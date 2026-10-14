local skynet = require "skynet"
local config = require "skyext.config"
local log = require "skyext.log"
local mongo_conn = require "skyext.mongo_conn"
local orm = require "orm"
local SCHEMA_PATH = "game.orm.schema"
local schema = require(SCHEMA_PATH)
local save_wheel = require "skyext.save_wheel"
local queue = require "skynet.queue"

local M = {}

local g_collection_obj = {} -- 数据库链接
local g_cache_collection = {} -- 缓存数据对象
local g_row_locks = {}
local g_default_projection = { _id = false, _fence = false }
-- 认领 fence 时需要读回 _fence 判断归属，之后再从文档里剔除（schema 中没有这个字段）。
local g_claim_projection = { _id = false }
local FENCE_CLAIM_ATTEMPTS = 3
-- 配置有可能在模块加载之后才注入（dbmgr 会被很早 require 到），
-- 在加载期读取会把 nil / 空表永久缓存下来，因此改成惰性读取 + 缓存
local g_mongo_config
local function mongo_config()
    if not g_mongo_config then
        g_mongo_config = assert(config.get_table("mongo_config"), "mongo_config is not configured")
    end
    return g_mongo_config
end

local g_db_save_interval
local function db_save_interval()
    if not g_db_save_interval then
        g_db_save_interval = config.get_number("db_save_interval") or 3 * 60
    end
    return g_db_save_interval
end

local function check_collection(dbname, dbcoll)
    local db_config = mongo_config()[dbname]
    if db_config == nil then
        error("database not configured" .. dbname)
    end

    local coll_config = db_config.collections[dbcoll]
    if coll_config == nil then
        error("collection not configured" .. dbname .. "." .. dbcoll)
    end
end

local function get_cache_collection(dbname, dbcoll)
    if not g_cache_collection[dbname] then
        g_cache_collection[dbname] = {}
    end
    local colls = g_cache_collection[dbname]
    if not colls[dbcoll] then
        colls[dbcoll] = {}
    end
    return colls[dbcoll]
end

local function get_collection_obj(dbname, dbcoll)
    if not g_collection_obj[dbname] then
        g_collection_obj[dbname] = {}
    end
    local colls = g_collection_obj[dbname]
    if not colls[dbcoll] then
        local coll_obj = mongo_conn.get_collection(dbname, dbcoll)
        colls[dbcoll] = coll_obj
        log.info("new mongo collection", "dbname", dbname, "dbcoll", dbcoll)
    end
    return colls[dbcoll]
end

local function with_row_lock(dbname, dbcoll, unique_id, f)
    g_row_locks[dbname] = g_row_locks[dbname] or {}
    local collection = g_row_locks[dbname]
    collection[dbcoll] = collection[dbcoll] or {}
    local rows = collection[dbcoll]
    local lock = rows[unique_id]
    if not lock then
        lock = { run = queue(), users = 0 }
        rows[unique_id] = lock
    end
    lock.users = lock.users + 1
    local ok, result, err = pcall(lock.run, f)
    lock.users = lock.users - 1
    if lock.users == 0 then
        rows[unique_id] = nil
    end
    if not ok then
        error(result, 0)
    end
    return result, err
end

local function lease_valid(handle)
    return not handle or require("skyext.distributed_lock").is_valid(handle)
end

-- 统一 findAndModify 的失败形态：网络异常、ok ~= 1 都算调用失败。
local function find_and_modify(coll_obj, opts)
    local called, ret = pcall(coll_obj.find_and_modify, coll_obj, opts)
    if not called then
        return nil, ret
    end
    if type(ret) ~= "table" or ret.ok ~= 1 then
        return nil, (type(ret) == "table" and ret.errmsg) or ret or "no reply"
    end
    return ret
end

-- Skynet Mongo 驱动把 BSON null 解码成单字节字符串 "\0"，
-- 因此只有 table 才算“命中并返回了文档”，其余一律视为没有匹配。
local function matched_value(ret)
    local value = ret and ret.value
    if type(value) == "table" then
        return value
    end
    return nil
end

