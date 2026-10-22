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

-- 客户端接入：网关管连接，login 处理还没绑定的会话。
-- 原生客户端走 gate_tcp，浏览器和小程序走 gate_ws，两个网关共用同一个 login
-- （它持有 realm 订阅和 JWT 状态，复制一份不划算）。
-- role 节点（同进程部署）和独立的 gate 节点都调这个；必须在本节点的实体就绪之后再调，
-- 端口一打开就会有玩家进来
function M.launcher_gate()
    local host = config.get("gate_host") or "0.0.0.0"
    local maxclient = config.get_number("maxclient") or 1024
    local login = skynet.newservice("login")
    -- 下发给客户端的地址。监听地址通常是 0.0.0.0，对客户端没有意义
    local public_host = config.get("gate_public_host")
        or assert(config.get("cluster_host"), "cluster_host is not configured")
    local gate_info = {}

    local port = assert(config.get_number("gate_port"), "gate_port is not configured")
    local gate = skynet.newservice("gate_tcp")
    skynet.call(gate, "lua", "open", {
        address = host,
        port = port,
        maxclient = maxclient,
        nodelay = true,
        login = login,
    })
    gate_info.tcp_addr = public_host .. ":" .. port
    log.info("tcp gate listening", "port", port)

    -- WS 网关是可选的：不配 ws_port 就只开裸 TCP
    local ws_port = config.get_number("ws_port")
    if ws_port then
        local protocol = config.get("ws_protocol") or "ws"
        local ws_gate = skynet.newservice("gate_ws")
        skynet.call(ws_gate, "lua", "open", {
            address = host,
            port = ws_port,
            maxclient = maxclient,
            protocol = protocol,
            certfile = config.get("ws_certfile"),
            keyfile = config.get("ws_keyfile"),
            login = login,
        })
        -- 前面挂了 TLS 终止时客户端连的是域名和 443，和本节点的监听口没有关系，
        -- 这时整条 URL 由 ws_public_url 给
        gate_info.ws_url = config.get("ws_public_url") or (protocol .. "://" .. public_host .. ":" .. ws_port)
        log.info("ws gate listening", "port", ws_port)
    end

    -- 上报接入地址，客户端通过 realm 的网关列表找到这里
    gate_info.weight = config.get_number("gate_weight") or 1
    skynet.call(skynet.uniqueservice("realm"), "lua", "register_gate", gate_info)
end

return M
