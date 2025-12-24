local skynet = require("skynet")
local cmd_api = require("cmd_api")
local config = require("config")
local mongo = require("skynet.db.mongo")
local util_table = require("util.table")
local bson = require("bson")
local log = require("log")

local bson_meta = bson.meta

local g_name, g_index = ...
g_index = tonumber(g_index)
local g_db
local mongo_config = config.get_table("mongo_config")
local service_name = string.format("mongo_conn:%s:%d", g_name, g_index)

-- log 配置使用 traceback 避免出错打印upvale。
-- upvalue 中包含的请求，会消耗大量的内存
log.config({
    name = service_name,
    traceback = debug.traceback,
})

local CMD = {}

local function init_db(dbname)
    local db_config = mongo_config[dbname]
    assert(db_config, "Database not configured: " .. dbname)
    local dbs = mongo.client(db_config.cfg)
    g_db = dbs[dbname]
end

function CMD.find_and_modify(coll, doc)
    local col_obj = g_db[coll]
    return col_obj:findAndModify(doc)
end

function CMD.find(coll, doc, projection)
    local col_obj = g_db[coll]
    local it = col_obj:find(doc, projection)
    local all = {}
    while it:hasNext() do
        local role = it:next()
        all[#all + 1] = role
    end
    return all
end

function CMD.find_one(coll, doc, projection)
    log.debug("find_one", "coll", coll, "doc", doc, "projection", projection)
    local col_obj = g_db[coll]
    local ret = col_obj:findOne(doc, projection)
    for k, v in pairs(ret or {}) do
        log.debug("find_one", "k", k, "v", v, "typev", type(v))
    end
    log.debug("find_one", "ret", ret)
    return ret
end

function CMD.raw_safe_insert(coll, bson_str)
    local col_obj = g_db[coll]
    return col_obj:raw_safe_insert(bson_str)
end

function CMD.raw_safe_update(coll, bson_str)
    local col_obj = g_db[coll]
    log.debug("raw_safe_update", "coll", coll, "bson_str", bson_str)
    return col_obj:raw_safe_update(bson_str)
end

skynet.start(function()
    init_db(g_name)
    cmd_api.dispatch(CMD)
end)
