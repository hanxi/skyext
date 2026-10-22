robot_count = 1

account_host = "http://127.0.0.1:8080"

-- 网关地址不在这里配：机器人启动时请求 account 的 /gates 拿在线网关列表，
-- 和正式客户端走同一条发现路径。连哪台都能进游戏，网关会把包转到角色实体所在的节点

-- 同一套用例在每种传输上各跑一遍，验证行为一致。只想压某一种时删掉另一个
robot_transports = { "tcp", "ws" }

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
