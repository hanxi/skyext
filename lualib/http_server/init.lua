local skynet = require "skynet"
local service = require "skynet.service"
local watchdog = require "http_server.watchdog"
local log = require "log"

local M = {}

function M.start(conf)
    local watchdog = service.new("http_watchdog", watchdog)
    skynet.call(watchdog, "lua", "start", conf)
end

function M.register_router(router_name)
    local watchdog = service.query("http_watchdog")
    if not watchdog then
        log.error("http_watchdog not exist", "router_name", router_name)
        return
    end
    skynet.call(watchdog, "lua", "register_router", router_name)
end

return M
