start = "robot" -- main script robot/main.lua

robot_count = 1

-- TODO: 从 platform 中获取
gate_ip = "127.0.0.1"
gate_port = "7012"

log_config = [[
{
    {
        name = "file",
        filename = "logs/robot.log",
        split = "size", -- size/line/day/hour
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    }
}
]]

include "common.conf.lua"
