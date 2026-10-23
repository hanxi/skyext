# skyext

[![构建](https://img.shields.io/github/actions/workflow/status/hanxi/skyext/build-release.yml?branch=main&label=build)](https://github.com/hanxi/skyext/actions/workflows/build-release.yml)
[![测试](https://img.shields.io/github/actions/workflow/status/hanxi/skyext/coverage.yml?branch=main&label=test)](https://github.com/hanxi/skyext/actions/workflows/coverage.yml)
[![代码检查](https://img.shields.io/github/actions/workflow/status/hanxi/skyext/lint.yml?branch=main&label=lint)](https://github.com/hanxi/skyext/actions/workflows/lint.yml)
[![Lua 5.5](https://img.shields.io/badge/Lua-5.5-2c2d72)](https://www.lua.org/)
[![MIT 许可证](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

基于 [skynet](https://github.com/cloudwu/skynet) 的分布式游戏服务器框架。引擎代码位于仓库根目录，`example/` 是使用引擎的示例游戏；也可以将 skyext 作为 submodule 引入游戏项目。**项目仍处于开发阶段，示例配置仅供本地开发和学习，不应直接用于生产环境。**

## 能做什么

- **分层与分布式部署**：引擎模块采用 `skyext.*` 命名空间；Account、Role、Gateway、Robot 节点可分别部署（Role 自带 gate，Gateway 为可选的独立网关节点），基于 etcd 提供服务发现与分布式锁。
- **游戏数据与协议**：MongoDB 持久化、ORM/schema、sproto 协议，以及可扩展的通用实体系统。
- **接入与运维**：HTTP 接口、JWT 登录、skynet TLS 模块、日志、GM 命令与代码/配置热更新。
- **开发工具**：跨平台统一 CLI、伴随源码的 `.test.lua` 测试及 CI 检查。

运行时依赖 MongoDB、etcd；构建还需要 C 工具链、OpenSSL 和项目子模块。具体准备方式见[快速上手](docs/getting-started.md)。

## 快速体验

以下命令从 **仓库根目录** 执行，适用于 Linux/macOS（完整的依赖、Windows 用法和故障排查见[快速上手](docs/getting-started.md)）：

```bash
git clone https://github.com/hanxi/skyext.git
cd skyext
make init
make build

# 在本机启动示例所需的 MongoDB 和三节点 etcd；需要 Docker Compose
docker compose -f example/tools/mongodb/docker-compose.yml up -d
docker compose -f example/tools/etcd/docker-compose.yml up -d

# 协议和 ORM 模式；生成 schema 需要安装 stylua
./bin/skyext generate proto
./bin/skyext generate schema

# 分别在两个终端运行（进程保持前台）
./bin/skyext serve account1
./bin/skyext serve role1
```

可另开终端运行 `./bin/skyext serve robot` 测试示例客户端。`serve` 会将工作目录设为仓库根目录；直接调用 skynet 时也必须在根目录执行，例如 `./bin/skynet example/etc/account1.conf.lua`，因为示例的 `root = "./"`。

> `example/etc/nodes/common.app.lua` 包含演示用 JWT 密钥，GM token 默认不配（接口关闭）。连接真实网络或部署前必须替换密钥、配置 GM token，并按环境配置数据库、etcd 与接口访问控制。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `lualib/skyext/`、`lualib/orm/`、`lualib/skytest/` | 引擎库、ORM、测试框架 |
| `sdk/lua/`、`sdk/ts/` | 客户端 SDK（Lua / TypeScript），实现[客户端接入规范](docs/guide/client_protocol.md) |
| `service/`、`public/` | 通用 skynet 服务和静态资源 |
| `lualib-src/`、`service-src/`、`build.mk` | C 扩展、服务与构建规则 |
| `example/nodes/`、`example/service/`、`example/lualib/` | 示例游戏的节点入口、共享服务（login/admin）与业务代码 |
| `example/etc/`、`example/proto/`、`example/schema/` | 示例配置、协议与数据模式 |
| `scripts/tools/sproto_orm/`、`scripts/`、`bin/skyext`、`bin/skyext.bat` | 内化的 ORM 生成工具、跨平台 CLI 及其 Lua 实现 |
| `skynet/`、`3rd/` | Git submodule 依赖 |
| `docs/` | 使用指南、设计记录与规划 |

节点职责、启动链与配置分层详见[架构概览](docs/overview.md)。

## 开发与验证

在仓库根目录运行 CLI；Windows CMD/PowerShell 将 `./bin/skyext` 替换成 `bin\skyext.bat`（先完成对应平台构建）：

```bash
./bin/skyext --help
./bin/skyext test                      # 运行所有 .test.lua 测试
./bin/skyext test lualib/skyext/       # 只运行指定目录
SKYTEST_INTEGRATION=1 ./bin/skyext test lualib/skyext/entity/  # 含真实 MongoDB/etcd 集成测试
./bin/skyext generate proto            # 编译 sproto
./bin/skyext generate schema           # 生成 ORM schema（需要 stylua）
./bin/skyext package game              # 示例游戏包：example/skyext.zip
./bin/skyext package framework linux   # 框架包：release-assets/skyext-linux.zip
```

测试文件与被测模块放在一起，使用 `*.test.lua` 命名；真实 MongoDB/etcd 集成测试仅在 `SKYTEST_INTEGRATION=1` 时运行，可用 `MONGO_HOST`、`MONGO_PORT`、`ETCD_ENDPOINTS` 覆盖地址（默认本机）。集成测试验证两个独立锁实例的竞争、租约撤销、Mongo fencing、旧持有者写入拒绝，以及真实 MongoDB 上的可靠消息序号、分页和重复确认；完整的多进程节点交接仍需部署环境验证。`make -C example format` 和 `make -C example lint` 分别调用 StyLua、Luacheck；CI 还会运行构建、测试、格式检查和多平台打包。ORM schema 生成到 Git 忽略的 `example/build/lualib/game/orm/`；运行时 ORM 位于主工程 `lualib/orm/`。生成协议/schema 需要源码检出初始化的 `3rd/sprotodump` 子模块（框架发布包未包含该解析器）。

## 文档导航

**在线使用文档**（[文档站](https://hanxi.github.io/skyext/docs/)；也可直接阅读仓库文件）：

- [架构概览](docs/overview.md)：节点、引擎/游戏分层与配置流向。
- [快速上手](docs/getting-started.md)：依赖、构建、运行、测试及常见问题。
- [登录流程](docs/guide/login.md) · [登录流程图](docs/guide/login_diagram.md) · [客户端接入规范](docs/guide/client_protocol.md)：自己写客户端 SDK 看规范。
- [客户端 SDK](docs/guide/client_sdk.md)：官方 Lua / TypeScript 双实现的安装、快速上手、小程序 transport 适配、错误码与验收方法。
- [完整客户端联调](docs/guide/fullstack_client.md)：gamepass OAuth + phaser-game 浏览器客户端（已迁移到官方 TS SDK，直连 `gate_ws`，不再需要 goscon），跑通正式客户端链路。
- [热更新操作](docs/guide/hotfix.md) · [GM HTTP API](docs/guide/gm_api.md)。
- [HTTP 服务端](docs/guide/http_server.md)：命名实例、连接与超时上限、路由注册。
- [指标采集与导出](docs/guide/metrics.md)：指标原语、Prometheus 端点与内置指标。
- [改 ORM schema](docs/guide/orm_schema_change.md)：加删字段为什么不用写迁移，改名、改类型和重用旧字段名怎么拦。
- [不做的事](docs/non-goals.md)：做过又删掉的设计，以及删它们的理由。

**仅保存在仓库的设计与规划文档**（未发布到在线文档站）：[实体系统](docs/design/entity_system.md)、[skytest](docs/design/skytest.md)、[性能采样设计](docs/design/profiler.md)、[管理后台规划](docs/plan/admin_panel.md)。规划文档描述目标，不代表功能已经可用。

## 相关项目与参与

- [phaser-game](https://github.com/hanxi/phaser-game)：示例 Phaser 客户端（submodule：`example/tools/phaser-game`）。
- [gamepass](https://github.com/hanxi/gamepass)：第三方登录鉴权服务（submodule：`example/tools/gamepass`）。
- [goscon](https://github.com/hanxi/goscon)：WebSocket 到 TCP 网关（submodule：`example/tools/goscon`）。**已从示例链路退役**：phaser-game 迁移到官方 [客户端 SDK](docs/guide/client_sdk.md) 后直连 `gate_ws`，WebSocket 接入由 `service/gate_ws.lua` 原生支持，断线续接由会话层原生支持（见[登录流程](docs/guide/login.md)）。只有真的需要字节级连接续接时才接它，并且**不能打开它的 `-sproto` 开关**——那个开关会往游戏服注入 `login.report_remote_addr`，该协议已经删除（真要在代理后面拿客户端真实 IP，用 PROXY protocol，而不是带内消息）。

前两者的启动与联调步骤见[完整客户端联调](docs/guide/fullstack_client.md)。

问题与建议可提交 [GitHub Issues](https://github.com/hanxi/skyext/issues)。修改前请阅读 [AGENTS.md](AGENTS.md) 中的项目约定，并运行相关测试和代码检查。

本项目采用 [MIT 许可证](LICENSE)。
