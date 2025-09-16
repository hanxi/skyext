local skynet = require "skynet"
local sproto_api = require "sproto_api"
local cmd_api = require "cmd_api"
local client = require "client"
local login_request = require "login_request"
local global = require "global"
local log = require "log"

log.config {
    name = "login",
}

local CMD = {}

function CMD.start(conf)
    global.watchdog_service = conf.watchdog
    global.roleagentmgr_service = conf.roleagentmgr
    log.info("login service started", "watchdog", global.watchdog_service, "roleagentmgr", global.roleagentmgr_service)
end

function CMD.open(client_conf)
    log.info("new client", "fd", client_conf.fd, "addr", client_conf.addr)
    client.new(client_conf)
    skynet.call(global.watchdog_service, "lua", "forward", client_conf.fd, skynet.self())
    log.info("opened client", "fd", client_conf.fd, "addr", client_conf.addr)
end

function CMD.disconnect(fd)
    log.info("closing client", "fd", fd)
    client.unbind(fd)
end

skynet.start(function()
    sproto_api.register_module("login", client, login_request)
    cmd_api.dispatch(CMD)
end)
