# AGENTS.md — skyext 编码助手约定

本文面向修改 skyext 代码的 AI 助手；面向使用者的安装与运行说明见 [快速上手](docs/getting-started.md)，架构说明见 [架构概览](docs/overview.md)。以仓库中的实现、配置与测试为准，不要把 `docs/design/`、`docs/plan/` 中的提案当成已交付能力。

**动手加"更安全""更严谨"的机制之前，先读[不做的事](docs/non-goals.md)。**那里记的是做过又删掉的设计（日志脱敏、ORM 版本化迁移、GM 权限分级、GM 独立审计文件）和删它们的理由，别再实现第二遍。核心三条：成本不要转嫁给写玩法的人；不要在现成设施旁边造一个更差的；信任边界内侧的那层防护拦不住任何人。

## 项目边界

skyext 是基于 [skynet](https://github.com/cloudwu/skynet) 的分布式游戏服务器**引擎框架**；`example/` 是游戏层示例，游戏项目可以将引擎作为 submodule 使用。skynet 子模块当前构建的解释器是 **Lua 5.5**（可用 `./bin/lua -v` 核实）；另有引擎 C 模块、MongoDB 持久化、etcd 服务发现/分布式锁和 sproto 协议。

| 路径 | 归属与用途 |
| --- | --- |
| `lualib/skyext/` | 引擎 Lua 模块，统一使用 `skyext.*` 命名空间 |
| `lualib/orm/`、`lualib/skytest/`、`lualib/loader.lua` | ORM 运行时、测试/覆盖率与服务加载器 |
| `scripts/tools/sproto_orm/`、`example/build/lualib/game/orm/` | 主工程内生成工具、Git 忽略的游戏层 schema 生成物 |
| `service/`、`public/` | 引擎服务与静态资源 |
| `lualib-src/`、`service-src/`、`build.mk` | 引擎 C 扩展/服务及构建规则 |
| `example/nodes/`、`example/lualib/` | 节点入口与游戏业务代码 |
| `example/etc/`、`example/proto/`、`example/schema/`、`example/hotfix/` | 游戏配置、协议、数据模式与热更包 |
| `scripts/`、`bin/skyext`、`bin/skyext.bat` | 统一 CLI 的 Lua 实现与平台入口 |
| `skynet/`、`3rd/` | Git submodule 依赖，不将引擎修改混入其中 |

引擎服务可以依照扩展点加载游戏层模块（如 `service/entity_agent.lua` 按类型加载 `entity_handler.<type>`）；这是有意的边界，通用能力仍应放在引擎层。

## 模块与加载约定

- 引擎 Lua 模块使用 `require "skyext.config"`、`require "skyext.log"`、`require "skyext.gm_api"` 等完整命名空间，不要在引擎代码中使用 `require "config"` 一类裸模块名。
- 例外：skynet 自带模块（如 `skynet`、`skynet.db.mongo`）、`orm.*`、服务局部库和游戏层自有模块。`service/logger/` 的局部裸 `require` 会通过 `SERVICE_PATH` 解析，不必机械地加 `skyext.` 前缀。
- Lua 风格遵循现有代码：`local M = {} ... return M`、`require "skyext.config"`；记录日志用 `skyext.log`，错误码放在 `skyext.errcode` 或游戏层对应模块中。
- `lualib/loader.lua` 的 `package.path` 从高到低依次为：服务独有库 → 节点根目录 → 节点独有库 → `example/lualib/` → 游戏生成物 `example/build/lualib/` → 引擎 `lualib/` → `skynet/lualib/`。新模块先确认所属层级，避免同名遮蔽。
- 每个服务的启动链是 `lualib/loader.lua` → `require "skyext"`（解析至 `lualib/skyext/init.lua`）→ 服务自身的 `main.lua`。初始化回调加载应用配置与日志。
- Lua C 子模块遵循其导出符号：例如 `require "traceback.c"` 从 `traceback.so` 查找 `luaopen_traceback_c`。

## 配置与工作目录

示例节点配置（如 `example/etc/account1.conf.lua`）提供 `start`、`app_config_path`，并以 `include "core.conf.lua"` 载入 skynet 配置；`core.conf.lua` 定义：

```lua
root = "./"
skyext_root = root
game_root = root .. "example/"
include "paths.conf.lua"
```

应用配置在 `example/etc/nodes/*.app.lua`，通用设置在 `common.app.lua`。**skynet 必须从仓库根目录启动**，或者使用会自动设置工作目录的 `./bin/skyext serve <node>`；不要在 `example/` 目录直接运行 skynet。skynet 和引擎配置加载器的 `include` 按当前配置文件所在目录解析；不要把同目录引用改成 `include(game_root .. "etc/paths.conf.lua")`。

业务配置使用 `require "skyext.config"` 获取：`config.get(key)`（字符串）、`get_boolean`、`get_number`、`get_table`；不存在的键返回 `nil`。`common.app.lua` 中的 JWT 密钥、GM token 只是演示值，切勿用于正式环境。

## 构建、生成与验证

```bash
make init                                   # 初始化子模块（仓库根目录）
make build                                  # 构建引擎与示例
./bin/skyext generate proto                 # 生成 sproto
./bin/skyext generate schema                # 生成 example/build/lualib/game/orm/，需要 stylua
./bin/skyext schema check                   # 改过 schema 后必跑：对比基线，拦下不兼容改动
./bin/skyext test                           # 运行 *.test.lua 测试
./bin/skyext test --cov                     # Lua LCOV；有 genhtml 时生成 HTML
make -C example clean && make build C_COVERAGE=1  # Linux/GCC：切换到 C 插桩构建
./bin/skyext test --cov --cov-c             # 另生成 coverage/c_coverage.info（需要 lcov）
./bin/skyext cov check coverage/lua_coverage_clean.info --threshold 35
make -C example lint                       # 示例游戏的 luacheck
```

Unix/macOS 的 CLI 为 `./bin/skyext`，Windows CMD/PowerShell 使用 `bin\skyext.bat`（先构建本平台二进制）。`make proto` / `make schema` 是 `example/Makefile` 的目标，不是顶层 Makefile 的目标；不要使用不存在的 `make autocode`。CI 在仓库根目录使用 `luacheck .`、`stylua --check .`，还会执行测试、Lua 35% 与 C 60% 的独立行覆盖率门禁和平台构建；C 覆盖率仅统计主工程 `lualib-src/`、`service-src/`，不计子模块。生成器使用独立的 `3rd/sprotodump` 子模块（许可证尚未核实，框架包中不包含），勿将游戏 schema 写入引擎的 `lualib/orm/`。

测试文件与源码相邻，命名 `*.test.lua`；需要 MongoDB 或 etcd 的测试先启动相应服务。若改变 API、配置或构建规则，更新对应使用指南及测试；可通过 `./bin/skyext --help` 核对命令选项。

## Git 与提交约定

- **直接提交到 `main`**，不新建功能分支、不走 PR 流程（本仓库维护约定）。未经用户明确要求，不要自行提交。
- 提交信息遵循 Conventional Commits：`type(scope): description`，描述与正文尽量用中文；**不要**添加 `Co-Authored-By` 尾注。
- 涉及 GitHub Issue 的提交信息必须带 Issue 引用；短写 `#123` 始终指当前提交所在仓库，跨仓库 Issue 必须写完整 `owner/repo#123`，避免误关联。
