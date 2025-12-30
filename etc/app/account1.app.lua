log_config = {
    {
        name = "file",
        filename = "logs/account.log",
        split = "size", -- size/line/day/hour
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    },
}

account_http_port = 8080
account_agent_count = 1

debug_console_port = 6003
gm_http_port = 9090 -- GM HTTP 服务端口

snowflake_machine_id = 2

include "common.app.lua"
