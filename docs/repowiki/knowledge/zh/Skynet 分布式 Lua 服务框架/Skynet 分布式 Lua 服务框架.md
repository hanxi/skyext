---
kind: external_dependency
name: Skynet 分布式 Lua 服务框架
slug: skynet
category: external_dependency
category_hints:
    - framework_behavior
    - client_constraint
scope:
    - '**'
source_files:
    - service/hotfix.lua
    - lualib/gm_router.lua
    - lualib/launcher.lua
---

本项目基于 skynet 构建，热更模块深度依赖其运行时能力：
- 代码注入复用 skynet debug_console 的 `debug` 协议 `RUN` 消息，将 patcher 源码以字符串形式注入目标服务进程执行；
- 使用 `skynet.localname` 解析 `.gm` 等内部服务地址；