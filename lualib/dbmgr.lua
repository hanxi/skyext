local skynet = require "skynet"
local config = require "config"
local log = require "log"
local mongo_conn = require "mongo_conn"
local orm = require "orm"
local schema = require "orm.schema"
local timer = require "timer"

local M = {}

local g_collection_obj = {} -- 数据库链接
local g_cache_collection = {} -- 缓存数据对象
local g_default_projection = { _id = false }
local mongo_config = config.get_table("mongo_config")
local db_save_interval = config.get_number("db_save_interval") or 3 * 60

local function check_collection(dbname, dbcoll)
    local db_config = mongo_config[dbname]
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

local function save_dirty(coll_obj, query, dirty_doc)
    local ok, err, ret = coll_obj:safe_update(query, dirty_doc, true)
    if not ok then
        log.error("save failed", "query", query, "dirty_doc", dirty_doc, "ret", ret, "err", err)
        return false
    end

    if ret.nModified ~= 1 then
        log.error("save failed not modified", "query", query, "dirty_doc", dirty_doc, "ret", ret)
        return false
    end
    return true
end

local function save_doc(coll_obj, key, unique_id, doc)
    if not orm.is_dirty(doc) then
        log.debug("doc not dirty", "key", key, "unique_id", unique_id)
        return true
    end

    local old_version = doc._version
    doc._version = old_version + 1
    local query = {
        [key] = unique_id,
        _version = old_version,
    }
    local is_dirty, dirty_doc = orm.commit_mongo(doc)
    if not is_dirty then
        log.info("save not dirty", "query", query, "doc", doc)
        return true
    end

    local ok = save_dirty(coll_obj, query, dirty_doc)
    if not ok then
        doc._version = doc._version - 1
    end

    log.info("save success", "query", query, "doc", doc)
    return true
end

function M.load(dbname, dbcoll, key, unique_id, default)
    check_collection(dbname, dbcoll)

    local cache_collection = get_cache_collection(dbname, dbcoll)
    if cache_collection[unique_id] then
        return cache_collection[unique_id].doc
    end

    -- 防重入，提前占位
    cache_collection[unique_id] = {
        loading = true,
    }

    local t = default or {}
    t[key] = unique_id
    t._version = 0

    -- 从数据库加载数据
    local coll_obj = get_collection_obj(dbname, dbcoll)
    local ret = coll_obj:find_and_modify({
        query = { [key] = unique_id },
        update = { ["$setOnInsert"] = t },
        fields = g_default_projection,
        upsert = true,
        new = true,
    })

    log.debug("load data", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id, "ret", ret)
    if ret.ok ~= 1 then
        log.error("load failed", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id, "ret", ret)
        return
    end

    -- 防止重入
    if not cache_collection[unique_id].loading then
        log.warn("load again", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
        return cache_collection[unique_id].doc
    end

    -- 用 orm 包裹: dbcoll 为 schema name
    local doc = schema[dbcoll].new(ret.value)

    -- 定时器入库脏数据(随机分布)
    local timer_obj = timer.repeat_random_delayed("dbmgr", db_save_interval, function()
        save_doc(coll_obj, key, unique_id, doc)
        log.debug("timer save", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
    end)

    cache_collection[unique_id] = {
        doc = doc,
        timer_obj = timer_obj,
    }

    return doc
end

function M.unload(dbname, dbcoll, key, unique_id)
    check_collection(dbname, dbcoll)

    local cache_collection = get_cache_collection(dbname, dbcoll)
    if not cache_collection then
        log.error("unload failed no cache", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
        return
    end
    local cache = cache_collection[unique_id]
    if not cache then
        log.error("unload failed no such row", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
        return
    end

    if cache.loading then
        log.warn("unload failed by loading", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
        return
    end

    if cache.unloading then
        log.warn("unload again", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
        return
    end

    cache.unloading = true

    -- 先取消定时存盘
    cache.timer_obj:cancel()
    log.info("cancel timer save by unload", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)

    local doc = cache.doc
    if not doc then
        log.error("unload failed no such doc", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
        return
    end

    local coll_obj = get_collection_obj(dbname, dbcoll)
    local ok = save_doc(coll_obj, key, unique_id, doc)
    if not ok then
        -- TODO: 把数据完整写入到其他地方
        log.error("unload failed", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
    end

    cache.unloading = nil
    -- 移除 cache
    cache_collection[unique_id] = nil

    log.info("unload success", "dbname", dbname, "dbcoll", dbcoll, "key", key, "unique_id", unique_id)
end

-- TODO: 关进程时 unload 所有数据:可以考虑用 bulkWrite 接口。

local GM_CMD = {}
GM_CMD.reload_orm_schema = {
    desc = "重载 orm schema",
    handler = function()
        local new_schema = require "orm.schema"
        orm.reload_schema(schema, new_schema)
        log.info("reload schema success", "schema", tostring(schema), "new_schema", tostring(new_schema))
        return true
    end,
}

skynet.init(function()
    local gm_api = require "gm_api"
    gm_api.register(GM_CMD)
end)

return M
