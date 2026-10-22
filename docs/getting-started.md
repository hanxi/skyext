# 快速上手

本指南从空白检出开始，完成构建、启动示例节点和运行测试。以下 Unix 命令除非特别说明，均在 **skyext 仓库根目录** 执行。架构与目录职责见[架构概览](overview.md)。

## 准备环境

| 用途 | 依赖 |
| --- | --- |
| 源码与编译 | Git、Make、C 编译器、OpenSSL 开发库；构建 skynet 所需的 autotools 等工具 |
| 示例运行 | MongoDB 6、etcd（示例提供 Docker Compose 配置） |
| 生成 ORM schema | 已初始化的 `3rd/sprotodump` 子模块、`stylua` 命令（生成器最后会格式化产物） |
| 测试 | 构建好的 skynet/Lua，部分测试需要 MongoDB 和 etcd |

Linux、macOS 可使用 Unix 包装入口 `./bin/skyext`。CI 还构建 FreeBSD 和 Windows（MSYS2/MinGW64）；Windows CMD/PowerShell 的入口是 `bin\skyext.bat`，需先在对应环境构建 `bin\lua.exe` 和 `bin\skynet.exe`。具体平台依赖和编译参数可参照 [CI 构建配置](https://github.com/hanxi/skyext/blob/main/.github/workflows/build-release.yml)，尤其是 macOS 的 OpenSSL 路径和 Windows 的 skynet 兼容补丁。

Linux（Debian/Ubuntu）的 CI 安装了以下构建依赖，可作为本地环境参考：

```bash
sudo apt-get update
sudo apt-get install build-essential make pkg-config autoconf automake libtool \
  git curl ca-certificates libreadline-dev libedit-dev libssl-dev rsync zip unzip
```

需要使用本地 Docker Compose 示例时，还应安装 Docker 与 Compose 插件。Windows 和 macOS 请按对应平台安装等价依赖；`stylua` 需要另行安装并加入 `PATH`。

## 1. 获取源码并构建

```bash
git clone https://github.com/hanxi/skyext.git
cd skyext
make init           # 拉取 skynet 和 3rd/ 子模块
make build          # 等同于 make -C example build
./bin/lua -v        # 查看实际使用的 Lua 版本
./bin/skyext --help
```

当前子模块构建的 Lua 为 **5.5**。`make build` 会编译 skynet、引擎 C 模块与服务，并将 Lua/Skynet 程序放入 `bin/`。如果编译失败，先检查子模块是否已初始化、C 工具链与 OpenSSL 头文件/链接库是否可用。构建规则在根目录的 `build.mk`，示例游戏入口在 `example/Makefile`。

## 2. 启动外部服务

示例配置 `example/etc/nodes/common.app.lua` 默认访问本机 MongoDB `127.0.0.1:27017` 和三个 etcd 端点（`127.0.0.1:2379`、`2378`、`2377`）。使用项目自带的 Compose 配置：

```bash
docker compose -f example/tools/mongodb/docker-compose.yml up -d
docker compose -f example/tools/etcd/docker-compose.yml up -d
```

也可以连接已有实例，此时按实际地址修改应用配置；关闭示例依赖时对相应配置执行 `docker compose -f <路径> down`。**不要**在公共网络暴露示例 Compose 的未鉴权数据库/etcd 服务。

## 3. 生成协议和数据模式

```bash
./bin/skyext generate proto
./bin/skyext generate schema
# 或者：make -C example proto && make -C example schema
```

- `generate proto` 从 `example/proto/**/*.sproto` 生成 `example/build/proto/sproto.spb`。
- `generate schema` 从 `example/schema/**/*.sproto` 生成 `example/build/lualib/game/orm/schema_define.lua` 与 `schema.lua`，最后调用 `stylua`。服务通过 `require "game.orm.schema"` 加载游戏层生成物；`example/build/` 被 Git 忽略，不要把 schema 写回引擎的 `lualib/orm/`。若报 `stylua failed`，先安装格式化工具并确认可从终端运行。
- 协议解析器位于独立子模块 `3rd/sprotodump`，ORM 生成工具位于主工程 `scripts/tools/sproto_orm/`，运行时位于 `lualib/orm/`。框架发布包不包含许可证尚未核实的 `sprotodump`；要重新生成 schema/proto，请使用已初始化该子模块的源码检出。
- 改过 schema 之后执行 `./bin/skyext schema check`：加删字段在运行期是安全的，改名、改类型和重用删过的字段名会被拦下。确认无误后 `./bin/skyext schema accept` 更新基线 `example/schema/schema.lock.lua` 并一起提交，详见[改 ORM schema](guide/orm_schema_change.md)。
- 修改协议或 schema 后重新生成相应产物，再运行相关测试；项目没有 `make autocode` 目标。

## 4. 启动示例节点

分别在不同终端、**从仓库根目录**运行，命令会保持前台：

```bash
./bin/skyext serve account1  # Account：HTTP 端口 8080，GM 端口 9090，指标端口 9190
./bin/skyext serve role1     # Role：客户端网关端口 7012，GM 端口 9092，指标端口 9192
```

也可以启动 `account2`、`role2`，以及独立网关节点 `gate1`（端口由各自的 `example/etc/nodes/*.app.lua` 配置决定）。`gate1` 只负责连接与登录，实体仍转发给 Role 逻辑节点处理；role1/role2 已同进程带 gate，gate1 属可选。`./bin/skyext serve robot` 启动示例机器人；其 `gate_addrs` 列出三个可连 gate：7012/7022（rolenode1/rolenode2 同进程 gate）与 7052（独立 gate1）。机器人按编号错开起点，再依次试到第一个连得上的——连哪个 gate 都能进游戏，gate 会把包转到角色实体所在节点，所以只起了 `role1` 也能跑通。

CLI 的 `serve` 会自动切换到仓库根目录。直接使用 skynet 时**不能**在 `example/` 下启动，否则 `example/etc/core.conf.lua` 中的 `root = "./"` 会指向错误位置：

```bash
./bin/skynet example/etc/account1.conf.lua
```

机器人走的是开发链路（`/dev_login` 签 token、TCP 直连 gate）。正式浏览器客户端的完整链路（gamepass OAuth 签 JWT + goscon WebSocket 网关 + phaser-game 客户端）见[完整客户端联调](guide/fullstack_client.md)。

## 5. 理解并修改配置

配置分两层，分别由 skynet 和引擎加载：

| 层级 | 示例路径 | 作用 |
| --- | --- | --- |
| 节点启动配置 | `example/etc/account1.conf.lua` | 设置 `start`、`app_config_path`，并引用 `core.conf.lua` |
| 核心与搜索路径 | `example/etc/core.conf.lua`、`example/etc/paths.conf.lua` | 定义仓库根目录、Lua/C 模块与服务搜索路径 |
| 应用配置 | `example/etc/nodes/account1.app.lua`、`common.app.lua` | HTTP 端口、日志、MongoDB、etcd、登录密钥等业务参数 |

`include "core.conf.lua"` 和 `include "common.app.lua"` 均按各自配置文件所在目录解析，不要替换成从仓库根目录拼接出的路径。服务启动时，`lualib/loader.lua` 加载 `skyext`，`lualib/skyext/init.lua` 再初始化配置与日志。业务代码通过 `require "skyext.config"` 获取配置：

```lua
local config = require "skyext.config"
local mongo = config.get_table("mongo_config")
local timeout = config.get_number("login_timeout_sec")
local enabled = config.get_boolean("proto_checksum_enable")
local secret = config.get("login_jwt_secret")
```

`config.get*` 在配置不存在时返回 `nil`；应用配置中的 table 会序列化进 skynet 环境，再由 `get_table` 反序列化。示例中的 `login_jwt_secret = "your_access_secret"` **不是生产密钥**；在真实部署前务必更换，并保护 GM、Account、数据库与 etcd 的访问边界。

密钥强度由 `skyext.secret` 统一校验（`openssl rand -hex 32` 生成即可）：未配置、命中已知占位符黑名单、或少于 16 字符的密钥一律视为不可用。不可用时的行为是"拒绝而不是放行"：

- `login_jwt_secret` 不可用 → 登录请求返回 `TOKEN_ERROR`，`/dev_login` 也签发不出 token；
- GM token（`gm_auth_token`）不可用 → `/gm/execute`、`/gm/list` 全部拒绝。

示例配置里额外写了 `allow_insecure_secret = true`，这是**仅供本地开发**的逃生口：它只放宽 `login_jwt_secret`（放行时打一条 ERROR 日志），不影响 GM 鉴权。生产环境不要设置这一项。

同样仅供本地开发的还有 `dev_login_enable = true`：它打开 Account 的 `POST /dev_login`，按账号名直接签发登录 token、**不校验任何身份**，机器人靠它登录。生产环境必须去掉，token 交给 SDK/平台登录服务签发。

登录 token 除签名外还校验签发方和有效期：`login_jwt_issuer` / `login_jwt_audience` 两边必须一致，`login_jwt_ttl` 决定有效期（缺 `exp` 的 token 一律拒绝），`login_jwt_leeway` 容忍节点间时钟差。详见 [登录流程](guide/login_diagram.md#jwt-token)。

指标端点（`metrics_http_host` / `metrics_http_port`，示例里 account1 用 9190、role1 用 9192）同样默认只听回环。它**不鉴权**，暴露出去等于把内部拓扑和业务量公开，配法与内置指标见[指标采集与导出](guide/metrics.md)。

GM 口是管理员接口，只认一个 token，分人分权交给对接它的后台去做。示例默认不配（即 GM 接口关闭），配法见 [GM HTTP API](guide/gm_api.md#鉴权)。

**停止节点要走 GM 命令 `shutdown`**，不要直接 Ctrl+C 或 kill（端口换成对应节点的 `gm_http_port`）：

```bash
curl -H "Authorization: Bearer <gm_auth_token>" "http://127.0.0.1:9092/gm/execute?cmd=shutdown&timeout=60"
```

它会先停止接受新连接，再把全部实体落库、释放锁、踢下在线玩家，然后归还 snowflake 机器号、撤销节点租约，进程自己退出；有实体卸不掉时进程保持运行并打 ERROR 日志，排查后可以再发一次。直接杀进程会丢掉上次回存（默认 3 分钟一次）之后的改动，实体锁和节点注册也要等 30 秒租约过期才会被清掉。没有实体的节点（如 Account）走同一个命令，只是少了卸载那一步。

## 6. 测试、检查与打包

```bash
./bin/skyext test                           # 扫描并运行所有 *.test.lua
./bin/skyext test lualib/skyext/errcode.test.lua
./bin/skyext test --match errcode           # 按测试文件路径过滤
make -C example lint                       # 示例游戏 luacheck
# CI 在仓库根目录运行 luacheck . 和 stylua --check .
./bin/skyext package game                  # example/skyext.zip（游戏部署包）
./bin/skyext package framework linux       # release-assets/skyext-linux.zip（平台框架包）
```

测试文件与源码相邻，每个测试文件在独立的 skynet 进程中运行；需要数据库或 etcd 的测试应先启动相应服务。游戏部署包会排除 `*.test.lua` 与测试运行器生成的临时配置；框架源码包也会排除临时测试配置，避免将构建机的绝对路径带入发布物。平台包只适用于实际构建的平台；正式发布由 GitHub Actions 在 `v*` 标签构建，不要把本地 Linux 产物当作其他平台的二进制。

## 常见问题

| 现象 | 检查项 |
| --- | --- |
| `bin/skyext` 提示未构建 | 先运行 `make init && make build`；Windows 需构建本平台可执行文件。 |
| `module ... not found` 或路径错误 | 确认子模块已拉取，生成步骤完成；直接运行 skynet 时工作目录必须是仓库根目录。 |
| 生成 schema 失败 | 检查 `3rd/sprotodump` 是否已初始化，`stylua` 是否已安装且在 `PATH` 中。 |
| MongoDB/etcd 连接失败 | 检查 Compose 服务、端口与 `common.app.lua` 中的连接地址；容器环境需替换 `127.0.0.1`。 |
| 客户端/机器人无法连接 | 核对 Account HTTP、gate 监听端口（Role 同进程 gate 或独立 gate1），以及 `robot.app.lua` 的 `gate_addrs`。 |
| GM 接口不可用 | 核对对应节点 GM 端口与 `gm_auth_token`，详见 [GM HTTP API](guide/gm_api.md)。 |
| `/metrics` 少了某个服务 | 该服务要用 `skyext.cmd_api` 接管消息分发才挂得上 `collect_metrics`；另见日志里的 `metrics service not found`。 |

下一步可阅读[登录流程](guide/login.md)、[热更新操作](guide/hotfix.md)与[架构概览](overview.md)。
