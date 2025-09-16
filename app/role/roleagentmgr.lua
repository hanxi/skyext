local skynet = require "skynet"
local cmd_api = require "cmd_api"
local cluster_discovery = require "cluster_discovery"
local errcode = require "errcode"
local config = require "config"
local log = require "log"
local roleagent_api = require "roleagent_api"

log.config {
    name = "roleagentmgr",
}

local CMD = {}
local g_agents = {}
local g_watchdog_service

function CMD.start(conf)
    g_watchdog_service = conf.watchdog
    local agent_count = config.get_number("agent_count") or 2
    for i = 1, agent_count do
        local agent_name = roleagent_api.format_agent_name(i)
        local agent = skynet.newservice(agent_name, i)
        skynet.call(agent, "lua", "start", {
            watchdog = g_watchdog_service,
            roleagentmgr = skynet.self(),
        })
        g_agents[i] = agent
        log.info("role agent service started", "agent", agent, "i", i)
    end
end

skynet.start(function()
    cmd_api.dispatch(CMD)
    cluster_discovery.register({ "roleagentmgr" })
end)
