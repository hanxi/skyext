local skynet = require "skynet"
local config = require "config"
local log = require "log"

local M = {}

function M.launcher_node()
    log.info("launcher_node begin")

    local debug_console_port = config.get_number("debug_console_port")
    log.info("debug console listen", "debug_console_port", debug_console_port)
    skynet.newservice("debug_console", debug_console_port)

    -- 创建 mongodb 索引
    local mongo_index = skynet.newservice("mongo_index")
    local all_ok = skynet.call(mongo_index, "lua", "create_indexes")
    assert(all_ok, "auto create indexes failed")
    skynet.kill(mongo_index)
    log.info("auto create indexes success")
end

return M
