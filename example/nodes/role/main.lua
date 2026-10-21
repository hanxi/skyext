local skynet = require "skynet"
local config = require "skyext.config"
local log = require "skyext.log"
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

-- 排行榜这类全局单例跑在 role 节点上：没有客户端直连，不需要 watchdog
local function launcher_rank()
    local rank_mgr = skynet.newservice("entity_agentmgr", "rank")
    skynet.call(rank_mgr, "lua", "start", {})
end

skynet.start(function()
    log.info("role start begin")
    launcher.launcher_node()
    launcher_rank()
    launcher_rolenode()
    log.info("role start finished")
    skynet.exit()
end)
