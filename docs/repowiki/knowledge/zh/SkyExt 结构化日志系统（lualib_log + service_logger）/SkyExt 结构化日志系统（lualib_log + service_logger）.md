---
kind: logging_system
name: SkyExt 结构化日志系统（lualib/log + service/logger）
category: logging_system
scope:
    - '**'
source_files:
    - lualib/log/init.lua
    - lualib/log/logger.lua
    - lualib/log/log_level.lua
    - lualib/log/formatter.lua
    - lualib/log/bucket/init.lua
    - lualib/log/bucket/console.lua
    - lualib/log/bucket/file.lua
    - lualib/log/bucket/service.lua
    - service/logger/main.lua
    - service/logger/start.lua
    - service/logger/cmd.lua
    - service/logger/bucket.lua
---

## 1. 整体方案

SkyExt 的日志系统由两部分组成：
- **客户端库** `lualib/log/`：提供统一的 `log` 接口，封装结构化字段收集、级别过滤、traceback 捕获、以及通过 bucket 抽象写入后端。
- **服务端** `service/logger/`：一个独立的 Skynet 服务，注册 `.logger` 地址，接收来自各服务的 `PTYPE_LOG / PTYPE_LOG_ERR` 消息，按配置路由到文件/控制台等 sink，并支持热重载与过载丢弃。

应用代码统一通过 `require "log"` 使用，无需感知底层是本地 console 还是远程 logger 服务。启动时调用 `log.init()` 完成全局初始化。

## 2. 关键文件与职责

| 文件 | 职责 |
|---|---|
| `lualib/log/init.lua` | 暴露 `log.debug/info/warn/error/sys_assert/sys_error/xpcall_msgh/config` 默认实例；`init()` 从 `config` 读取 `log_level`、`log_src`、`log_print_table` 并注入 `_G.assert/_G.error/_G.pcall/_G.xpcall` |
| `lualib/log/logger.lua` | 核心 Logger 对象实现：结构化事件打包 `_pack_events`、级别过滤 `_log`、traceback 采集（C 扩展 `traceback.c`）、错误上下文保护（safe_pcall/safe_xpcall 计数器防重入） |
| `lualib/log/log_level.lua` | 定义优先级常量 `DEBUG=4 > INFO=3 > WARN=2 > ERROR=1 > FATAL=0` |
| `lualib/log/formatter.lua` | 文本格式化（ANSI 彩色）与 JSON 序列化（`cjson.safe.encode`），输出字段含 `module/level/line/msg/time` 及用户自定义 events |
| `lualib/log/bucket/init.lua` | Bucket 工厂：按 name 动态 `require "log.bucket.console|file|service"`，并提供 `get_default()` 回退到 console |
| `lualib/log/bucket/console.lua` | 本地 stdout 输出，走 formatter |
| `lualib/log/bucket/file.lua` | 本地文件输出 |
| `lualib/log/bucket/service.lua` | 将记录通过 `skynet.send(".logger", "text", record)` 发送到 logger 服务 |
| `service/logger/main.lua` | 进程入口，用 xpcall 包裹启动，失败时写 `bootfaillogpath` 后 `skynet.abort()` |
| `service/logger/start.lua` | 注册 SYSTEM/text 协议，订阅内核日志；创建 `global.bucket`；回调 `PTYPE_LOG/PTYPE_LOG_ERR` 分发；SIGHUP 触发 `bucket.reload()` |
| `service/logger/cmd.lua` | GM 命令：`put/close/reload` |
| `service/logger/bucket.lua` | 聚合多个 sink（如 file + console），支持 overload 检测丢弃非 ERROR 日志 |

## 3. 架构与数据流

```
业务模块
  → require "log".info(msg, key, value, ...)
  → logger._raw_log(level, stack_depth, msg, ...)
    → _pack_events: 将 key/value 对转为 {key, value}[] 数组
    → save_to_bucket: 组装 g_record = {module, level, timestamp, line, msg, events}
    → get_bucket(): 优先取 service_bucket（已连接 .logger 服务），否则 default_bucket(console)
    → bucket:put(record)
```

当存在 `service/logger` 服务时，`bucket.service` 会把记录以 Skynet 消息发往 `.logger`，由该服务统一落盘或转发。没有该服务时降级为本地 console/file。

## 4. 结构化字段约定

每条日志记录固定包含以下字段：
- `module`：Logger 实例名（默认取自 `SERVICE_ARGS`，即当前 Skynet 服务名）
- `level`：字符串化级别 `FATAL/ERROR/WARN/INFO/DEBUG`
- `timestamp`：Unix 时间戳（秒+毫秒）
- `line`：调用源位置 `source:line`（可通过 `log_src=false` 关闭）
- `msg`：主消息体（table 类型会经 `util_table.tostring` 序列化）
- `events`：用户传入的键值对数组，JSON 输出时会平铺为顶层字段

冲突处理：若用户 events 中使用了保留键（`module/level/timestamp/line/msg`），会自动追加下标后缀（如 `module_1`）避免覆盖。

## 5. 级别与过滤策略

- 级别数值越小优先级越高：`FATAL(0) < ERROR(1) < WARN(2) < INFO(3) < DEBUG(4)`。
- 每个 Logger 实例维护 `self.level`，低于该级别的日志直接丢弃，不进入序列化流程。
- 默认级别 `DEBUG`，可通过 `log.config({ level = ... })` 调整。
- `error` 级别自动附加 traceback 字段；`sys_assert`/`sys_error` 在首次触发时以 `FATAL` 级别记录完整堆栈后再抛出异常。

## 6. 全局钩子与健壮性

`log.init()` 会替换全局函数：
- `_G.assert` → `sys_assert`：断言失败时先记 FATAL 日志再抛错
- `_G.error` → `sys_error`：同上
- `_G.pcall` → `safe_pcall` / `_G.xpcall` → `safe_xpcall`：通过 pcall/xpcall 计数器防止错误处理上下文内再次触发日志导致死循环

## 7. 运行时能力

- **热重载**：logger 服务监听 SIGHUP，调用 `global.bucket.reload()` 重新加载 sink 配置。
- **过载保护**：`global.log_overload` 为真时，非 ERROR 日志被丢弃，仅保留错误通道。
- **内核日志桥接**：通过 `PTYPE_TEXT` 协议收集 Skynet 内核 text 日志，含 `[Ee]rror` 的标记为 warn，其余 info。
- **启动失败兜底**：`main.lua` 用 xpcall 包裹启动，失败时写入 `bootfaillogpath`（默认 `logs/bootfail.log`）后 abort。

## 8. 配置来源

所有配置均通过框架 `config` 模块读取：
- `log_level`：数字级别
- `log_src`：是否采集 source 行号
- `log_print_table`：是否打印 table 类型参数
- `log_config`：logger 服务的 sink 配置表，传给 `bucket.new(log_config)`

## 9. 使用约束与约定

- 调用日志 API 时必须以**成对的 key-value** 传递结构化字段（`...` 长度必须为偶数），否则会 `assert` 失败。
- 推荐在应用 `main.lua` 中尽早调用 `log.init()`，以便全局 assert/error 钩子生效。
- 生产环境建议部署 `service/logger` 并通过 `bucket.service` 集中收集日志，便于统一格式化和归档。
- 自定义 bucket 需遵循 `{new(conf), put(record), close(), reload()}` 接口，并通过 `log.bucket.<name>` 模块暴露。