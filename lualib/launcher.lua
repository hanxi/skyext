local skynet = require "skynet"
local config = require "config"
local log = require "log"

local M = {}

function M.launcher_node()
    log.info("launcher_node begin")
    skynet.newservice("gm")

    -- 创建 mongodb 索引
    local mongo_index = skynet.newservice("mongo_index")
    local all_ok = skynet.call(mongo_index, "lua", "create_indexes")
    assert(all_ok, "auto create indexes failed")
    skynet.kill(mongo_index)
    log.info("auto create indexes success")
end

return M
