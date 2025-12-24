local mongo_conn = require "mongo_conn"
local config = require "config"
local skynet = require "skynet"
local errcode = require "errcode"
local log = require "log"
local time = require "time"

local M = {}
local g_coll_obj
local g_default_projection = { _id = false }

function M.get(account, projection)
    assert(account)
    projection = projection or g_default_projection
    log.debug("get account", "account", account, "projection", projection)
    return g_coll_obj:find_one({ account = account }, projection)
end

function M.get_rids(account)
    local user = M.get(account, { _id = false, rids = 1 })
    log.debug("get_rids", "account", account, "user", user)
    assert(user, account)
    return user.rids
end

function M.add_rid(account, rid)
    local update = {
        ["$addToSet"] = {
            rids = rid,
        },
    }
    return g_coll_obj:safe_update({ account = account }, update)
end

function M.remove_rid(account, rid)
    local update = {
        ["$pull"] = {
            rids = rid,
        },
    }
    return g_coll_obj:safe_update({ account = account }, update)
end

function M.create(account)
    local obj = {
        account = account,
        create_time = time.now_ms(),
    }
    log.debug("begin create account", "account", account, "obj", obj)
    local ok, err, r = g_coll_obj:safe_insert(obj)
    log.info("end create account", "account", "ok", ok, "err", err, "r", r)
    if not ok then
        return false, err, r
    end
    return obj
end

function M.ensure_get_user(account)
    -- 已有账号，直接返回
    local user = M.get(account)
    if user then
        return user
    end

    -- 创建账号
    local err, r
    user, err, r = M.create(account)
    if user then
        return user
    end

    -- 创建失败，如果是因为并发创建，则重试读取
    local werror = r.writeErrors
    if werror and werror[1].code == errcode.MONGO_DUPLICATE_KEY then
        return M.get(account)
    end
    log.error("get_user failed", "account", account, "err", err, "r", r)
end

skynet.init(function()
    local name = config.get("user_db_name")
    local coll = config.get("user_db_coll")
    log.info("user_db_api init", "db", name, "coll", coll)
    g_coll_obj = mongo_conn.get_collection(name, coll)
end)

return M
