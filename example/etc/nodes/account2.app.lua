-- 账号节点也要加入集群：它按服务发现报告的存活节点为玩家挑 rolenode，
-- 不注册进 etcd 就拿不到成员变更
cluster_node_name = "account2"
cluster_listen_port = "7041"
cluster_host = "127.0.0.1"

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

account_http_port = 8081
account_agent_count = 1

gm_http_port = 9091 -- GM HTTP 服务端口

include "common.app.lua"
