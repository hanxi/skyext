local skynet = require "skynet"
local timer = require "skyext.timer"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

-- 已连接但还没绑定到实体的客户端，fd -> { fd, addr, gate }。
-- gate 是来源网关的注册名（.gate_tcp / .gate_ws）：两个网关共用一个登录服务，
-- 踢人必须踢回原来那个网关。
-- 登录服务只负责握手；登录成功后会话移交给实体，客户端从这里移除（见 M.unbind）。
local g_clients = {}

-- fd -> 来源网关的注册名。比 g_clients 活得久：登录成功时 g_clients 里的记录当场就删了，
-- 但那次登录的响应还没发出去，发它还要用网关
local g_gates = {}

function M.new(conf)
    local fd = conf.fd
    assert(not g_clients[fd], fd .. " exists")
    g_clients[fd] = conf
    g_gates[fd] = conf.gate
    log.info("new client created", "fd", fd, "addr", conf.addr)
    -- 超时仍未完成登录就踢掉，避免半开连接长期占用 gate
    local login_timeout_sec = config.get_number("login_timeout_sec") or 60
    timer.timeout("login_timeout", login_timeout_sec, function()
        if not g_clients[fd] then
            return
        end
        log.error("client login timeout", "fd", fd)
        skynet.send(conf.gate, "lua", "kick", fd)
    end)
    return g_clients[fd]
end

-- 登录成功（会话已移交实体）或连接断开后，停止跟踪该客户端
function M.unbind(fd)
    g_clients[fd] = nil
    log.info("login client unbound", "fd", fd)
end

-- 连接断了。和 M.unbind 的区别：unbind 只表示"不再是待登录客户端"（登录成功也会调），
-- 这个表示 fd 已经没了
function M.closed(fd)
    g_gates[fd] = nil
    M.unbind(fd)
end

-- 登录阶段的回包一律经网关发出。裸 TCP 和 WebSocket 的帧格式不一样，登录服务不知道
-- 也不该知道某条连接是哪一种——网关知道。直接往 socket 里写 netpack 包的老做法在
-- WS 连接上发的是乱码，客户端只会一直等到超时
function M.sender(fd, pack)
    local gate = g_gates[fd]
    if not gate then
        log.warn("dropping a response for a connection the login service no longer knows", "fd", fd)
        return
    end
    if not g_clients[fd] then
        -- 这条连接已经移交给实体了，这是登录服务在它上面发的最后一个包
        g_gates[fd] = nil
    end
    skynet.send(gate, "lua", "push", fd, pack)
end

-- sproto_api 把返回值作为 obj 透传给协议 handler
function M.get_obj(fd)
    return g_clients[fd]
end

return M
