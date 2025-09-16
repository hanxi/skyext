local skynet = require "skynet"
local http_server = require "http_server"
local config = require "config"
local launcher = require "launcher"
local log = require "log"

local function launcher_accountnode()
    local port = config.get_number("account_http_port") or 8080
    local agent_count = config.get_number("account_agent_count") or 8
    local conf = {
        port = port,
        agent_count = agent_count,
    }
    http_server.start(conf)
    http_server.register_router("account_router")
end

skynet.start(function()
    log.info("account start begin")
    launcher.launcher_node()
    launcher_accountnode()
    log.info("account start finished")
    skynet.exit()
end)

