local skynet = require "skynet"
local cmd_api = require "cmd_api"
local log = require "log"

local CMD = {}
local SOCKET = {}
local g_gate_service
local g_login_service
local g_roleagentmgr_service
local g_clients = {}

function SOCKET.open(fd, addr)
    assert(not g_clients[fd], fd .. " exists")

    log.info("new client", "fd", fd, "addr", addr)
    local client = {
        fd = fd,
        addr = addr,
    }
    g_clients[fd] = client
    skynet.call(g_login_service, "lua", "open", client)
end

local function close_client(fd)
    if not g_clients[fd] then
        log.warn("close_client client not found", "fd", fd)
        return
    end

    local client = g_clients[fd]
    g_clients[fd] = nil

    if client.forward_service then
        skynet.call(g_gate_service, "lua", "kick", fd)
        skynet.send(client.forward_service, "lua", "disconnect", fd)
    end
end

function SOCKET.close(fd)
    log.info("socket close", "fd", fd)
    close_client(fd)
end

function SOCKET.error(fd, msg)
    log.warn("socket error", "fd", fd, "msg", msg)
    close_client(fd)
end

function SOCKET.warning(fd, size)
    -- size K bytes havn't send out in fd
    log.warn("socket warning", "fd", fd, "size", size)
end

function SOCKET.data(fd, msg)
    log.warn("socket data why in here", "fd", fd, "size", #msg)
end

function CMD.start(conf)
    skynet.call(g_login_service, "lua", "start", { watchdog = skynet.self(), roleagentmgr = g_roleagentmgr_service })
    skynet.call(g_roleagentmgr_service, "lua", "start", { watchdog = skynet.self() })
    skynet.call(g_gate_service, "lua", "open", conf)
end

function CMD.close_client(fd)
    close_client(fd)
end

-- Forward the client to service
function CMD.forward(fd, forward_service)
    assert(g_clients[fd], "forward: client not found " .. fd)
    g_clients[fd].forward_service = forward_service
    skynet.call(g_gate_service, "lua", "forward", fd, 0, forward_service)
end

skynet.start(function()
    cmd_api.dispatch_socket(CMD, SOCKET)

    g_gate_service = skynet.newservice("gate")
    g_login_service = skynet.newservice("login")
    g_roleagentmgr_service = skynet.newservice("roleagentmgr")
end)
