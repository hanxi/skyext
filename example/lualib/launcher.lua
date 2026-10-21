local skynet = require "skynet"
local config = require "skyext.config"
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
    -- 区服目录：首次启动时把 realm_seed 写进 etcd，之后各服务查询时直接用
    skynet.uniqueservice("realm")

    -- 创建 mongodb 索引
    local mongo_index = skynet.newservice("mongo_index")
    local all_ok = skynet.call(mongo_index, "lua", "create_indexes")
    assert(all_ok, "auto create indexes failed")
    skynet.kill(mongo_index)
    log.info("auto create indexes success")
end

-- 客户端接入：session_gate 管连接，login 处理还没绑定的会话。
-- role 节点（同进程部署）和独立的 gate 节点都调这个；必须在本节点的实体就绪之后再调，
-- 端口一打开就会有玩家进来
function M.launcher_gate()
    local port = assert(config.get_number("gate_port"), "gate_port is not configured")
    local login = skynet.newservice("login")
    local gate = skynet.newservice("session_gate")
    skynet.call(login, "lua", "start", { gate = gate })
    skynet.call(gate, "lua", "open", {
        address = config.get("gate_host") or "0.0.0.0",
        port = port,
        maxclient = config.get_number("maxclient") or 1024,
        nodelay = true,
        login = login,
    })
    log.info("gate listening", "port", port)
end

return M
