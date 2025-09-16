local skynet = require "skynet"
local timer = require "timer"
local global = require "global"
local config = require "config"
local log = require "log"

local M = {}

local g_clients = {}

local client = {}
client.__index = client

local function new_client_obj(conf)
    return setmetatable(conf, client)
end

function client:check_auth()
    return self.auth
end

function client:set_authed(account)
    self.account = account
    self.auth = true
    log.info("client authenticated", "fd", self.fd, "account", account)
end

function M.unbind(fd)
    g_clients[fd] = nil
    log.info("login client unbiund", "fd", fd)
end

function M.new(conf)
    local fd = conf.fd
    assert(not g_clients[fd], fd .. " exists")
    g_clients[fd] = new_client_obj(conf)
    log.info("new client created", fd, fd)
    local login_timeout_sec = config.get_number("login_timeout_sec") or 60 -- default login timeout 60 seconds
    timer.timeout("login_timeout", login_timeout_sec, function()
        if not g_clients[fd] then
            return
        end

        log.error("client auth timeout", "fd", fd)
        skynet.call(global.watchdog_service, "lua", "close_client", fd)
    end)
    return g_clients[fd]
end

function M.get_obj(fd)
    log.debug("get client object", "fd", fd, "obj", g_clients[fd])
    return g_clients[fd]
end

local noauth_request = {
    ["login.login"] = true,
    ["login.report_remote_addr"] = true,
}
local function check_auth_cb(request_name, request, fd, client_obj)
    if noauth_request[request_name] then
        return true
    end

    if (not client_obj) or (not client_obj:check_auth()) then
        log.warn("unauthorized access", "fd", fd, "request_name", request_name)
        return nil, "Unauthorized"
    end
    return true
end

M.middleware_cbs = {
    check_auth_cb,
}

return M