-- 原子地“认领 fence + 读取文档”。
--
-- 必须是同一次 findAndModify：先读后认领会留下窗口，旧持有者在窗口内的写入
-- 既不会被 fence 拒绝（此时 _fence 还是旧值），又不会出现在我们已经读到的快照里，
-- 结果是缓存文档落后于数据库，后续所有 _version 乐观锁写入永远失配。
--
-- 带 fence 约束的查询绝不能开 upsert：文档若已被更高 fence 认领，查询不匹配会让
-- upsert 直接插入一条同 key 的重复文档（除非恰好建了唯一索引，而索引是配置可选的）。
-- 所以“不存在就创建”单独走等值查询 + $setOnInsert，既不会改坏既有文档，
-- 也不会插出重复 key。
local function claim_with_fence(coll_obj, key, unique_id, initial, fence)
    local last_err
    for _ = 1, FENCE_CLAIM_ATTEMPTS do
        local ret, err = find_and_modify(coll_obj, {
            query = {
                [key] = unique_id,
                ["$or"] = {
                    { _fence = { ["$lte"] = fence } },
                    { _fence = { ["$exists"] = false } },
                },
            },
            -- 只有 $set，没有 $setOnInsert：两个操作符同时写 _fence 会被 mongod 判为路径冲突。
            update = { ["$set"] = { _fence = fence } },
            -- 命中即代表 fence 已归我们，不需要把 _fence 读回来。
            fields = g_default_projection,
            upsert = false,
            new = true,
        })
        if not ret then
            return nil, "fence claim failed", err
        end
        local claimed = matched_value(ret)
        if claimed then
            return claimed
        end

        -- 没匹配：要么文档还不存在，要么已经属于更高的 fence。
        local created, create_err = find_and_modify(coll_obj, {
            query = { [key] = unique_id },
            -- 只有 $setOnInsert（initial 里已经带上 _fence），不会改动既有文档。
            update = { ["$setOnInsert"] = initial },
            -- 这一步需要读回 _fence 判断文档归谁，调用方负责在建 ORM 文档前剔除。
            fields = g_claim_projection,
            upsert = true,
            new = true,
        })
        local value = matched_value(created)
        if not value then
            return nil, "fence claim failed", create_err or (created and created.lastErrorObject)
        end
        if value._fence == fence then
            -- 要么是我们刚插入的（插入时就带上了 fence），要么本来就归我们。
            return value
        end
        if value._fence and value._fence > fence then
            return nil, "fence superseded"
        end
        -- 文档刚被别人创建且 fence 更低或缺失：回到上面重新认领。
        last_err = "document created concurrently"
    end
    return nil, "fence claim failed", last_err
end

local function save_doc(coll_obj, key, unique_id, doc, handle)
    if not lease_valid(handle) then
        log.error("refusing save without lease", "key", key, "unique_id", unique_id)
        return false
    end
    if not orm.is_dirty(doc) then
        return true
    end

    local old_version = assert(doc._version, "document has no _version")
    local is_dirty, update, revision = orm.snapshot_mongo(doc)
    if not is_dirty then
        orm.ack_mongo(doc, revision, old_version)
        return true
    end

    local query = { [key] = unique_id, _version = old_version }
    if handle then
        query._fence = handle.fence
    end
    update["$set"] = update["$set"] or {}
    update["$set"]._version = old_version + 1
    local called, ok, err, ret = pcall(coll_obj.safe_update, coll_obj, query, update, false)
    if not called or not ok or type(ret) ~= "table" or ret.n ~= 1 or ret.nModified ~= 1 or ret.upserted then
        log.error("save failed", "query", query, "update", update, "reply", ret, "error", called and err or ok)
        return false
    end

    if not lease_valid(handle) then
        log.error("lease lost during save, retaining dirty state", "query", query)
        return false
    end
    orm.ack_mongo(doc, revision, old_version + 1)
    log.info("save success", "query", query, "version", old_version + 1)
    return true
end

-- 回存轮用的落库入口：等行锁期间文档可能已经被卸载或被新的持有者换掉，
-- 所以拿到锁之后要确认缓存里还是同一个条目，否则这一轮就不该再碰它
local function sweep_save(entry)
    return with_row_lock(entry.dbname, entry.dbcoll, entry.unique_id, function()
        if get_cache_collection(entry.dbname, entry.dbcoll)[entry.unique_id] ~= entry then
            return true
        end
        local coll_obj = get_collection_obj(entry.dbname, entry.dbcoll)
        return save_doc(coll_obj, entry.key, entry.unique_id, entry.doc, entry.handle)
    end)
end

-- 所有缓存文档共用一个回存轮，而不是一个文档挂一个定时器
local g_save_wheel
local function save_wheel_obj()
    if not g_save_wheel then
        g_save_wheel = save_wheel.new("dbmgr", db_save_interval(), function(entry)
            if not sweep_save(entry) then
                log.error(
                    "sweep save failed",
                    "dbname",
                    entry.dbname,
                    "dbcoll",
                    entry.dbcoll,
                    "unique_id",
                    entry.unique_id
                )
            end
        end)
    end
    return g_save_wheel
end

