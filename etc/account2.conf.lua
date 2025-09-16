account_http_port = 8081
account_agent_count = 1

start = "account" -- main script account/main.lua

debug_console_port = 6004

log_config = [[
{
    {
        name = "file",
        filename = "logs/account.log",
        split = "size", -- size/line/day/hour
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    }
}
]]



include "common.conf.lua"
snowflake_machine_id = 3
