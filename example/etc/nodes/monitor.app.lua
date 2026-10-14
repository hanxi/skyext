cluster_node_name = "monitor"
cluster_listen_port = "7021"
cluster_host = "127.0.0.1"

start = "monitor" -- main script

-- 负责管理 role 节点数量，节点信息经 etcd 同步，实体落在哪个节点由 skyext.entity.placement 决定

include "common.app.lua"
