start = "robot" -- main script robot/main.lua

robot_count = 1

account_host = "http://127.0.0.1:8080"

-- TODO: 从 platform 中获取
gate_nodes = [[
{
  rolenode1 = {
    ip = "127.0.0.1",
    port = 7012,
  },
  rolenode2 = {
    ip = "127.0.0.1",
    port = 7022,
  },
}
]]

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
