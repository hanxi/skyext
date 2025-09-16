local skynet = require "skynet"
local global = require "global"
local log = require "log"

local M = {}

local g_clients = {}

local client = {}
client.__index = client

local function new_client_obj(fd, role_obj)
    local obj = {
        fd = fd,
        role_obj = role_obj,
    }
    return setmetatable(obj, client)
end

function M.unbind(fd)
    local client_obj = g_clients[fd]
    log.info("unbinding begin client", "fd", fd, "client_obj", client_obj)
    if client_obj and client_obj.role_obj then
        log.info("unbinding client fd", "fd", fd)
        client_obj.role_obj:unbind_fd()
    end
    g_clients[fd] = nil
end

function M.unbind_kick(fd)
    M.unbind(fd)
    -- 断开客户端连接
    skynet.call(global.watchdog_service, "lua", "close_client", fd)
end

function M.bind(fd, role_obj)
    assert(not g_clients[fd], fd .. " exists")
    -- bind fd to role_obj
    role_obj:bind_fd(fd)
    g_clients[fd] = new_client_obj(fd, role_obj)
    log.info("binding client", "fd", fd, "rid", role_obj.rid, "name", role_obj.data.name)
    return g_clients[fd]
end

function M.get_obj(fd)
    return g_clients[fd]
end

return M
