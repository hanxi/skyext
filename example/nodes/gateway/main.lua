-- 独立的网关节点：只管客户端连接和登录，不承载实体。玩家的包经它转发到实体所在的逻辑节点
local skynet = require "skynet"
local log = require "skyext.log"
local launcher = require "launcher"

skynet.start(function()
    log.info("gateway start begin")
    launcher.launcher_node()
    launcher.launcher_gate()
    log.info("gateway start finished")
    skynet.exit()
end)
