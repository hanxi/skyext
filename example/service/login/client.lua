local skynet = require "skynet"
local timer = require "skyext.timer"
local global = require "global"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

-- 已连接但还没绑定到实体的客户端，fd -> { fd, addr }。
-- 登录服务只负责握手；登录成功后会话移交给实体，客户端从这里移除（见 M.unbind）。
local g_clients = {}

function M.new(conf)
    local fd = conf.fd
    assert(not g_clients[fd], fd .. " exists")
    g_clients[fd] = conf
    log.info("new client created", "fd", fd, "addr", conf.addr)
    -- 超时仍未完成登录就踢掉，避免半开连接长期占用 gate
    local login_timeout_sec = config.get_number("login_timeout_sec") or 60
    timer.timeout("login_timeout", login_timeout_sec, function()
        if not g_clients[fd] then
            return
        end
        log.error("client login timeout", "fd", fd)
        skynet.send(global.gate_service, "lua", "kick", fd)
    end)
    return g_clients[fd]
end

-- 登录成功（会话已移交实体）或连接断开后，停止跟踪该客户端
function M.unbind(fd)
    g_clients[fd] = nil
    log.info("login client unbound", "fd", fd)
end

-- sproto_api 把返回值作为 obj 透传给协议 handler
function M.get_obj(fd)
    return g_clients[fd]
end

return M
