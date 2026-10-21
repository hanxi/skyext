-- 账号节点也加入集群：和其他节点一样注册进服务发现，停服时撤销注册，
-- 以后需要跨节点调用实体时也不用再改部署
cluster_node_name = "account1"
cluster_listen_port = "7031"
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

account_http_port = 8080
account_agent_count = 1

gm_http_port = 9090 -- GM HTTP 服务端口
metrics_http_port = 9190 -- 指标抓取端口

include "common.app.lua"
