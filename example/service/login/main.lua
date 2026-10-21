-- 登录服务：处理还没绑定到实体的会话。session_gate 把未绑定会话的包交给这里，
-- 鉴权通过后经 router.bind_session 把会话绑到角色实体上，之后的包由 gate 直接转给实体。
-- role 节点（同进程部署）和独立的 gate 节点共用这个服务。
local sproto_api = require "skyext.sproto_api"
local cmd_api = require "skyext.cmd_api"
local skynet = require "skynet"
local client = require "client"
local login_request = require "login_request"
local global = require "global"
local log = require "skyext.log"

log.config {
    name = "login",
}

local CMD = {}

function CMD.start(conf)
    global.gate_service = assert(conf.gate, "login needs conf.gate")
    log.info("login service started", "gate", global.gate_service)
end

function CMD.open(fd, addr)
    client.new({ fd = fd, addr = addr })
end

function CMD.client_msg(fd, data)
    sproto_api.dispatch_message(fd, data)
end

function CMD.disconnect(fd)
    client.unbind(fd)
end

skynet.start(function()
    sproto_api.register_module("login", client, login_request)
    cmd_api.dispatch(CMD)
end)
