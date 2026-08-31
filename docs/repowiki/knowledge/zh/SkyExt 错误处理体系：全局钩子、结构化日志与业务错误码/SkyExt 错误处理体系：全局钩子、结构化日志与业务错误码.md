---
kind: error_handling
name: SkyExt 错误处理体系：全局钩子、结构化日志与业务错误码
category: error_handling
scope:
    - '**'
source_files:
    - lualib/log/init.lua
    - lualib/log/logger.lua
    - lualib/errcode.lua
    - lualib/skyext.lua
    - lualib/cmd_api.lua
    - lualib/http_server/agent.lua
    - lualib/distributed_lock.lua
    - app/account/lualib/account_router.lua
    - app/role/login/login_request.lua
    - service/gm_sys.lua
---

## 1. 整体方案

SkyExt 在 Skynet 之上构建了一套统一的错误处理体系，核心思路是：**启动时通过 `log.init` 全局替换 Lua 的 `assert`/`error`/`pcall`/`xpcall`**，使所有异常都先经过结构化日志记录，再抛出；业务层使用集中定义的 `errcode` 常量作为返回值中的 `code` 字段，配合 `true/false` 布尔前缀统一表达成功/失败。

- **全局钩子**：`lualib/log/init.lua` 在 `skynet.init` 中把 `_G.assert`、`_G.error`、`_G.pcall`、`_G.xpcall` 分别替换为 `sys_assert`、`sys_error`、`safe_pcall`、`safe_xpcall`。这意味着任何模块只要 `require "log"` 后调用初始化，后续抛出的所有异常都会走日志流程。
- **日志器**：`lualib/log/logger.lua` 提供结构化日志（key-value events）、traceback C 扩展（`lualib-src/traceback.c`）以及 `xpcall_msgh` 消息处理器，用于在 xpcall 回调中输出带堆栈的错误。
- **业务错误码**：`lualib/errcode.lua` 用元表 `__index` 拦截未定义键并直接 `error("Invalid error code: ...")`，强制调用方只能使用预定义常量（如 `OK=0`、`TOKEN_ERROR=7`、`DB_ERROR=6`、`ROLE_NOT_EXIST=3`、`SERVER_NOT_EXIST=9`、`MONGO_DUPLICATE_KEY=11000` 等），避免魔法数字散落。

## 2. 关键文件与职责

| 文件 | 职责 |
|---|---|
| `lualib/log/init.lua` | 暴露 `log.init()`，完成全局 `assert/error/pcall/xpcall` 替换 |
| `lualib/log/logger.lua` | 日志对象实现：结构化事件、traceback、`sys_assert`/`sys_error`/`xpcall_msgh`、`safe_pcall`/`safe_xpcall` |
| `lualib/errcode.lua` | 集中业务错误码 + 元表保护 |
| `lualib/skyext.lua` | 框架入口，`skynet.init` 中 `pcall(require, "config")` → `pcall(config.init)` → `pcall(log.init)`，确保日志在配置加载失败时仍能工作 |
| `lualib/cmd_api.lua` | 服务命令分发，未知命令直接 `error(...)` |
| `lualib/http_server/agent.lua` | HTTP 请求处理，每个请求用 `xpcall(handle_request, log.xpcall_msgh, ...)` 包裹，捕获 handler 异常并写回 4xx/5xx |
| `lualib/distributed_lock.lua` | 分布式锁，etcd 交互失败 `log.error` 后返回 `false`；锁过期回调用 `xpcall(lock_info.expired_cb, debug.traceback, ...)` 安全执行 |
| `app/account/lualib/account_router.lua` | 账号路由，统一返回 `{ code = errcode.XXX, ... }` 结构 |
| `app/role/login/login_request.lua` | 登录请求，按校验阶段填充 `errcode.TOKEN_ERROR` / `PROTO_CHECKSUM` / `ROLE_NOT_EXIST` / `SERVER_NOT_EXIST` |
| `service/gm_sys.lua` | GM 系统命令，全部以 `return true/false, message` 形式返回结果 |

