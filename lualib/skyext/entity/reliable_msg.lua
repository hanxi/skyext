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

毒消息隔离：
  同一条消息连续投递失败（没有对应 handler、handler 抛错）会累加 `attempts`，
  达到 `M.max_attempts()` 后转入死信队列（`STATUS_DEAD`），不再参与投递。
  只有“错在消息本身”的失败才计数；租约失效、实体落库失败、ack 写库失败属于环境问题，
  换个时间重投就能成功，计进去只会把正常消息误判成毒消息。
  死信可以通过 GM 指令 `dlq_list` / `dlq_replay` / `dlq_discard` 查看、重放、丢弃。

索引建议（生产环境请执行 `M.ensure_indexes()` 或由 DBA 建好）：
  entity_msg: { target_type, target_id, status, seq }（支撑 pending 排序分页）
  entity_msg: { msg_id } unique（ack 与业务去重）
  entity_msg: { status, dead_time }（死信队列列表）
]]

local mongo_conn = require "skyext.mongo_conn"
local id_generator = require "skyext.id_generator"
local config = require "skyext.config"
local log = require "skyext.log"
local time = require "skyext.time"

local M = {}

local DB_NAME = "entity"
local MSG_COLL = "entity_msg"
local SEQ_COLL = "entity_msg_seq"

-- 消息状态
M.STATUS_PENDING = 0
M.STATUS_DELIVERED = 1
-- 连续投递失败达到上限，已隔离，不再参与投递
M.STATUS_DEAD = 2
-- 死信被人工丢弃；文档保留，只是不再出现在死信列表里
M.STATUS_DISCARDED = 3

-- 单次 find 的默认批大小，避免一次拉回超大结果集
M.DEFAULT_PAGE_SIZE = 200

-- 同一条消息连续投递失败多少次后转入死信队列，可用节点配置
-- reliable_msg_max_attempts 覆盖
M.DEFAULT_MAX_ATTEMPTS = 5

-- last_error / dead_reason 里存的是 traceback，截断后再落库，
-- 否则一条毒消息能把文档撑到 MongoDB 的 16MB 上限
M.MAX_ERROR_LENGTH = 2048

-- 死信列表的默认/最大返回条数
M.DEFAULT_DEAD_PAGE_SIZE = 50
M.MAX_DEAD_PAGE_SIZE = 500

local g_warned_max_attempts = false

-- 投递次数上限。配置在 config.init() 之后才可见，因此每次读取（config 自身有缓存）。
function M.max_attempts()
    local n = config.get_number("reliable_msg_max_attempts")
    if n == nil then
        return M.DEFAULT_MAX_ATTEMPTS
    end
    if math.type(n) ~= "integer" or n < 1 then
        -- 不能因为配错了就让投递整体报错：那等于把一个配置笔误升级成消息积压
        if not g_warned_max_attempts then
            g_warned_max_attempts = true
            log.error(
                "invalid reliable_msg_max_attempts, falling back to default",
                "value",
                tostring(n),
                "default",
                M.DEFAULT_MAX_ATTEMPTS
            )
        end
        return M.DEFAULT_MAX_ATTEMPTS
    end
    return n
end

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

-- 从 findAndModify 的回包里取出文档。
-- Skynet Mongo 驱动把 BSON null 解码成单字节字符串 "\0"，查询没命中时拿到的就是它。
-- 返回 nil + "not_matched" 表示查询条件没命中（状态已经被别人改掉），
-- 返回 nil + 其它字符串表示这次写入本身失败了，调用方必须按“未生效”处理。
local function modified_doc(ret)
    if not ret or ret.ok ~= 1 then
        return nil, ret and ret.errmsg or "no reply"
    end
    local value = ret.value
    if value == nil or value == "\0" or (ret.lastErrorObject and tonumber(ret.lastErrorObject.n) == 0) then
        return nil, "not_matched"
    end
    if type(value) ~= "table" then
        return nil, "invalid response"
    end
    return value
end

-- 状态迁移的公共实现：只有处于 from_status 的消息会被改写，因此天然幂等。
local function transition(msg_id, from_status, set_fields, unset_fields)
    local update = { ["$set"] = set_fields }
    if unset_fields then
        update["$unset"] = unset_fields
    end
    local ret = msg_coll():find_and_modify({
        query = { msg_id = msg_id, status = from_status },
        update = update,
        new = true,
    })
    return modified_doc(ret)
end

-- ack 一条消息；只能在 handler 执行成功之后调用。
-- 幂等：重复 ack 返回 false（说明这是一次重复投递），首次 ack 返回 true。
-- 第二个返回值为失败原因（仅在抛错路径之外用于日志）。
function M.mark_delivered(msg_id)
    local doc, reason = transition(msg_id, M.STATUS_PENDING, {
        status = M.STATUS_DELIVERED,
        delivered_time = time.now(),
    })
    if doc then
        return true
    end
    if reason == "not_matched" then
        log.debug("reliable_msg already delivered", "msg_id", msg_id)
        return false, "already_delivered"
    end
    -- ack 写失败：消息仍为 pending，会在下次加载时重投（at-least-once）
    log.error("reliable_msg mark_delivered failed", "msg_id", msg_id, "err", reason)
    return false, reason