function M.load(dbname, dbcoll, key, unique_id, default, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        if not lease_valid(handle) then
            return nil, "lease expired"
        end
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cached = cache_collection[unique_id]
        if cached then
            if cached.handle == handle then
                return cached.doc
            end
            if orm.is_dirty(cached.doc) then
                return nil, "stale dirty cache requires recovery"
            end
            save_wheel_obj():remove(cached)
            cache_collection[unique_id] = nil
        end

        -- 浅拷贝，避免把 key/_version/_fence 写回调用方传入的 default 表。
        local initial = {}
        for k, v in pairs(orm.to_bson(default or {})) do
            initial[k] = v
        end
        initial[key] = unique_id
        initial._version = 0
        initial._fence = handle and handle.fence or nil

        local coll_obj = get_collection_obj(dbname, dbcoll)
        local value
        if handle then
            if not lease_valid(handle) then
                return nil, "lease expired during load"
            end
            local claimed, reason, detail = claim_with_fence(coll_obj, key, unique_id, initial, handle.fence)
            if not claimed then
                log.error(
                    "fence claim failed",
                    "dbname",
                    dbname,
                    "dbcoll",
                    dbcoll,
                    "key",
                    key,
                    "unique_id",
                    unique_id,
                    "fence",
                    handle.fence,
                    "reason",
                    reason,
                    "detail",
                    detail
                )
                return nil, reason
            end
            -- 认领已经落库；此处即便发现租约失效也不回滚 _fence：
            -- 更低 fence 的旧持有者本来就该被拒绝，后继者的 fence 一定更大。
            if not lease_valid(handle) then
                return nil, "lease expired during fence claim"
            end
            claimed._fence = nil
            value = claimed
        else
            local ret, err = find_and_modify(coll_obj, {
                query = { [key] = unique_id },
                update = { ["$setOnInsert"] = initial },
                fields = g_default_projection,
                upsert = true,
                new = true,
            })
            value = matched_value(ret)
            if not value then
                log.error(
                    "load failed",
                    "dbname",
                    dbname,
                    "dbcoll",
                    dbcoll,
                    "key",
                    key,
                    "unique_id",
                    unique_id,
                    "ret",
                    ret,
                    "error",
                    err
                )
                return nil, "database load failed"
            end
        end

        local schema_type = assert(schema[dbcoll], "missing schema for " .. dbcoll)
        local doc = schema_type.new(value)
        local entry = {
            doc = doc,
            handle = handle,
            dbname = dbname,
            dbcoll = dbcoll,
            key = key,
            unique_id = unique_id,
        }
        cache_collection[unique_id] = entry
        save_wheel_obj():add(entry)
        return doc
    end)
end

function M.save(dbname, dbcoll, key, unique_id)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache = get_cache_collection(dbname, dbcoll)[unique_id]
        if not cache then
            return false
        end
        return save_doc(get_collection_obj(dbname, dbcoll), key, unique_id, cache.doc, cache.handle)
    end)
end

function M.unload(dbname, dbcoll, key, unique_id)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cache = cache_collection[unique_id]
        if not cache then
            return false
        end
        local ok = save_doc(get_collection_obj(dbname, dbcoll), key, unique_id, cache.doc, cache.handle)
        if not ok or orm.is_dirty(cache.doc) then
            log.error(
                "unload failed, retaining dirty cache",
                "dbname",
                dbname,
                "dbcoll",
                dbcoll,
                "unique_id",
                unique_id
            )
            return false
        end
        save_wheel_obj():remove(cache)
        cache_collection[unique_id] = nil
        return true
    end)
end

function M.discard_clean(dbname, dbcoll, unique_id, handle)
    check_collection(dbname, dbcoll)
    return with_row_lock(dbname, dbcoll, unique_id, function()
        local cache_collection = get_cache_collection(dbname, dbcoll)
        local cache = cache_collection[unique_id]
        if not cache or cache.handle ~= handle or orm.is_dirty(cache.doc) then
            return false
        end
        save_wheel_obj():remove(cache)
        cache_collection[unique_id] = nil
        return true
    end)
end

local GM_CMD = {}
GM_CMD.reload_orm_schema = {
    desc = "重载 orm schema",
    handler = function()
        -- require 有缓存，必须先清掉才能拿到热更后的新代码
        package.loaded[SCHEMA_PATH] = nil
        local ok, new_schema = pcall(require, SCHEMA_PATH)
        -- 不论成败都要把原来那张表放回去：整个进程只能有一份 schema 表，
        -- 否则 orm doc 的类型判定会分裂成两套
        package.loaded[SCHEMA_PATH] = schema
        if not ok then
            log.error("reload schema failed", "err", new_schema)
            return false, new_schema
        end
        if new_schema == schema then
            -- loader 返回的还是同一张表（package.preload 之类），
            -- 拿它 reload 等于把 schema 清空，必须拒绝
            local err = "new schema is the same table, reload skipped"
            log.error("reload schema failed", "err", err)
            return false, err
        end
        orm.reload_schema(schema, new_schema)
        log.info("reload schema success", "schema", tostring(schema), "new_schema", tostring(new_schema))
        return true
    end,
}

skynet.init(function()
    local gm_api = require "skyext.gm_api"
    gm_api.register(GM_CMD)
end)

return M
