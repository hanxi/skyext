local skynet = require "skynet"
local config = require "config"
local log = require "log"

skynet.start(function()
    log.info("robot start")
    if not config.get("daemon") then
        local console = skynet.newservice("console")
    end

    local robot_count = config.get_number("robot_count") or 1
    for i = 1, robot_count do
        local robotagent = skynet.newservice("robot/robotagent")
        skynet.call(robotagent, "lua", "start", {
            id = i,
            name = "robot_" .. i,
        })
        log.info("robot service started", "id", i)
    end

    skynet.exit()
end)
