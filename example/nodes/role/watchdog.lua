local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local log = require "skyext.log"

local CMD = {}
local SOCKET = {}
local g_gate_service
local g_login_service
local g_entity_agentmgr_service
local g_clients = {}
local g_started = false
local g_starting = false

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
        -- kick 失败（gate 那边连接已经没了、或 gate 本身出错）不能挡住后面的 disconnect：
        -- forward 目标靠 disconnect 清掉 entity.fd，而 fd 还在的实体永远不会进卸载定时器，
        -- 漏发一次就是一个实体泄漏。
        local ok, err = pcall(skynet.call, g_gate_service, "lua", "kick", fd)
        if not ok then
            log.warn("kick client failed", "fd", fd, "err", err)
        end
        -- forward_service 可能已经退出，send 失败同样只记录，不让 close_client 抛错
        local sent, send_err = pcall(skynet.send, client.forward_service, "lua", "disconnect", fd)
        if not sent then
            log.error(
                "notify disconnect failed",
                "fd",
                fd,
                "service",
                tostring(client.forward_service),
                "err",
                send_err
            )
        end
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
    log.warn("socket warning", "fd", fd, "size", size)
end

function SOCKET.data(fd, msg)
    log.warn("socket data why in here", "fd", fd, "size", #msg)
end

function CMD.start(conf)
    if g_started then
        log.warn("watchdog already started, ignore duplicate start")
        return true
    end
    assert(not g_starting, "watchdog is starting")
    g_starting = true

    -- 先把依赖服务全部拉起来（agentmgr 的 start 返回即代表所有 entity_agent 已就绪），
    -- 最后才打开 gate 端口对外接受连接
    local ok, err = xpcall(function()
        skynet.call(
            g_login_service,
            "lua",
            "start",
            { watchdog = skynet.self(), roleagentmgr = g_entity_agentmgr_service }
        )
        skynet.call(g_entity_agentmgr_service, "lua", "start", { watchdog = skynet.self() })
        skynet.call(g_gate_service, "lua", "open", conf)
    end, debug.traceback)

    g_starting = false
    if not ok then
        log.error("watchdog start failed", "err", err)
        error(err, 0)
    end

    g_started = true
    log.info("watchdog started", "port", conf and conf.port)
    return true
end

function CMD.close_client(fd)
    close_client(fd)
end

function CMD.forward(fd, forward_service)
    assert(g_clients[fd], "forward: client not found " .. fd)
    g_clients[fd].forward_service = forward_service
    skynet.call(g_gate_service, "lua", "forward", fd, 0, forward_service)
end

skynet.start(function()
    cmd_api.dispatch_socket(CMD, SOCKET)

    g_gate_service = skynet.newservice("gate")
    g_login_service = skynet.newservice("login")
    g_entity_agentmgr_service = skynet.newservice("entity_agentmgr", "role")
end)
