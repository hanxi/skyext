# AGENTS.md — AI 编码助手指南

## 项目概述

skyext 是基于 [skynet](https://github.com/cloudwu/skynet) 的分布式游戏服务器**引擎框架**。采用引擎层/游戏层分离架构，游戏项目可以将 skyext 作为 submodule 引用。

## 目录结构

```
skyext/                     ← 引擎仓库根目录（skynet 启动时的工作目录）
├── lualib/
│   ├── skyext/             ← 引擎 Lua 模块（require "skyext.*"）
│   │   ├── init.lua        ← 引导模块，被 loader.lua 自动加载
│   │   ├── config.lua      ← 配置读取
│   │   ├── log/            ← 日志系统
│   │   ├── http_server/    ← HTTP 服务器
│   │   ├── entity/         ← 实体系统
│   │   ├── gm_api.lua      ← GM 命令注册
│   │   ├── gm_router.lua   ← GM HTTP 路由
│   │   ├── dbmgr.lua       ← MongoDB 连接池
│   │   └── ...
│   ├── orm/                ← ORM 框架（不在 skyext/ 下）
│   └── loader.lua          ← 服务加载器（不在 skyext/ 下）
├── service/                ← 引擎服务
├── public/                 ← 引擎静态资源（gm.html 等）
├── lualib-src/             ← 引擎 C 模块源码（crypto.c 等）
├── build.mk                ← 引擎构建规则
├── example/                ← 示例游戏项目
│   ├── nodes/              ← 节点入口（account/、role/、robot/）
│   ├── etc/                ← 游戏配置（skynet 配置文件）
│   ├── lualib/             ← 游戏业务 Lua 库
│   ├── proto/              ← 协议定义
│   ├── schema/             ← ORM 数据模式
│   ├── hotfix/             ← 热更包
│   └── Makefile            ← 游戏构建入口（include ../build.mk）
├── skynet/                 ← skynet 框架（submodule）
└── 3rd/                    ← 第三方库（submodule）
```

## 核心约定

### 命名空间

所有引擎 Lua 模块使用 `skyext.*` 命名空间：

```lua
local config = require "skyext.config"
local log = require "skyext.log"
local gm_api = require "skyext.gm_api"
local dbmgr = require "skyext.dbmgr"
```

**不要使用裸 require**（如 `require "config"`），除非是：
- skynet 内置模块：`require "skynet"`、`require "skynet.db.mongo"` 等
- ORM 模块：`require "orm.ormtable"` 等
- 服务目录内的局部模块（通过 SERVICE_PATH 解析）
- 游戏层自己的模块（通过搜索路径解析）

### require 搜索优先级

`lualib/loader.lua` 设置的 `package.path` 优先级（从高到低）：

1. 服务独有库：`<service_path>/<service_name>/lualib/`
2. 节点根目录：`<service_path>/`
3. 节点独有库：`example/nodes/<start>/lualib/`
4. 游戏公共库：`example/lualib/`
5. 引擎库：`lualib/`（`skyext.*` 模块在这里）
6. skynet 库：`skynet/lualib/`

### 配置系统

配置文件使用 skynet env 机制，分两层：

- **节点配置**：`example/etc/account1.conf.lua` — skynet 启动参数
- **应用配置**：`example/etc/nodes/common.app.lua` — 业务参数

核心配置 `example/etc/core.conf.lua`：
```lua
root = "./"                          -- 指向 skyext 根目录
skyext_root = root                   -- 引擎根
game_root = root .. "example/"       -- 游戏根
include "paths.conf.lua"             -- 同目录相对路径（skynet include 使用路径累加）
```

**注意**：skynet 的 `include` 使用 `current_path = current_path .. path` 拼接，不是绝对路径解析。所以 `include "paths.conf.lua"` 是相对当前配置文件目录，**不要**写 `include(game_root .. "etc/paths.conf.lua")`。

读取配置使用 `skyext.config` 模块：
```lua
local config = require "skyext.config"
config.get("key")             -- 字符串
config.get_boolean("key")     -- 布尔
config.get_number("key")      -- 数值
config.get_table("key")       -- 表
```

### 引导链

每个服务启动时的加载顺序：
1. `lualib/loader.lua` — 设置 package.path 搜索优先级
2. `require "skyext"` → `lualib/skyext/init.lua` — ORM 元表扩展、config.init()、log.init()
3. 服务自身的 main.lua

### 引擎层 vs 游戏层

| 层级 | 路径 | 说明 |
|------|------|------|
| 引擎 | `lualib/skyext/` | 通用模块，`skyext.*` 命名空间 |
| 引擎 | `service/` | 通用服务（gm、hotfix、logger、cluster_discovery 等） |
| 引擎 | `public/` | 静态资源（gm.html） |
| 引擎 | `lualib/orm/` | ORM 框架 |
| 游戏 | `example/nodes/` | 节点入口和节点独有逻辑 |
| 游戏 | `example/lualib/` | 游戏公共库 |
| 游戏 | `example/etc/` | 游戏配置文件 |
| 游戏 | `example/proto/` | 协议定义 |
| 游戏 | `example/schema/` | ORM 数据模式 |

**设计模式**：引擎服务可以通过搜索路径向上依赖游戏层模块（如 `entity_agent.lua` 的 `require("entity_handler." .. type_name)`），这是有意的扩展点设计。

## 构建与运行

```bash
# 初始化
make init

# 编译（在 example/ 下）
cd example && make build

# 生成协议和 schema
cd example && make proto && make schema

# 启动（必须在 skyext 根目录，因为 root="./"）
./bin/skynet example/etc/account1.conf.lua
./bin/skynet example/etc/role1.conf.lua
```

**关键**：skynet 必须从 skyext 根目录启动，不能 `cd example`，否则 `root="./"` 指向错误位置。

## 技术栈

- **运行时**：skynet（C + Lua 5.4）
- **数据库**：MongoDB（通过 skynet.db.mongo）
- **服务发现**：etcd
- **加密**：系统 OpenSSL（HMAC-SHA256/SHA512，lualib-src/crypto.c）
- **协议**：sproto
- **TLS**：skynet 编译时启用 ltls 模块

## 代码风格

- Lua `require` 使用空格语法：`require "skyext.config"`（不是 `require("skyext.config")`）
- 模块返回表模式：`local M = {} ... return M`
- 日志使用 `skyext.log`，不要直接 `print`
- 错误码定义在 `skyext.errcode`

## Git 提交约定

- **直接提交到 `main` 分支**，不新建功能分支、不走 PR 流程（本仓库约定）
- 提交信息**禁止**添加 `Co-Authored-By` 尾部标记
- 遵循 Conventional Commits 格式：`type(scope): description`，description 和 body 尽量用中文
- 关联 GitHub issue 的提交信息必须带 issue 引用
- issue 引用规则：短写 `#123` 永远指向**当前 commit 所在仓库**的 issue；只要引用的不是当前仓库的 issue，就必须写完整 `owner/repo#123`
  - 本仓库的 commit 引用本仓库 issue：可写 `#123`
  - 本仓库的 commit 引用其他仓库 issue：必须写完整路径，如 `owner/repo#123`

## 常见陷阱

1. **不要在引擎模块中裸 require** — 必须用 `skyext.` 前缀
2. **不要从 example/ 目录启动 skynet** — 必须从根目录启动
3. **skynet config include 不是绝对路径** — 使用同目录相对路径
4. **service/logger/ 内部的裸 require 是安全的** — 通过 SERVICE_PATH 解析（global、cmd、bucket 等）
5. **`require "skyext"` 解析为 `skyext/init.lua`** — 利用 Lua 的 `?/init.lua` 模式
6. **Lua C 模块子模块加载** — `require "traceback.c"` 在 `traceback.so` 中查找 `luaopen_traceback_c`（searcher[4]）
