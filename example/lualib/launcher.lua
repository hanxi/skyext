local skynet = require "skynet"
local log = require "skyext.log"
local node_shutdown_api = require "skyext.node_shutdown_api"

local M = {}

function M.launcher_node()
    log.info("launcher_node begin")
    -- metrics 先起：业务服务首次声明指标时就会去找 .metrics，晚一步它们得走重试
    skynet.newservice("metrics")
    skynet.newservice("gm")
    skynet.newservice("hotfix")
    -- 停服编排：GM 命令 shutdown 停止接入、卸载实体落库后退出进程
    node_shutdown_api.start()

    -- 创建 mongodb 索引
    local mongo_index = skynet.newservice("mongo_index")
    local all_ok = skynet.call(mongo_index, "lua", "create_indexes")
    assert(all_ok, "auto create indexes failed")
    skynet.kill(mongo_index)
    log.info("auto create indexes success")
end

return M
