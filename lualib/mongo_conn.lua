local skynet = require "skynet"
local queue = require "skynet.queue"
local config = require "config"
local bson = require "bson"
local log = require "log"
local orm = require "orm"

local to_lightuserdata = bson.to_lightuserdata

local M = {}

local mongo_config = config.get_table("mongo_config")

-- 处理 orm 的情况
local _bson_encode = bson.encode
local _with_bson_encode_context = orm.with_bson_encode_context
local function bson_encode(doc)
    return _with_bson_encode_context(_bson_encode, doc)
end

local conn_mt = {}
conn_mt.__index = conn_mt

function conn_mt:call(cmd, ...)
    return skynet.call(self.addr, "lua", cmd, ...)
end

local conn = {}
function conn.new(name, index)
    local service_name = string.format("mongo_conn:%s:%d", name, index)
    local service_addr = skynet.uniqueservice(service_name, name, index)
    log.info("mongo_conn new", "service_name", service_name, "service_addr", service_addr)
    return setmetatable({ name = service_name, addr = service_addr }, conn_mt)
end

local coll_mt = {}
coll_mt.__index = coll_mt

function coll_mt:find_and_modify(doc)
    local conn_obj = self.db:_route()
    return skynet.call(conn_obj.addr, "lua", "find_and_modify", self.coll, doc)
end

function coll_mt:find(doc, projection)
    local conn_obj = self.db:_route()
    return skynet.call(conn_obj.addr, "lua", "find", self.coll, doc, projection)
end

function coll_mt:find_one(doc, projection)
    local conn_obj = self.db:_route()
    return skynet.call(conn_obj.addr, "lua", "find_one", self.coll, doc, projection)
end

-- 兼容 orm 数据打包,必须在调用者服务执行 bson_encode
function coll_mt:safe_insert(doc)
    local conn_obj = self.db:_route()
    log.debug("safe_insert doc:", "doc", doc)
    local bson_obj = bson_encode(doc)
    return skynet.call(conn_obj.addr, "lua", "raw_safe_insert", self.coll, to_lightuserdata(bson_obj))
end

function coll_mt:safe_update(query, update, upsert, multi)
    local conn_obj = self.db:_route()
    log.debug("safe_update", "query", query, "update", update, "upsert", upsert, "multi", multi)
    local bson_obj = bson_encode({
        q = query,
        u = update,
        upsert = upsert,
        multi = multi,
    })
    return skynet.call(conn_obj.addr, "lua", "raw_safe_update", self.coll, to_lightuserdata(bson_obj))
end

local db_mt = {}
db_mt.__index = db_mt

function db_mt:get_collection(coll)
    local collection = self.collections[coll]
    if not collection then
        collection = setmetatable({
            db = self,
            coll = coll,
        }, coll_mt)
        self.collections[coll] = collection
    end
    return collection
end

function db_mt:_route()
    local index = math.random(1, #self.conns)
    return self.conns[index]
end

function db_mt:init()
    local db_config = mongo_config[self.name]
    for i = 1, db_config.connections do
        local conn_obj = conn.new(self.name, i)
        table.insert(self.conns, conn_obj)
    end
end

local db = {}
function db.new(name)
    return setmetatable({
        name = name,
        collections = {},
        conns = {},
    }, db_mt)
end

local g_dbs = {}
local g_db_locks = {}

local function _get_db(name)
    local db_obj = g_dbs[name]
    if db_obj then
        return db_obj
    end

    db_obj = db.new(name)
    db_obj:init()
    g_dbs[name] = db_obj
    return db_obj
end

local function get_db(name)
    local db_obj = g_dbs[name]
    if db_obj then
        return db_obj
    end

    local lock = g_db_locks[name]
    if not lock then
        lock = queue()
        g_db_locks[name] = lock
    end

    return lock(_get_db, name)
end

function M.get_collection(name, coll)
    local db_obj = get_db(name)
    return db_obj:get_collection(coll)
end

return M
