---
kind: configuration_system
name: SkyExt 配置系统：基于 Skynet env 的 Lua 配置文件分层加载
category: configuration_system
scope:
    - '**'
source_files:
    - lualib/config.lua
    - etc/core.conf.lua
    - etc/account1.conf.lua
    - etc/role1.conf.lua
    - etc/app/common.app.lua
    - etc/app/role1.app.lua
    - etc/app/account1.app.lua
    - etc/app/monitor.app.lua
    - hotfix/20260120-patch1/hotfix.conf.lua
---

## 1. 整体方案

SkyExt 使用 **Skynet 原生 `skynet.getenv/setenv` 键值存储**作为运行时配置总线，配合自研 `lualib/config.lua` 实现“应用级 Lua 配置文件 → Skynet env → 模块按需读取”的分层加载机制。所有业务服务通过 `require "config"` 统一访问配置，不直接操作 Skynet 内核。

## 2. 核心文件与职责

- `lualib/config.lua`：配置加载与访问库。提供 `get/get_boolean/get_number/get_table` 四个类型化读取接口，以及 `init()` 入口。
- `etc/core.conf.lua`：Skynet 启动参数（`luaservice`、`lua_path`、`bootstrap`、`thread`、`harbor`、`logservice` 等），被每个进程 conf 通过 `include` 复用。
- `etc/<app>.conf.lua`：进程级入口配置，声明 `app_config_path`、`start`，并 `include "core.conf.lua"`。
- `etc/app/*.app.lua`：应用级配置表（Lua 源码），按进程拆分（如 `role1.app.lua`、`account1.app.lua`、`monitor.app.lua`），并通过 `include "common.app.lua"` 共享公共配置。
- `etc/app/common.app.lua`：全局默认配置（etcd/mongo/sproto/日志/JWT/http 等），可被子 app 覆盖。
- `hotfix/.../hotfix.conf.lua`：热更新配置清单，声明要重载的资源（reload_res/reload_sproto/reload_orm_schema）和代码补丁。

## 3. 架构与加载流程

1. **Skynet 启动阶段**：由 `etc/account1.conf.lua` 等进程 conf 指定 `app_config_path = "etc/app/account1.app.lua"`，并通过 `include "core.conf.lua"` 注入 luaservice/lua_path 等路径。
2. **应用初始化**：任意服务调用 `config.init()`（通常由主服务在启动时调用）。该函数检查 `skynet.getenv("app_config_loaded")` 防止重复加载；若未加载，则读取 `skynet.getenv("app_config_path")`，调用内部 `load_config` 解析对应 `.app.lua`。
3. **配置文件解析**：`load_config` 使用 `load(code, ..., result)` 将目标 Lua 文件载入到一个空 table 中执行，从而把顶层赋值写入结果表；支持 `include "xxx"` 语法（通过 metatable 的 `__index.include` 钩子）和 `$VAR` shell 风格环境变量替换（`os.getenv`）。
4. **回写 Skynet env**：解析完成后，将结果表中每个 key/value 通过 `skynet.setenv` 写回——table 类型先经 `serialize` 序列化为字符串，标量直接 tostring。
5. **运行时读取**：各模块通过 `config.get(key)/get_boolean/get_number/get_table` 获取值，内部先查本地缓存 `conf[key]`，再 fallback 到 `skynet.getenv(key)`，对布尔/数字做类型转换，对 table 用 `load("return " .. s)` 反序列化。
6. **热更新**：`hotfix.conf.lua` 中的 `reload_res` / `reload_sproto` / `reload_orm_schema` / `clearcache` 等开关控制热更时是否重新加载策划表、协议、ORM schema 及清理 Lua 代码缓存。

## 4. 约定与约束

- **配置文件必须是合法 Lua 源码**：`app_config_path` 指向的文件会被 `load` 执行，因此只能包含安全的 Lua 表达式与 `include` 调用。
- **进程级配置必须声明 `app_config_path` 和 `start`**：`config.init()` 会因缺少 `app_config_path` 而 `error`。
- **配置只加载一次**：`app_config_loaded` 标记确保同一进程内多次调用 `config.init()` 是幂等的。
- **配置项命名即 key**：`.app.lua` 中定义的顶层变量名就是后续 `config.get(key)` 的键名，例如 `cluster_node_name`、`mongo_config`、`sproto_index`、`login_jwt_secret` 等。
- **公共配置下沉到 `common.app.lua`**：etcd、MongoDB、sproto、日志、JWT、HTTP body size 等跨进程共享配置集中定义，各进程 app 仅覆盖差异部分。
- **路径变量通过 `root` 与 `start` 传递**：`core.conf.lua` 用 `root`、`start` 拼接 luaservice/lua_path，这两个变量由上层 Skynet 启动参数传入，而非写在 app 配置中。
- **环境变量注入点**：配置文件中的 `$VAR` 会通过宿主进程的 `os.getenv` 展开，用于注入敏感信息或部署相关路径。
- **热更新清单独立于运行配置**：`hotfix.conf.lua` 使用 `return { ... }` 返回表结构，字段 `desc/checksum/gitsha_base/gitsha_update/time/update_files/code_files/reload_*` 由热更服务消费，与 `etc/app/*.app.lua` 解耦。

## 5. 使用范围

该配置体系被 `app/*` 下的所有业务服务（account、role、robot、monitor）以及 `lualib/dbmgr`、`lualib/distributed_lock`、`lualib/http_server`、`lualib/log` 等基础设施库广泛引用，构成 SkyExt 框架统一的配置访问面。