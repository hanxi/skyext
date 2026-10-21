robot_count = 1

account_host = "http://127.0.0.1:8080"

-- 可连的 gate。连哪个都能进游戏：gate 会把包转到角色实体所在的节点。
-- 正式环境客户端连的是 gate 前面的负载均衡（或 goscon），这里直接列出各个 gate
gate_addrs = {
    { ip = "127.0.0.1", port = 7012 }, -- rolenode1 同进程部署的 gate
    { ip = "127.0.0.1", port = 7022 }, -- rolenode2 同进程部署的 gate
    { ip = "127.0.0.1", port = 7052 }, -- 独立的 gate1 节点
}

log_config = {
    {
        name = "file",
        filename = "logs/robot.log",
        split = "size", -- size/line/day/hour
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    },
}

include "common.app.lua"