## 3. 架构与约定

### 3.1 异常路径
1. **断言失败**：调用 `assert(...)` → 命中 `log.sys_assert` → 写入 FATAL 级日志（含 traceback）→ 调用 `raw_error` 抛出。
2. **显式错误**：调用 `error(...)` → 命中 `log.sys_error` → 首次触发时额外记录一次 FATAL traceback → 抛出。
3. **可恢复错误**：使用 `pcall`/`xpcall`（已被替换为 `safe_pcall`/`safe_xpcall`），计数器用于判断是否在错误处理上下文中，避免嵌套 traceback。
4. **HTTP 请求**：`http_server/agent.lua` 在每个请求外层包 `xpcall(handle_request, log.xpcall_msgh, ...)`，handler 抛错会被捕获并记录 warn，同时关闭 socket。
5. **GM 命令**：`cmd_api.dispatch` 对未知命令直接 `error`；已注册命令通过 `skynet.ret(skynet.pack(f(...)))` 返回，上层 GM 路由用 `pcall` 包装调用。

### 3.2 业务错误码约定
- 所有跨服务 RPC 或协议响应统一采用 `{ ok = true/false, code = errcode.XXX, ... }` 或 `true/false, message` 形式。
- 常见模式：
  - 成功：`return true, data` 或 `return { code = errcode.OK, ... }`
  - 失败：`return false, "message"` 或 `return { code = errcode.DB_ERROR, msg = "..." }`
- 错误码来源严格限定于 `lualib/errcode.lua`，访问未定义键会立即 `error`。

### 3.3 日志级别与降级
- 日志模块自身也做防护：`logger:_log` 调用底层 `pcall(_raw_log, ...)`，若日志写入失败则 fallback 到 `print(err, msg, ...)`，保证即使日志子系统崩溃也不影响业务。
- `log.init` 本身用 `xpcall(default_logger.config, default_logger.error, ...)` 调用，防止配置阶段出错导致整个进程无法启动。

## 4. 约束与规则

1. **禁止直接使用原始 `assert`/`error`**：启动后 `_G.assert` 和 `_G.error` 已被替换为带结构化日志的版本，所有断言和错误都会记录 traceback。
2. **错误码必须来自 `errcode` 模块**：`errcode` 的元表 `__index` 对未定义键直接 `error`，编译期/运行期均阻止魔法数字。
3. **RPC/协议层不抛异常，返回结构化结果**：应用层（account、role 等）统一返回 `{ code = errcode.XXX, ... }`，由调用方根据 `code` 判断分支。
4. **外部 I/O 调用使用 `pcall`/`xpcall`**：etcd 请求、MongoDB 操作、HTTP 请求等均在各自模块内用 `pcall`/`xpcall` 包裹，失败时 `log.error` 并返回 `nil/false`。
5. **HTTP handler 必须幂等且不会阻塞**：每个请求被 `xpcall` 包裹，异常不会传播到 Skynet 主循环，但会记录 warn 并关闭连接。
6. **分布式锁过期回调必须健壮**：`distributed_lock.lua` 用 `xpcall(lock_info.expired_cb, debug.traceback, ...)` 执行用户回调，失败仅记录错误，不影响锁清理。

## 5. 缺失与注意事项

- 没有统一的中间件式错误处理器（如 Gin 风格的 middleware chain），错误处理分散在各层（HTTP agent、GM router、分布式锁等）。
- 没有 panic/recover 机制（Lua 无 panic），依赖 `xpcall` + 全局钩子实现类似效果。
- 日志级别、是否打印 table、traceback 深度等通过 `config.get_*` 读取，但未发现运行时动态切换级别的 API。
- 测试目录（`test/test_etcd`、`test/test_jwt`）未展示业务错误码的使用方式，仅验证基础设施库。
