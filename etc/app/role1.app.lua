cluster_node_name = "rolenode1"
cluster_listen_port = "7011"
cluster_host = "127.0.0.1"

gm_http_port = 9092 -- GM HTTP 服务端口

gate_port = "7012"

maxclient = 1024

agent_count = 2
login_timeout_sec = 60 -- 登录连接验证超时，单位秒

role_offline_unload_sec = 5 -- 角色离线后多久卸载，单位秒

log_config = {
    {
        name = "file",
        filename = "logs/role1.log",
        split = "size", -- size/line/day/hour
        maxsize = "100M", -- 每个文件最大尺寸 size split 有效
    },
    {
        name = "console",
    },
}

snowflake_machine_id = 0
include "common.app.lua"
