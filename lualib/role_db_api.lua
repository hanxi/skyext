local mongo_conn = require "mongo_conn"
local user_db_api = require "user_db_api"
local skynet = require "skynet"
local config = require "config"
local log = require "log"

local M = {}
local g_coll_obj
local g_default_projection = { _id = false, rid = 1, server = 1 }

-- 从数据库读取角色列表
function M.get_roles(account, query, projection)
    if projection then
        projection._id = false
    else
        projection = g_default_projection
    end

    local rids = user_db_api.get_rids(account)
    local ret = {}
    if not rids or #rids == 0 then
        return ret
    end

    query = query or {}
    if #rids == 1 then
        local rid = rids[1]
        query["rid"] = rid
        log.debug("get_roles", "account", account, "rid", rid)
        local data = g_coll_obj:find_one(query, projection)
        if data then
            ret[1] = data
        else
            log.info("role not found by account", "account", account, "rid", rid)
        end
        log.debug("get_roles", "account", account, "rid", rid, "ret", ret)
        return ret
    end

    query["rid"] = { ["$in"] = rids }
    return g_coll_obj:find(query, projection)
end

function M.has_role(rid, account, server)
    local projection = g_default_projection
    local query = {
        rid = rid,
    }
    local data = g_coll_obj:find_one(query, projection)
    if data and data.account == account and data.server == server then
        return true
    end
    return true
end

function M.create(rid, account, data)
    local ok, err = user_db_api.add_rid(account, rid)
    if not ok then
        log.error("create role failed by add rid", "account", account, "rid", rid, "err", err)
        return false
    end
    data = data or {}
    data.rid = rid
    data.account = account
    data._version = 0
    ok, err = g_coll_obj:safe_insert(data)
    if not ok then
        log.warn("create role failed", "account", account, "rid", rid, "err", err)
        assert(user_db_api.remove_rid(account, rid))
        return false
    end

    log.info("create role success", "account", account, "rid", rid)
    return true
end

skynet.init(function()
    local name = config.get("role_db_name")
    local coll = config.get("role_db_coll")
    log.info("role_db_api init", "db", name, "coll", coll)
    g_coll_obj = mongo_conn.get_collection(name, coll)
end)

return M
