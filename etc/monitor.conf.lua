cluster_node_name = "monitor"
cluster_listen_port = "7021"
cluster_host = "127.0.0.1"

start = "monitor"  -- main script

-- 负责管理game节点数量，使用etcd同步节点信息，使用jhash决定role应该在哪个节点上


include "common.conf.lua"
