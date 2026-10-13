--[[
可靠消息（at-least-once 语义）

投递保证：
  1. `router.reliable_send` 先持久化消息（`save`），再尝试即时投递；持久化失败直接报错，
     不会给调用方“已可靠投递”的假象。
  2. 处理函数执行成功、实体状态确认写入后才 ack（`mark_delivered`）；handler 抛错、
     节点宕机或 ack 写库失败时消息保持 pending，已加载实体也会周期性重试。
  3. 即时投递只唤醒从 Mongo 读取 pending 的同一个按实体串行化的入口。

因此同一条消息可能被投递多次（即时投递与加载重投并发、ack 写库失败后重投等），
**业务 handler 必须幂等**；可用 `msg_id`（全局唯一）作为业务侧去重键。

对已落库的 pending 消息按 `seq` 升序读取。`seq` 由 MongoDB
`findAndModify($inc + upsert + new)` 原子分配，并发 save 不会重号。
但 seq 分配与消息 insert 不是一个事务：较小 seq 的生产者若延迟插入，
较大 seq 的消息仍可能先被投递，因此不保证并发生产者的严格全序。
注意不要用 `msg_id` 排序：`skyext.id_generator` 的本地缓存池用哈希表存放预取 ID，
发放顺序与分配顺序无关，snowflake ID 的大小并不反映 save 的先后。

索引建议（生产环境请执行 `M.ensure_indexes()` 或由 DBA 建好）：
  entity_msg: { target_type, target_id, status, seq }（支撑 pending 排序分页）
  entity_msg: { msg_id } unique（ack 与业务去重）
]]

local mongo_conn = require "skyext.mongo_conn"
local id_generator = require "skyext.id_generator"
local log = require "skyext.log"
local time = require "skyext.time"

local M = {}

local DB_NAME = "entity"
local MSG_COLL = "entity_msg"
local SEQ_COLL = "entity_msg_seq"

-- 消息状态
M.STATUS_PENDING = 0
M.STATUS_DELIVERED = 1

-- 单次 find 的默认批大小，避免一次拉回超大结果集
M.DEFAULT_PAGE_SIZE = 200

local function msg_coll()
    return mongo_conn.get_collection(DB_NAME, MSG_COLL)
end

local function seq_coll()
    return mongo_conn.get_collection(DB_NAME, SEQ_COLL)
end

local function seq_key(target_type, target_id)
    return string.format("%s:%s", tostring(target_type), tostring(target_id))
end

-- 原子分配 (target_type, target_id) 维度自增序号。
-- upsert + new 保证首次分配返回 1，并发调用由 mongod 串行化，不会重号。
function M.next_seq(target_type, target_id)
    local ret = seq_coll():find_and_modify({
        query = { _id = seq_key(target_type, target_id) },
        update = { ["$inc"] = { seq = 1 } },
        upsert = true,
        new = true,
    })
    if not ret or ret.ok ~= 1 then
        error(string.format("reliable_msg alloc seq failed: %s", ret and ret.errmsg or "no reply"))
    end
    local value = ret.value
    local seq = value and value.seq
    if type(seq) ~= "number" then
        error(string.format("reliable_msg alloc seq got invalid value for %s", seq_key(target_type, target_id)))
    end
    return seq
end

-- 持久化一条可靠消息；失败抛错，调用方不应继续按“已持久化”处理
function M.save(target_type, target_id, cmd, args)
    local msg_id = id_generator.newid()
    local seq = M.next_seq(target_type, target_id)
    local doc = {
        msg_id = msg_id,
        seq = seq,
        target_type = target_type,
        target_id = target_id,
        cmd = cmd,
        args = args,
        status = M.STATUS_PENDING,
        create_time = time.now(),
    }
    local ok, err = msg_coll():safe_insert(doc)
    if not ok then
        error(
            string.format(
                "reliable_msg save failed: target=%s/%s cmd=%s msg_id=%s err=%s",
                tostring(target_type),
                tostring(target_id),
                tostring(cmd),
                tostring(msg_id),
                tostring(err)
            )
        )
    end
    log.debug(
        "reliable_msg save",
        "msg_id",
        msg_id,
        "seq",
        seq,
        "target_type",
        target_type,
        "target_id",
        target_id,
        "cmd",
        cmd
    )
    return msg_id, seq
