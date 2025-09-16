local skynet = require "skynet"
local role = require "modules.role"
local client = require "client"
local dbmgr = require "dbmgr"
local config = require "config"
local log = require "log"
local modules = require "modules"

local M = {}

local g_role_db_name = config.get("role_db_name")
local g_role_db_coll = config.get("role_db_coll")

local g_roles = {}

function M.load_role(rid)
    if g_roles[rid] then
        log.info("load role already exists", "rid", rid)
        return g_roles[rid]
    end

    local role_data = dbmgr.load(g_role_db_name, g_role_db_coll, "rid", rid)
    local role_obj = role.new(M, rid, role_data)
    g_roles[rid] = role_obj
    modules.load(role_obj, role_data)
    return role_obj
end

function M.get_role(rid)
    return g_roles[rid]
end

function M.unload_role(rid)
    local role_obj = g_roles[rid]
    if not role_obj then
        log.warn("unload role not exists", "rid", rid)
        return
    end
    if role_obj.fd then
        client.unbind_kick(role_obj.fd)
    end

    -- save_obj
    dbmgr.unload(g_role_db_name, g_role_db_coll, "rid", rid)

    -- TODO: role_obj 支持 lazy_load 数据,在默认情况下不加载，在使用时才加载.
    -- lazy_load_data 加载晚，卸载早
    -- 一般用于一些不常用的数据

    g_roles[rid] = nil

    log.info("unloading role", "rid", rid)
end

return M
