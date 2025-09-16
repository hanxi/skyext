local skynet = require "skynet"
local config = require "config"
local log = require "log"
local launcher = require "launcher"

local function launcher_rolenode()
    local watchdog = skynet.newservice("watchdog")
    local max_client = config.get_number("maxclient")
    local gate_port = config.get_number("gate_port")
    skynet.call(watchdog, "lua", "start", {
        port = gate_port,
        maxclient = max_client,
        nodelay = true,
    })
    log.info("watchdog listen", "gate_port", gate_port)
end

skynet.start(function()
    log.info("role start begin")
    launcher.launcher_node()
    launcher_rolenode()
    log.info("role start finished")
    skynet.exit()
end)
