cluster_node_name = "rolenode2"
cluster_listen_port = "7021"
cluster_host = "127.0.0.1"

debug_console_port = 6002

gate_port = "7022"

start = "role" -- main script role/main.lua
maxclient = 1024
-- daemon = "./role2.pid"

agent_count = 2
login_timeout_sec = 60 -- 登录连接验证超时，单位秒

role_offline_unload_sec = 5 * 60 -- 角色离线后多久卸载，单位秒

log_config = [[
{
    {
        name = "file",
        filename = "logs/role2.log",
        split = "size", -- size/line/day/hour
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    }
}
]]

snowflake_machine_id = 1
include "common.conf.lua"