end

-- 记录一次投递失败：attempts 自增、保存最后一次错误，返回新的 attempts 值。
-- 查询限定 pending：消息已被 ack 或已判死时不再累加，返回 nil + 原因。
-- 失败时返回 nil，调用方不能把“没记上”当成“次数没到”之外的任何结论。
function M.record_failure(msg_id, err)
    local text = tostring(err)
    if #text > M.MAX_ERROR_LENGTH then
        text = text:sub(1, M.MAX_ERROR_LENGTH)
    end
    local ret = msg_coll():find_and_modify({
        query = { msg_id = msg_id, status = M.STATUS_PENDING },
        update = {
            ["$inc"] = { attempts = 1 },
            ["$set"] = {
                last_error = text,
                last_attempt_time = time.now(),
            },
        },
        new = true,
    })
    local doc, reason = modified_doc(ret)
    if not doc then
        log.error("reliable_msg record_failure failed", "msg_id", msg_id, "err", reason)
        return nil, reason
    end
    -- $inc 从缺失字段起算，首次必然是 1；取不到数字说明历史脏数据，按已达上限处理更安全
    local attempts = doc.attempts
    if type(attempts) ~= "number" then
        log.error("reliable_msg attempts is not a number", "msg_id", msg_id, "attempts", tostring(attempts))
        return nil, "invalid attempts"
    end
    return attempts
end

-- 把消息移入死信队列，不再参与投递。幂等：已经不是 pending 时返回 false。
function M.mark_dead(msg_id, reason)
    local text = tostring(reason)
    if #text > M.MAX_ERROR_LENGTH then
        text = text:sub(1, M.MAX_ERROR_LENGTH)
    end
    local doc, err = transition(msg_id, M.STATUS_PENDING, {
        status = M.STATUS_DEAD,
        dead_time = time.now(),
        dead_reason = text,
    })
    if doc then
        return true
    end
    if err == "not_matched" then
        return false, "not_pending"
    end
    log.error("reliable_msg mark_dead failed", "msg_id", msg_id, "err", err)
    return false, err
end

-- 死信重放：状态回到 pending、重投次数清零，返回消息文档。
-- 调用方拿 target_type/target_id 去唤醒目标实体。
-- 只有处于死信状态的消息可以重放，重复重放返回 nil + "not_dead"。
function M.replay(msg_id)
    local doc, err = transition(msg_id, M.STATUS_DEAD, {
        status = M.STATUS_PENDING,
        attempts = 0,
        replay_time = time.now(),
    }, {
        dead_time = 1,
        dead_reason = 1,
    })
    if doc then
        return doc
    end
    if err == "not_matched" then
        return nil, "not_dead"
    end
    log.error("reliable_msg replay failed", "msg_id", msg_id, "err", err)
    return nil, err
end

-- 丢弃一条死信：状态置为 discarded，文档保留以便事后追查。
-- 只有处于死信状态的消息可以丢弃，避免误删还在投递中的消息。
function M.discard(msg_id, operator)
    local doc, err = transition(msg_id, M.STATUS_DEAD, {
        status = M.STATUS_DISCARDED,
        discard_time = time.now(),
        discard_operator = tostring(operator or "unknown"),
    })
    if doc then
        return true
    end
    if err == "not_matched" then
        return false, "not_dead"
    end
    log.error("reliable_msg discard failed", "msg_id", msg_id, "err", err)
    return false, err
end

-- 列出死信消息，按进入死信队列的先后排序。
-- opts = { target_type = 只看某类实体, target_id = 只看某个实体, limit = 最多返回条数 }
function M.list_dead(opts)
    opts = opts or {}
    local limit = opts.limit or M.DEFAULT_DEAD_PAGE_SIZE
    assert(type(limit) == "number" and limit > 0, "limit must be positive")
    if limit > M.MAX_DEAD_PAGE_SIZE then
        limit = M.MAX_DEAD_PAGE_SIZE
    end
    local query = { status = M.STATUS_DEAD }
    if opts.target_type ~= nil then
        query.target_type = opts.target_type
    end
    if opts.target_id ~= nil then
        query.target_id = opts.target_id
    end
    return msg_coll():find_many(query, {
        sort = { dead_time = 1 },
        limit = limit,
    }) or {}
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
    -- 死信队列按入列时间翻页，status 单独在前缀上，不依赖 target 过滤
    coll:create_index({
        { status = 1 },
        { dead_time = 1 },
        name = "dead_time",
    })
end

return M
