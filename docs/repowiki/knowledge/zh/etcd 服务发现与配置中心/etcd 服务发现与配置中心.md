---
kind: external_dependency
name: etcd 服务发现与配置中心
slug: etcd
category: external_dependency
category_hints:
    - vendor_identity
    - client_constraint
scope:
    - '**'
source_files:
    - lualib/cluster_discovery.lua
    - lualib/distributed_lock.lua
    - etc/app/common.app.lua
    - tools/etcd/docker-compose.yml
---

项目使用 etcd 作为分布式服务注册发现与配置管理后端：
- 通过 `lualib/cluster_discovery.lua` 实现服务注册与发现；
- 通过 `lualib/distributed_lock.lua` 提供基于 etcd 的分布式锁；
- 应用配置中 `mongo_config`、`log_level` 等通过 etcd 下发；
- 开发环境通过 `tools/etcd/docker-compose.yml` 启动 etcd 集群。
etcd 是独立部署的外部依赖，需在启动游戏服务器前先拉起。