-- WebSocket 网关：浏览器和小程序连接的落点。对外接口和 service/gate_tcp.lua 完全一致
-- （open / bind / push / kick / count，上行发 client_msg 和 session_closed），
-- 差别只在传输层，所以实体侧不需要知道客户端走的是哪一种。
--
-- **为什么不能和 gate_tcp 同一个服务**：snax.gateserver 注册 PTYPE_SOCKET 用的是
-- netpack.filter，而 http.websocket 依赖的 skynet.socket 也注册 PTYPE_SOCKET，
-- skynet.register_protocol 开头就 assert 没人占过。同一个服务里二选一，必须分开。
-- 分开也更合适：裸 TCP 那边的长度前缀是 C 层解的，原生客户端要的就是这个加速，
-- 不该为了省一个端口把它换成 Lua 手工解析。
--
-- **为什么是单个服务而不是 watchdog + agent 池**：实体给客户端发包时按 gate_service
-- 这个注册名直接找到网关（见 skyext.entity.session），单服务意味着下行一跳到位。
-- 拆成池子就得在 watchdog 上多转一次，而下行是热路径。WS 帧解析确实落在 Lua 里，
-- 单服务有吞吐上限，横向扩的单位是节点——这和 gate_tcp 的扩容方式一致。
local skynet = require "skynet"
local cluster = require "skynet.cluster"
local socket = require "skynet.socket"
local websocket = require "http.websocket"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local node_shutdown_api = require "skyext.node_shutdown_api"
local log = require "skyext.log"

-- 注册名。登录服务同时服务于两个网关，必须知道一条未绑定连接是从哪个网关来的，
-- 否则踢人会踢错进程。
local GATE_NAME = ".gate_ws"

local g_login
local g_listen_fd
local g_maxclient
local g_count = 0
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

local function close_session(fd)
    local session = g_sessions[fd]
    if not session then
        return
    end
    g_sessions[fd] = nil
    g_count = g_count - 1
    if session.owner_node then
        send_owner(session, "session_closed", self_node(), fd)
    else
        skynet.send(g_login, "lua", "disconnect", fd)
    end
end

-- websocket.accept 的回调，第一个参数都是 fd
local handler = {}

function handler.message(fd, msg, msg_type)
    local session = g_sessions[fd]
    if not session then
        return
    end
    -- 协议是二进制 sproto。文本帧多半是接错了端口或者客户端用了 JSON，直接断开比
    -- 让它在后面某个解码器里炸掉清楚
    if msg_type ~= "binary" then
        log.warn("ws client sent a non-binary frame", "fd", fd, "type", msg_type)
        websocket.close(fd, 1003, "binary only")
        return
    end
    if session.owner_node then
        send_owner(session, "client_msg", self_node(), fd, msg)
    else
        skynet.send(g_login, "lua", "client_msg", fd, msg)
    end
end

function handler.close(fd)
    close_session(fd)
end

function handler.error(fd, err)
    log.warn("ws session error", "fd", fd, "err", err)
    close_session(fd)
end

-- 这个回调拿到的第一个参数是 ws 对象而不是 fd（websocket.lua 的历史遗留）
function handler.warning(ws, size)
    log.warn("ws send buffer is piling up", "fd", ws.id, "size", size)
end

local function serve(fd, addr, protocol)
    g_sessions[fd] = { fd = fd, addr = addr }
    g_count = g_count + 1
    skynet.send(g_login, "lua", "open", fd, addr, GATE_NAME)
    -- accept 一直阻塞到连接关闭，所以每条连接占一个协程
    local ok, err = websocket.accept(fd, handler, protocol, addr)
    if not ok then
        -- 握手阶段就失败了（不是 WS 请求、TLS 握手不过）。这时 handler.close 不会被调用
        log.warn("ws handshake failed", "fd", fd, "addr", addr, "err", err)
    end
    close_session(fd)
end

local CMD = {}

function CMD.open(conf)
    g_login = assert(conf.login, "gate_ws needs conf.login")
    g_maxclient = conf.maxclient or 1024
    local protocol = conf.protocol or "ws"
    assert(protocol == "ws" or protocol == "wss", "ws_protocol must be ws or wss")
    if protocol == "wss" then
        -- TLS 握手在 ltls 里做，没开的话第一个 wss 连接才会炸，太晚了
        -- bootstrap 比的也是字符串 "true"
        assert(skynet.getenv("enablessl") == "true", "wss needs enablessl = true in the node config")
        -- websocket.lua 只认 skynet env 里的证书路径，没有别的入口。env 里已经有值
        -- （直接写在节点配置里）时以它为准：skynet.setenv 不允许覆盖已存在的键
        if not skynet.getenv("certfile") then
            skynet.setenv("certfile", assert(conf.certfile, "wss needs ws_certfile"))
        end
        if not skynet.getenv("keyfile") then
            skynet.setenv("keyfile", assert(conf.keyfile, "wss needs ws_keyfile"))
        end
    end

    local address = conf.address or "0.0.0.0"
    g_listen_fd = socket.listen(address, conf.port)
    socket.start(g_listen_fd, function(fd, addr)
        if g_count >= g_maxclient then
            log.warn("ws gate is full, dropping a new connection", "addr", addr, "maxclient", g_maxclient)
            socket.close_fd(fd)
            return
        end
        -- 这个回调跑在 socket 消息的分发协程里，阻塞它就收不到后续的 accept
        skynet.fork(serve, fd, addr, protocol)
    end)
    log.info("ws gate listening", "address", address, "port", conf.port, "protocol", protocol)
end

-- 会话绑定到实体：之后的包原样转发给 owner。会话已经断开时返回 false
function CMD.bind(fd, owner_node, owner_service)
    local session = g_sessions[fd]
    if not session then
        return false
    end
    session.owner_node, session.owner_service = owner_node, owner_service
    return true
end

-- 发给客户端一个已经编码好的包（回包或推送）。WS 帧自带边界，不加长度头
function CMD.push(fd, pack)
    if not g_sessions[fd] then
        return
    end
    -- 写可能撞上连接正在关闭：这条连接的协程会走正常的断开流程，这里不能连累调用方
    local ok, err = pcall(websocket.write, fd, pack, "binary")
    if not ok then
        log.warn("ws push failed", "fd", fd, "err", err)
    end
end

-- 断开连接。断开回调照常走：未绑定的通知登录服务，已绑定的通知 owner
function CMD.kick(fd)
    if g_sessions[fd] then
        websocket.close(fd, 1000, "kicked")
    end
end

function CMD.count()
    return g_count
end

-- 停服第一步：关掉监听端口，不再接新连接。已经建立的连接继续服务到实体卸载
function CMD.close()
    if g_listen_fd then
        socket.close(g_listen_fd)
        g_listen_fd = nil
        log.info("ws gate stopped accepting")
    end
end

skynet.start(function()
    cmd_api.dispatch(CMD)
    -- 实体侧按这个名字找本节点的网关（跨节点时 cluster.send(node, ".gate_ws", ...)）
    skynet.register(GATE_NAME)
    skynet.fork(function()
        node_shutdown_api.add_hook("stop_accepting", "close")
    end)
end)
