# 架构概览

skyext 在 [skynet](https://github.com/cloudwu/skynet) 上提供通用的游戏服务器基础设施；`example/` 是使用这些能力的示例游戏。本文说明**代码放在哪里、节点如何协作、启动时配置如何生效**。安装、启动和测试步骤集中在[快速上手](getting-started.md)。

## 引擎层与游戏层

| 层级 | 主要路径 | 职责 |
| --- | --- | --- |
| 引擎 Lua 模块 | `lualib/skyext/` | `skyext.*` 命名空间：配置、日志、HTTP、服务发现、协议、GM、实体路由等 |
| 引擎基础设施 | `lualib/orm/`、`lualib/skytest/`、`service/` | ORM、测试与覆盖率、GM/热更/数据库等 skynet 服务 |
| 引擎原生扩展 | `lualib-src/`、`service-src/`、`build.mk` | C 模块、C 服务及构建规则 |
| 游戏层（示例） | `example/nodes/`、`example/lualib/` | 节点入口、角色/账号逻辑、实体 handler 与业务模块 |
| 游戏契约与配置 | `example/etc/`、`example/proto/`、`example/schema/`、`example/build/lualib/game/orm/` | 节点/应用配置、sproto/ORM 源模式及生成的游戏层 schema（构建产物） |

游戏项目可以参考 `example/` 实现自身逻辑，并通过搜索路径使用引擎模块。引擎服务通过约定扩展点加载游戏侧代码，例如实体 agent 按实体类型加载 `entity_handler.<type>`；这不等于把业务模块放进 `lualib/skyext/`。`skynet/` 与 `3rd/` 是 Git submodule 依赖；ORM 运行时在主工程 `lualib/orm/`，内化的生成工具在 `scripts/tools/sproto_orm/`，解析器仍为 `3rd/sprotodump` 子模块。框架发布包不分发许可证尚未核实的解析器，重新生成模式需使用初始化子模块的源码检出。

## 节点与数据流

| 节点 | 入口 | 主要职责 |
| --- | --- | --- |
| Account | `example/nodes/account/main.lua` | 启动 HTTP 服务并注册账号路由，处理账号与登录请求 |
| Role | `example/nodes/role/main.lua` | 启动 watchdog/gate，承载角色连接与游戏逻辑 |
| Robot | `example/nodes/robot/main.lua` | 示例客户端，用于本地登录/游戏流程验证 |

各节点分别运行在 skynet 进程中。示例的 Account、Role 节点都调用游戏层 `example/lualib/launcher.lua` 启动 GM、hotfix 服务，并在启动阶段创建 MongoDB 索引；Role 通过网关接入客户端。服务发现组件把服务注册到 etcd，并为服务端调用方维护节点缓存；示例 Robot 则根据 Account 返回的 `rolenode` 和本地 `gate_nodes` 配置连接网关，而非从 etcd 缓存选择客户端地址。角色与账号数据通过 MongoDB 连接池、ORM 和业务 handler 读取/保存。详细的客户端交互见[登录流程](guide/login.md)及[流程图](guide/login_diagram.md)。

示例业务配置位于 `example/etc/nodes/`：Account HTTP、Role 网关、GM HTTP 端口，以及 `mongo_config`、`etcd_config`、JWT 密钥等都在这里配置。跨机器部署时，需同时调整监听/对外地址、服务发现地址和外部服务连接地址；示例中的 `127.0.0.1` 只适用于本机环境。

## 启动与模块加载

1. skynet 从 `example/etc/<node>.conf.lua` 读取启动参数；节点文件通过 `include "core.conf.lua"` 载入根目录、线程与搜索路径。
2. `example/etc/core.conf.lua` 定义 `root = "./"`、`skyext_root`、`game_root`，再载入同目录的 `paths.conf.lua`。因此直接启动 skynet 时工作目录必须是 **skyext 仓库根目录**。
3. `lualib/loader.lua` 依次配置服务局部、节点、游戏公共、引擎和 skynet 的 Lua 模块搜索路径，并加载 `require "skyext"`。
4. `lualib/skyext/init.lua` 注册初始化回调：`skyext.config` 读取 `app_config_path` 指向的应用配置，`skyext.log` 初始化日志；随后执行服务自身的入口文件。

搜索优先级允许服务或游戏层覆盖自己的模块，但引擎 Lua 模块应通过 `require "skyext.<模块>"` 引用，避免与同名业务模块冲突。`config.get`、`get_number`、`get_boolean`、`get_table` 分别读取字符串、数值、布尔和表类型的应用配置。配置文件和示例见[快速上手：理解并修改配置](getting-started.md)。

## 核心能力与实现位置

| 能力 | 入口或实现 | 说明 |
| --- | --- | --- |
| 服务发现 | `lualib/skyext/cluster_discovery.lua`、`service/cluster_discovery.lua` | etcd 注册、租约续期、服务节点查询与变更通知 |
| etcd 客户端 | `lualib/skyext/etcd/` | etcd v3 HTTP 客户端，按 transport/auth/kv/lease/watch 分层，服务发现与分布式锁的底座 |
| 数据持久化 | `lualib/skyext/dbmgr.lua`、`lualib/skyext/save_wheel.lua`、`lualib/orm/`、`service/mongo_conn.lua` | 加载/缓存 ORM 对象、跟踪变更、按回存轮定时与卸载时写入 MongoDB |
| ORM schema 变更 | `lualib/orm/init.lua` 的 `orm.decode`、`lualib/skyext/orm_compat.lua`、`./bin/skyext schema check` | 加载时丢弃已删字段、补齐新字段；改名、改类型、重用删过的名字由基线对比在 CI 拦下；见 [改 ORM schema](guide/orm_schema_change.md) |
| 协议与鉴权 | `lualib/skyext/sproto_api.lua`、`example/lualib/jwt.lua` | sproto 编解码、示例 JWT 登录 |
| HTTP 与 GM | `lualib/skyext/http_server/`、`lualib/skyext/gm_api.lua`、`service/gm.lua` | HTTP 路由、命令注册/执行、token 鉴权；见 [HTTP 服务端](guide/http_server.md)、[GM HTTP API](guide/gm_api.md) |
| 指标 | `lualib/skyext/metrics*.lua`、`service/metrics.lua` | counter/gauge/histogram 原语、跨服务合并与 Prometheus 文本导出；见 [指标采集与导出](guide/metrics.md) |
| 热更新 | `service/hotfix.lua`、`example/hotfix/` | 热更包、预演与执行；按[热更新操作](guide/hotfix.md)进行 |
| 通用实体 | `lualib/skyext/entity/`、`service/entity_agent*.lua` | 按存活节点路由（HRW）、实体生命周期、业务模块扩展 |
| 测试与覆盖率 | `lualib/skytest/`、`scripts/commands/test.lua` | 每个 `.test.lua` 文件独立 skynet 进程，生成 lcov 报告 |

**节点崩溃后的接管窗口**：实体锁挂在节点级的 etcd 租约上，TTL 30 秒、每 10 秒续一次。节点**优雅下线**时会主动交接，几乎没有空窗；节点**硬崩**（进程被杀、机器掉电、网络分区）时没人能主动释放锁，必须等 etcd 把租约过期掉。这段时间里，落到该实体上的请求会一直拿到 `LOCK_FAILED`（`bind_client` 在能查到持锁节点、交接又失败时返回 `IN_OTHER_NODE`）：接管节点尝试向已死的持有者请求交接会直接失败，而锁键还在，抢不过来。

所以**单个实体的最坏不可用时长约 30 秒**，不是秒级。客户端重连逻辑要能容忍这个量级，不要在收到 `LOCK_FAILED` 后立刻放弃或提示玩家"账号异常"。想缩短窗口就得调小 `distributed_lock.lua` 里的 `LEASE_TTL`，代价是心跳更密、对 etcd 抖动更敏感——续租晚一拍就会误判失租，把一个健康节点上的实体全部隔离。

**数据可靠性边界**：`dbmgr` 对脏数据制作快照，在 MongoDB 确认更新后才清除脏标记；写入失败、不确定或未匹配时保留脏对象及缓存，卸载不得先释放实体锁。进程异常退出时仍不能据此推断数据已持久化；可靠消息为至少一次投递，业务 handler 需以 `msg_id` 幂等处理。生产使用前应结合一致性、失败日志和恢复策略评估。示例 JWT 密钥必须更换，GM token 要现生成并限制接口来源。

## 当前状态与延伸阅读

代码中已有 Account/Role 示例、实体框架、GM/热更、skytest 与覆盖率工具；[管理后台规划](https://github.com/hanxi/skyext/blob/main/docs/plan/admin_panel.md)和[性能采样设计](https://github.com/hanxi/skyext/blob/main/docs/design/profiler.md)描述的是后续方向，不应将规划中的功能视为已交付。仓库中已有 `public/gm.html` 和部分 profiler 相关组件，但不等于完整的运营后台或火焰图服务。

深入设计见仓库中的[实体系统设计](https://github.com/hanxi/skyext/blob/main/docs/design/entity_system.md)和[skytest 设计](https://github.com/hanxi/skyext/blob/main/docs/design/skytest.md)。这些内部文档**不随在线文档站发布**；本文的链接指向 GitHub 源文件。配置、测试和操作命令请以[快速上手](getting-started.md)为准。
