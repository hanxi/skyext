-- 裸 TCP 网关：原生客户端连接的落点，只管连接，不持有玩法状态。
-- 浏览器和小程序走 service/gate_ws.lua，两者对外接口一致，差别只在传输层。
--
-- 每条连接是一个会话 fd -> { owner_node, owner_service }：
--   * 还没绑定：包交给登录服务（conf.login），由它完成鉴权并把会话绑到实体上；
--   * 绑定之后：包原样转发给实体所在的节点（同节点 skynet.send，跨节点 cluster.send），
--     不解码协议，协议热更不用动网关。同一个会话固定发往一个 owner，消息天然保序。
-- 实体侧通过 bind / push / kick 操作会话（见 skyext.entity.session）。
-- gate 可以和实体同进程部署，也可以单独起节点，代码路径相同。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local gateserver = require "snax.gateserver"
local netpack = require "skynet.netpack"
local socketdriver = require "skynet.socketdriver"
local config = require "skyext.config"
local node_shutdown_api = require "skyext.node_shutdown_api"
local log = require "skyext.log"

-- 注册名。登录服务同时服务于两个网关，必须知道一条未绑定连接是从哪个网关来的，
-- 否则踢人会踢错进程。
local GATE_NAME = ".gate_tcp"

local g_login
local g_sessions = {}

local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = assert(config.get("cluster_node_name"), "cluster_node_name is not configured")
    end
    return g_self_node
end

local function send_owner(session, cmd, ...)
    if session.owner_node == self_node() then
        skynet.send(session.owner_service, "lua", cmd, ...)
        return
    end
    -- 目标节点不可达时 cluster.send 会抛错：这个包丢了，客户端超时后会重试或重连，
    -- 不能让整个网关跟着出错
    local ok, err = pcall(cluster.send, session.owner_node, session.owner_service, cmd, ...)
    if not ok then
        log.warn("session forward failed", "fd", session.fd, "owner", session.owner_node, "cmd", cmd, "err", err)
    end
end

local handler = { embed = true }

function handler.open(_, conf)
    g_login = assert(conf.login, "gate_tcp needs conf.login")
    log.info("tcp gate listening", "address", conf.address, "port", conf.port)
end

function handler.connect(fd, addr)
    g_sessions[fd] = { fd = fd, addr = addr }
    gateserver.openclient(fd)
    skynet.send(g_login, "lua", "open", fd, addr, GATE_NAME)
end

function handler.message(fd, msg, sz)
    -- netpack.tostring 复制一份并释放原始缓冲
    local data = netpack.tostring(msg, sz)
    local session = g_sessions[fd]
    if not session then
        return
    end
    if session.owner_node then
        send_owner(session, "client_msg", self_node(), fd, data)
    else
        skynet.send(g_login, "lua", "client_msg", fd, data)
    end
end

local function close_session(fd)
    local session = g_sessions[fd]
    if not session then
        return
    end
    g_sessions[fd] = nil
    if session.owner_node then
        send_owner(session, "session_closed", self_node(), fd)
    else
        skynet.send(g_login, "lua", "disconnect", fd)
    end
end

function handler.disconnect(fd)
    close_session(fd)
end

function handler.error(fd, msg)
    log.warn("session socket error", "fd", fd, "msg", msg)
    close_session(fd)
end

function handler.warning(fd, size)
    log.warn("session send buffer is piling up", "fd", fd, "size", size)
end

local CMD = {}

-- 会话绑定到实体：之后的包原样转发给 owner。会话已经断开时返回 false
function CMD.bind(fd, owner_node, owner_service)
    local session = g_sessions[fd]
    if not session then
        return false
    end
    session.owner_node, session.owner_service = owner_node, owner_service
    return true
end

-- 发给客户端一个已经编码好的包（回包或推送）
function CMD.push(fd, pack)
    if not g_sessions[fd] then
        return
    end
    local data, sz = netpack.pack(pack)
    socketdriver.send(fd, data, sz)
end

-- 断开连接。断开回调照常走：未绑定的通知登录服务，已绑定的通知 owner
function CMD.kick(fd)
    if g_sessions[fd] then
        gateserver.closeclient(fd)
    end
end

function CMD.count()
    local n = 0
    for _ in pairs(g_sessions) do
        n = n + 1
    end
    return n
end

function handler.command(cmd, _, ...)
    local f = CMD[cmd]
    if not f then
        error(string.format("unknown gate_tcp command: %s", tostring(cmd)))
    end
    return f(...)
end

skynet.start(function()
    gateserver.start(handler)
    -- 实体侧按这个名字找本节点的网关（跨节点时 cluster.send(node, ".gate_tcp", ...)）
    skynet.register(GATE_NAME)
    -- 停服第一步：关掉监听端口，不再接新连接（gateserver 内置的 close）
    skynet.fork(function()
        node_shutdown_api.add_hook("stop_accepting", "close")
    end)
end)
