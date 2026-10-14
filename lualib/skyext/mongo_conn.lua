local skynet = require "skynet"
local queue = require "skynet.queue"
local config = require "skyext.config"
local bson = require "bson"
local log = require "skyext.log"
local orm = require "orm"

local to_lightuserdata = bson.to_lightuserdata

local M = {}

-- 配置可能在 config.init() 之后才可见，加载期读取会把 nil 永久缓存下来，
-- 因此改成首次使用时读取并缓存
local g_mongo_config
local function mongo_config()
    if not g_mongo_config then
        g_mongo_config = assert(config.get_table("mongo_config"), "mongo_config is not configured")
    end
    return g_mongo_config
end

-- 处理 orm 的情况：orm.to_bson 返回脱离 ORM 的普通表（map key 已转成 string），
-- 普通表原样通过，因此 query/update 仍然可以直接传普通 Lua 表。
local _bson_encode = bson.encode
local function bson_encode(doc)
    return _bson_encode(orm.to_bson(doc))
end

local conn_mt = {}
conn_mt.__index = conn_mt

-- fuck tail call
local function call_ret(...)
    return ...
end

function conn_mt:call(cmd, ...)
    return call_ret(skynet.call(self.addr, "lua", cmd, ...))
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
    return conn_obj:call("find_and_modify", self.coll, doc)
end

function coll_mt:find(doc, projection)
    local conn_obj = self.db:_route()
    return conn_obj:call("find", self.coll, doc, projection)
end

-- 带 sort/skip/limit 的查询，返回文档数组。
-- opts = { projection = {...}, sort = {...}, skip = n, limit = n }
-- sort 支持两种写法：
--   单字段 { seq = 1 }
--   多字段（有序）{ { target_id = 1 }, { seq = 1 } } —— 必须用数组形式，Lua 表的 pairs 无序
function coll_mt:find_many(doc, opts)
    local conn_obj = self.db:_route()
    return conn_obj:call("find_many", self.coll, doc, opts)
end

function coll_mt:find_one(doc, projection)
    local conn_obj = self.db:_route()
    return conn_obj:call("find_one", self.coll, doc, projection)
end

-- 兼容 orm 数据打包,必须在调用者服务执行 bson_encode
function coll_mt:safe_insert(doc)
    local conn_obj = self.db:_route()
    -- 整个 doc 就是玩家存档，不能整份刷进日志
    log.debug("safe_insert", "coll", self.coll)
    local bson_obj = bson_encode(doc)
    return conn_obj:call("raw_safe_insert", self.coll, to_lightuserdata(bson_obj))
end

function coll_mt:safe_update(query, update, upsert, multi)
    local conn_obj = self.db:_route()
    -- update 里是整份存档增量，只记录定位用的 query
    log.debug("safe_update", "coll", self.coll, "query", query, "upsert", upsert, "multi", multi)
    local bson_obj = bson_encode({
        q = query,
        u = update,
        upsert = upsert,
        multi = multi,
    })
    return conn_obj:call("raw_safe_update", self.coll, to_lightuserdata(bson_obj))
end

-- 建索引，幂等。
-- 单参数（推荐，支持复合索引）：create_index { { a = 1 }, { b = 1 }, name = "a_b", unique = true }
-- 兼容写法（单字段）：create_index({ a = 1 }, { unique = true })
function coll_mt:create_index(keys, options)
    local conn_obj = self.db:_route()
    return conn_obj:call("create_index", self.coll, keys, options)
end

local db_mt = {}
db_mt.__index = db_mt

-- 提供给测试注入假的 db 对象（只需实现 _route）
local function new_collection(db_obj, coll)
    return setmetatable({
        db = db_obj,
        coll = coll,
    }, coll_mt)
end

function db_mt:get_collection(coll)
    local collection = self.collections[coll]
    if not collection then
        collection = new_collection(self, coll)
        self.collections[coll] = collection
    end
    return collection
end

function db_mt:_route()
    local index = math.random(1, #self.conns)
    return self.conns[index]
end

function db_mt:init()
    local db_config = assert(mongo_config()[self.name], "database not configured: " .. tostring(self.name))
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

-- 仅供测试：用自定义 db 对象（需实现 :_route() 返回带 :call(cmd, ...) 的连接）构造 collection
M._new_collection = new_collection

return M
