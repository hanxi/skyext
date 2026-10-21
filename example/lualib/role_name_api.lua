-- 角色名表：名字在出生服内唯一（(server, name) 唯一索引）。
-- 不同服可以重名，所以合服、跨服都不会撞名；跨服场景里显示成 [S3]张三 来区分。
local skynet = require "skynet"
local mongo_conn = require "skyext.mongo_conn"
local realm = require "skyext.realm"
local config = require "skyext.config"
local errcode = require "errcode"
local log = require "skyext.log"

local M = {}

local COLL = "role_name"
local g_coll

-- 占用一个名字。返回 true，或 false, "taken"（已被占用）/ 其他错误
function M.reserve(server, name, rid)
    local ok, err, reply = g_coll:safe_insert({ server = server, name = name, rid = rid })
    if ok then
        return true
    end
    local write_errors = reply and reply.writeErrors
    if write_errors and write_errors[1].code == errcode.MONGO_DUPLICATE_KEY then
        return false, "taken"
    end
    log.error("reserve role name failed", "server", server, "err", err)
    return false, err or "database error"
end

-- 建角失败时把名字还回去
function M.release(server, name)
    local ok, err = pcall(g_coll.safe_delete, g_coll, { server = server, name = name }, true)
    if not ok then
        log.error("release role name failed", "server", server, "err", err)
    end
end

-- 跨服场景里的显示名，比如 [S3]张三。本服场景直接显示 name
function M.display(server, name)
    return string.format("[%s]%s", realm.tag_of(server), name)
end

skynet.init(function()
    g_coll = mongo_conn.get_collection(config.get("user_db_name"), COLL)
end)

return M
