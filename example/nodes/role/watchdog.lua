local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local gm_api = require "skyext.gm_api"
local cluster_discovery = require "skyext.cluster_discovery"
local router = require "skyext.entity.router"
local time = require "skyext.time"
local log = require "skyext.log"

local CMD = {}
local SOCKET = {}
local g_gate_service
local g_login_service
local g_entity_agentmgr_service
local g_clients = {}
local g_started = false
local g_starting = false
local g_shutting_down = false

-- 等实体卸载的默认时长（秒）
local SHUTDOWN_TIMEOUT = 60

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

-- 停服顺序：先停止接受新连接，再卸载全部实体（落库、释放锁、踢掉在线玩家），
-- 全部卸干净才退出进程。有实体卸不掉就不退：那些实体还有没落库的改动，
-- 退出就丢了。排查后可以再发一次 shutdown。
local function shutdown(timeout_sec)
    log.info("node shutdown begin", "timeout", timeout_sec)
    local closed, close_err = pcall(skynet.call, g_gate_service, "lua", "close")
    if not closed then
        log.warn("gate close failed", "err", close_err)
    end
    local ok, remaining = pcall(skynet.call, g_entity_agentmgr_service, "lua", "shutdown", timeout_sec)
    if not ok or remaining ~= 0 then
        log.error("node shutdown incomplete, process kept alive", "remaining", remaining)
        g_shutting_down = false
        return
    end
    -- 撤销服务发现租约，别的节点立刻看到本节点下线，不用等 30 秒过期
    local revoked, revoke_err = pcall(cluster_discovery.shutdown)
    if not revoked then
        log.warn("cluster discovery shutdown failed", "err", revoke_err)
    end
    log.info("node shutdown complete, exiting")
    -- 退出前让 logger 把缓冲写完
    pcall(skynet.call, ".logger", "lua", "close")
    skynet.abort()
end

local GM_CMD = {}

GM_CMD.shutdown = {
    desc = "停服：停止接入、卸载全部实体落库后退出进程",
    params = { timeout = "等实体卸载的秒数，默认 60" },
    handler = function(params)
        if g_shutting_down then
            return false, "already shutting down"
        end
        g_shutting_down = true
        -- 卸载可能要几十秒，不能让 GM 请求一直挂着，进度看日志
        skynet.fork(shutdown, tonumber(params.timeout) or SHUTDOWN_TIMEOUT)
        return true, "shutdown started"
    end,
}

-- 非实体服务给实体发可靠消息的示范：消息落库后由收件人自己的 handler 收下
GM_CMD.send_mail = {
    desc = "给玩家发一封系统邮件，可带一个附件",
    params = {
        rid = "收件人",
        title = "标题",
        content = "正文",
        res_type = "附件资源分类（可选）",
        res_id = "附件资源id（可选）",
        res_size = "附件数量（可选）",
    },
    handler = function(params)
        local rid = math.tointeger(tonumber(params.rid))
        if not rid or type(params.title) ~= "string" or params.title == "" then
            return false, "rid and title are required"
        end
        -- role_db_api 加载时就会连 mongo，只在真要发邮件时才拉进来
        local role_db_api = require "role_db_api"
        if not role_db_api.exists(rid) then
            return false, "role not found"
        end
        local attach
        if params.res_type then
            local res_type = math.tointeger(tonumber(params.res_type))
            local res_id = math.tointeger(tonumber(params.res_id))
            local res_size = math.tointeger(tonumber(params.res_size))
            if not res_type or not res_id or not res_size or res_size <= 0 then
                return false, "invalid attachment"
            end
            attach = { { res_type = res_type, res_id = res_id, res_size = res_size } }
        end
        local mail = {
            title = params.title,
            content = params.content,
            send_time = time.now_ms(),
            attach = attach,
        }
        return true, router.reliable_send("role", rid, "recv_mail", { mail })
    end,
}

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
    gm_api.register(GM_CMD)
end)
