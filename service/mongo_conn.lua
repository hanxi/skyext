local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local mongo = require "skynet.db.mongo"
local log = require "skyext.log"

local g_name, g_index = ...
g_index = tonumber(g_index)
local g_db
local service_name = string.format("mongo_conn:%s:%d", g_name, g_index)

-- log 配置使用 traceback 避免出错打印upvale。
-- upvalue 中包含的请求，会消耗大量的内存
log.config({
    name = service_name,
    traceback = debug.traceback,
})

local CMD = {}

local function init_db(dbname)
    -- 配置由 skyext 的 skynet.init 回调注入，必须在启动回调里读，
    -- 加载期读到的永远是 nil
    local mongo_config = config.get_table("mongo_config")
    local db_config = mongo_config and mongo_config[dbname]
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

-- opts = { projection = {...}, sort = {...} | { {k1=1}, {k2=-1} }, skip = n, limit = n }
function CMD.find_many(coll, doc, opts)
    opts = opts or {}
    local col_obj = g_db[coll]
    local it = col_obj:find(doc, opts.projection)
    local sort = opts.sort
    if sort then
        if sort[1] ~= nil then
            -- 数组形式：保证多字段排序的先后顺序
            it:sort(table.unpack(sort))
        else
            it:sort(sort)
        end
    end
    if opts.skip then
        it:skip(opts.skip)
    end
    if opts.limit then
        it:limit(opts.limit)
    end
    local all = {}
    while it:hasNext() do
        all[#all + 1] = it:next()
    end
    return all
end

function CMD.create_index(coll, keys, options)
    local col_obj = g_db[coll]
    if options then
        return col_obj:createIndex(keys, options)
    end
    return col_obj:createIndex(keys)
end

function CMD.find_one(coll, doc, projection)
    local col_obj = g_db[coll]
    local ret = col_obj:findOne(doc, projection)
    -- 逐字段打印会把整份存档（含玩家数据）刷进日志，这里只留一条概要
    log.debug("find_one", "coll", coll, "doc", doc, "projection", projection, "found", ret ~= nil)
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

function CMD.safe_delete(coll, query, single)
    local col_obj = g_db[coll]
    return col_obj:safe_delete(query, single)
end

skynet.start(function()
    init_db(g_name)
    cmd_api.dispatch(CMD)
end)
