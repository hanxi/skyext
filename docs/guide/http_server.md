# HTTP 服务端

`skyext.http_server` 以**命名实例**的方式提供 HTTP 服务：每个名字对应独立的 watchdog、agent 与路由表，同一节点内的多个端口（如对外的业务端口与内网 GM 端口）不会互相串路由。

```lua
local http_server = require "skyext.http_server"

local s = http_server.new("account")
s:start({ host = "0.0.0.0", port = 8080, agent_count = 8 })
s:register_router("account_router")
```

实例名必须是 `[%a_][%w_]*`；同一个 Lua 虚拟机里 `new` 同一个名字拿到的是同一个实例。`start` 的 `host` 默认 `0.0.0.0`、`port` 默认 `8080`、`agent_count` 默认 8，`port` 传 `0` 时由系统分配，返回的 `{ host, port, agent_count, limits }` 里是实际监听信息。`register_router` 必须在 `start` 之后调用，返回时所有 agent 都已注册完；可以调多次，同 `method + path` 由后注册的覆盖。

## 资源上限

HTTP 端口直接暴露给不受信任的客户端，默认配置要回答的问题是「单个客户端能不能让节点不可用」，而不是「吞吐能跑多高」。各项上限按下面的顺序取值：

1. `start(conf)` 里显式给出的同名字段；
2. 节点配置中的 `http_<字段名>`；
3. 内置默认值。

任何一项配置非法（非整数、超出范围）都会在 `start` 时直接报错，不会静默回退到默认值——否则一个拼错的配置名就会让上限悄悄失效。

| 字段 | 节点配置名 | 默认值 | 说明 |
| --- | --- | --- | --- |
| `max_connections` | `http_max_connections` | 1024 | 同时在处理的连接数上限，超出的新连接**直接关闭**，不回 503（回 503 得先把请求读完，正好是被打满时最不该做的事） |
| `read_timeout` | `http_read_timeout` | 10 | 读完一个完整请求（请求行 + 头 + body）的总时限，秒。这是**绝对**时限，不随收包续期，否则逐字节发送的 slowloris 就能无限续命 |
| `write_timeout` | `http_write_timeout` | 10 | 写出一个响应的时限，秒。客户端不收包时写操作同样会一直阻塞 |
| `keepalive_timeout` | `http_keepalive_timeout` | 60 | keep-alive 连接两次请求之间的空闲时限，秒。设为 `0` 表示关闭 keep-alive |
| `keepalive_requests` | `http_keepalive_requests` | 100 | 单条连接最多服务多少个请求，到达后主动关闭以回收内存与 fd |
| `request_body_size` | `http_request_body_size` | 1048576 | 请求 body 字节上限，超过返回 413 并关闭连接 |

超时由每条连接一个守卫协程实现：到期后 `shutdown` 该 fd，正在阻塞的读写会正常失败，沿原有错误路径收尾。日志中 `http connection timeout` 的 `phase` 字段区分是哪一段超时（`read` / `keepalive` / `write`）。

### 连接数统计

```lua
local stats = s:stats() -- { active = 12, rejected = 0, max_connections = 1024 }
```

`rejected` 是累计被上限挡掉的连接数，持续增长说明该调大 `max_connections` 或排查慢请求。被打满时的拒绝日志按秒限流，不会把日志通道一起压垮。这两个数同时按实例名导出成指标，见[指标采集与导出](metrics.md#内置指标)。

## keep-alive 行为

- 响应总是显式带 `connection: keep-alive` 或 `connection: close`，不依赖客户端对 HTTP 版本的默认假设。
- 下列情况会在当前响应后关闭连接：`keepalive_timeout` 为 0、已达到 `keepalive_requests`、客户端请求头带 `connection: close`、请求读取阶段就失败（4xx/5xx，此时缓冲区剩余内容不可知，复用只会让下一个请求解析错位）。
- 每个响应都有确定长度：有 body 时写 `content-length`，流式写出时用 chunked，无 body 时补 `content-length: 0`。按 RFC 7230，`204` / `304` / `1xx` 不带 `content-length`，它们本身定义为无 body。
- **不支持 HTTP 流水线（pipelining）**：底层 `httpd.read_request` 会丢弃超出 `content-length` 的预读数据，同一个包里的第二个请求拿不回来。浏览器早已默认关闭流水线，这里以 keep-alive 串行复用为准。

## 路由约定

路由模块是一张 `method -> path -> handler` 的表，`handler(req, res)`：

- `req`：`id` / `addr` / `method` / `url` / `path` / `query` / `header` / `body`，以及 `parse_query()` 与 `read_json()`。`read_json()` 只在 body 是 JSON 对象或数组时返回表，空 body、坏 JSON、JSON 标量一律返回 `nil, reason`。
- `res`：`write(status, body, header)` / `write_json(data, header)`（固定 200 + `application/json`）/ `write_file(path, header)`（文件读不到回 404），另有可供填充的 `res.header`。响应一律带上 `X-Powered-By` 与一组 `Access-Control-Allow-*`（允许任意来源、`GET, POST, OPTIONS`）。

路由未命中时由 agent 兜底：method 没有任何路由回 405，path 没有 handler 回 404，`OPTIONS` 直接回 204 不进路由。

handler 必须写且只写一次响应：

- 一个字都不写时，agent 会补一个 500 并关闭连接（keep-alive 下客户端否则会一直等到自己超时）；
- handler 抛错同样补 500 并关闭连接，异常信息记 ERROR 日志；
- 写第二次会被挡掉并记 ERROR 日志，因为那会把 keep-alive 的字节流写乱，导致后续请求全部解析错位。