end

-- 按 seq 升序分页读取 pending 消息。
-- 使用 seq > last_seq 的 keyset 分页（而不是 skip），并发 ack/插入时不会漏读或重读。
-- opts: { page_size = 每批条数, max_count = 最多返回条数, after_seq = 只取大于该 seq 的消息 }
function M.load_pending(target_type, target_id, opts)
    opts = opts or {}
    local page_size = opts.page_size or M.DEFAULT_PAGE_SIZE
    assert(type(page_size) == "number" and page_size > 0, "page_size must be positive")
    local max_count = opts.max_count
    local after_seq = opts.after_seq
    local coll = msg_coll()
    local result = {}

    while true do
        local limit = page_size
        if max_count then
            local remain = max_count - #result
            if remain <= 0 then
                break
            end
            if remain < limit then
                limit = remain
            end
        end

        local query = {
            target_type = target_type,
            target_id = target_id,
            status = M.STATUS_PENDING,
        }
        if after_seq then
            query.seq = { ["$gt"] = after_seq }
        end

        local batch = coll:find_many(query, {
            sort = { seq = 1 },
            limit = limit,
        })
        if not batch or #batch == 0 then
            break
        end

        local progressed = false
        for _, doc in ipairs(batch) do
            result[#result + 1] = doc
            if type(doc.seq) == "number" and (after_seq == nil or doc.seq > after_seq) then
                after_seq = doc.seq
                progressed = true
            end
        end

        if #batch < limit then
            break
        end
        if not progressed then
            -- 历史数据没有 seq 字段时无法做 keyset 分页，停止翻页避免死循环
            log.warn(
                "reliable_msg load_pending stop paging: documents without seq",
                "target_type",
                target_type,
                "target_id",
                target_id,
                "loaded",
                #result
            )
            break
        end
    end

    return result
end

-- ack 一条消息；只能在 handler 执行成功之后调用。
-- 幂等：重复 ack 返回 false（说明这是一次重复投递），首次 ack 返回 true。
-- 第二个返回值为失败原因（仅在抛错路径之外用于日志）。
function M.mark_delivered(msg_id)
    local ret = msg_coll():find_and_modify({
        query = { msg_id = msg_id, status = M.STATUS_PENDING },
        update = {
            ["$set"] = {
                status = M.STATUS_DELIVERED,
                delivered_time = time.now(),
            },
        },
        new = true,
    })
    if not ret or ret.ok ~= 1 then
        -- ack 写失败：消息仍为 pending，会在下次加载时重投（at-least-once）
        local err = ret and ret.errmsg or "no reply"
        log.error("reliable_msg mark_delivered failed", "msg_id", msg_id, "err", err)
        return false, err
    end
    -- Skynet Mongo 驱动将 BSON null 解码为单字节字符串 "\0"。
    if ret.value == nil or ret.value == "\0" or (ret.lastErrorObject and tonumber(ret.lastErrorObject.n) == 0) then
        log.debug("reliable_msg already delivered", "msg_id", msg_id)
        return false, "already_delivered"
    end
    if type(ret.value) ~= "table" then
        log.error("reliable_msg mark_delivered invalid value", "msg_id", msg_id, "value", ret.value)
        return false, "invalid ack response"
    end
    return true
end

function M.get(msg_id)
    return msg_coll():find_one({ msg_id = msg_id })
end

-- 建索引：幂等，可在服务启动时调用
function M.ensure_indexes()
    local coll = msg_coll()
    coll:create_index({
        { target_type = 1 },
        { target_id = 1 },
        { status = 1 },
        { seq = 1 },
        name = "pending_seq",
    })
    coll:create_index({
        { msg_id = 1 },
        name = "msg_id",
        unique = true,
    })
end

return M
