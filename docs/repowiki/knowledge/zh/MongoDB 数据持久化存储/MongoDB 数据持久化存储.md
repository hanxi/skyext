---
kind: external_dependency
name: MongoDB 数据持久化存储
slug: mongodb
category: external_dependency
category_hints:
    - vendor_identity
    - client_constraint
scope:
    - '**'
source_files:
    - lualib/dbmgr.lua
    - lualib/mongo_conn.lua
    - service/mongo_conn.lua
    - service/mongo_index.lua
    - tools/mongodb/docker-compose.yml
---

项目使用 MongoDB 作为 ORM 层的数据持久化后端：
- `lualib/dbmgr.lua` 管理连接池；
- `lualib/mongo_conn.lua` 封装连接；
- `service/mongo_conn.lua`、`service/mongo_index.lua` 负责连接初始化与索引创建；
- ORM schema 定义在 `schema/*.sproto`，通过 `make schema` 生成对应代码；
- 开发环境通过 `tools/mongodb/docker-compose.yml` 启动单实例 MongoDB。
MongoDB 为外部数据库依赖，需在启动服务前就绪。