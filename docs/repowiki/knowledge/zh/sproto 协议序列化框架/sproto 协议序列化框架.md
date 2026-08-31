---
kind: external_dependency
name: sproto 协议序列化框架
slug: sproto
category: external_dependency
category_hints:
    - vendor_identity
scope:
    - '**'
source_files:
    - lualib/sproto_api.lua
    - proto/base.sproto
    - schema/role.sproto
---

项目使用 sproto 作为网络协议和数据序列化工具：
- 协议定义位于 `proto/`，业务 schema 位于 `schema/`；
- 通过 `make proto` 和 `make schema` 生成对应 Lua 代码；
- `lualib/sproto_api.lua` 提供编解码封装；
- 热更流程支持 `reload_sproto` 动态重载协议定义。