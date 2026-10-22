local mongo_conn = require "skyext.mongo_conn"
local config = require "skyext.config"
local skynet = require "skynet"
local errcode = require "errcode"
local log = require "skyext.log"
local time = require "skyext.time"

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
    if user then
        return user.rids
    end
    return nil
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

-- 单个区服的建角名额。先读一遍再判断（读到 4 < 5 就放行）是典型的 TOCTOU：
-- 两个并发请求会读到同一个 4，双双放行，最后建出 6 个角色。
-- 这里把"判断"和"加一"压进一条 update：计数未达上限才匹配得上，匹配不上就是满了。
-- 返回 true（占到名额）、false（已满）或 nil, err（数据库出错）
function M.reserve_role_slot(account, server, max)
    local field = "role_count." .. server
    local query = {
        account = account,
        -- 第一次在这个服建角时字段还不存在，$lt 匹配不到，要显式放行
        ["$or"] = {
            { [field] = { ["$exists"] = false } },
            { [field] = { ["$lt"] = max } },
        },
    }
    local ok, err, r = g_coll_obj:safe_update(query, { ["$inc"] = { [field] = 1 } })
    if not ok then
        log.error("reserve role slot failed", "account", account, "server", server, "err", err)
        return nil, err
    end
    -- n 是匹配到的文档数：0 表示计数已经到上限（账号不存在也会是 0，调用方先保证账号已创建）
    return (r and r.n or 0) > 0
end

-- 建角失败时把名额还回去。
-- 注意这个计数和 role 集合里的实际角色数是两份数据：占到名额之后进程崩溃，
-- 这个名额就泄漏了，需要运维按 role 集合重算修正。换成完全不会漂移的做法要么依赖
-- 多文档事务（需要副本集），要么每次建角都全表数一遍，对示例来说都不划算。
function M.release_role_slot(account, server)
    local field = "role_count." .. server
    local ok, err = g_coll_obj:safe_update({ account = account }, { ["$inc"] = { [field] = -1 } })
    if not ok then
        log.error("release role slot failed", "account", account, "server", server, "err", err)
    end
end

function M.create(account)
    local obj = {
        account = account,
        create_time = time.now_ms(),
    }
    log.debug("begin create account", "account", account, "obj", obj)
    local ok, err, r = g_coll_obj:safe_insert(obj)
    log.info("end create account", "account", account, "ok", ok, "err", err, "r", r)
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
