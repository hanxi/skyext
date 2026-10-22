local mongo_conn = require "skyext.mongo_conn"
local user_db_api = require "user_db_api"
local skynet = require "skynet"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}
local g_coll_obj
local g_default_projection = { _id = false, rid = 1, server = 1 }

-- 查询条件和投影都复制一份再改：调用方常常把同一张表传两次（先查列表再查单个），
-- 就地改会让第二次查询带上第一次留下的条件
local function with_field(tbl, key, value)
    local copy = {}
    if tbl then
        for k, v in pairs(tbl) do
            copy[k] = v
        end
    end
    copy[key] = value
    return copy
end

-- 从数据库读取角色列表。query.rid 可选：指定了就只查那一个角色，
-- 但必须是这个账号自己的角色
function M.get_roles(account, query, projection)
    projection = projection and with_field(projection, "_id", false) or g_default_projection

    local rids = user_db_api.get_rids(account)
    local ret = {}
    if not rids or #rids == 0 then
        return ret
    end

    -- 账号范围始终由 rids 决定。调用方指定的 rid 只能在其中挑一个，
    -- 不然传一个别人的 rid 就能查到别人的角色；
    -- 同时这一步也保证了下面不会用 $in 把调用方指定的 rid 冲掉
    local wanted = query and query.rid
    if wanted ~= nil then
        local owned = false
        for _, rid in ipairs(rids) do
            if rid == wanted then
                owned = true
                break
            end
        end
        if not owned then
            return ret
        end
        rids = { wanted }
    end

    if #rids == 1 then
        local rid = rids[1]
        log.debug("get_roles", "account", account, "rid", rid)
        local data = g_coll_obj:find_one(with_field(query, "rid", rid), projection)
        if data then
            ret[1] = data
        else
            log.info("role not found by account", "account", account, "rid", rid)
        end
        log.debug("get_roles", "account", account, "rid", rid, "ret", ret)
        return ret
    end

    return g_coll_obj:find(with_field(query, "rid", { ["$in"] = rids }), projection)
end

-- 角色是否属于这个账号、这个区服。JWT 只证明了账号，rid 和 server 是客户端自己报的，
-- 登录时不查这一步，拿自己的 token 就能登别人的角色
function M.has_role(rid, account, server)
    local data = g_coll_obj:find_one({ rid = rid }, { _id = false, account = 1, server = 1 })
    return data ~= nil and data.account == account and data.server == server
end

function M.exists(rid)
    return g_coll_obj:find_one({ rid = rid }, { _id = false, rid = 1 }) ~= nil
end

-- 先写角色文档，再把 rid 挂到账号上：中途失败最多留下一份谁也看不见的角色文档，
-- 反过来则会在账号上留下指向空气的 rid
function M.create(rid, account, data)
    data = data or {}
    data.rid = rid
    data.account = account
    data._version = 0
    local ok, err = g_coll_obj:safe_insert(data)
    if not ok then
        log.warn("create role failed", "account", account, "rid", rid, "err", err)
        return false
    end
    ok, err = user_db_api.add_rid(account, rid)
    if not ok then
        log.error("create role failed by add rid", "account", account, "rid", rid, "err", err)
        g_coll_obj:safe_delete({ rid = rid }, true)
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
