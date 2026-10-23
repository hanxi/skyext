# GM 命令接口协议文档

## 概述

GM（Game Master）命令系统提供了一套 HTTP RESTful API，用于执行游戏管理命令。所有接口返回 JSON 格式数据。

**基础 URL**: `http://localhost:<gm_http_port>`（代码默认 `9090`，由各节点 `gm_http_port` 配置覆盖；以下示例使用 RoleNode1 的端口 `9092`）

GM HTTP 服务是独立的命名实例，与节点的业务 HTTP 端口（如 Account 的 `account_http_port`）互不共用路由：业务端口不会暴露 `/gm/*`，GM 端口也不会暴露业务接口。监听地址默认只绑定 `127.0.0.1`，需要对外暴露时显式配置 `gm_http_host`（务必同时配好 `gm_auth_token` 并限制来源）。HTTP agent 数量默认 2，由 `gm_agent_count` 配置；连接与超时上限见 [HTTP 服务端](http_server.md#资源上限)。

所有接口都要带 token，详见[鉴权](#鉴权)。

---

## 接口列表

### 1. 获取命令列表

获取所有已注册的 GM 命令列表。

**请求**

```
GET /gm/list
```

**响应**

```json
{
  "code": 0,
  "commands": [
    {
      "cmd": "命令名称",
      "desc": "命令描述",
      "params": {
        "参数名1": "参数描述1",
        "参数名2": "参数描述2"
      },
      "service_count": 2
    }
  ]
}
```

返回节点上所有已注册的命令。GM 只认一个 token，没有按命令分级，见下文[为什么不分级](#为什么不分级)。

**字段说明**

| 字段 | 类型 | 说明 |
|------|------|------|
| code | number | 状态码，0 表示成功，非 0 表示失败 |
| commands | array | 命令列表 |
| commands[].cmd | string | 命令名称 |
| commands[].desc | string | 命令描述 |
| commands[].params | object | 命令参数定义，key 为参数名，value 为参数描述 |
| commands[].service_count | number | 注册该命令的服务数量 |

**示例**

```bash
curl -H "Authorization: Bearer <token>" http://localhost:9092/gm/list
```

---

### 2. 执行 GM 命令（GET）

通过 GET 方式执行 GM 命令，适用于简单的命令调用。

**请求**

```
GET /gm/execute?cmd=<命令名>&<参数名1>=<参数值1>&<参数名2>=<参数值2>
```

**查询参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| cmd | string | 是 | 要执行的命令名称 |
| services | string | 否 | 指定执行的服务列表，逗号分隔，地址或本地服务名均可（见[服务地址格式](#服务地址格式)），如 `:01000002,.entity_agent:role:1`。不指定则在所有注册该命令的服务上执行 |
| 其他参数 | string | 否 | 命令所需的其他参数 |

**响应**

```json
{
  "code": 0,
  "cmd": "命令名称",
  "results": [
    {
      "service": ":01000002",
      "success": true,
      "data": "执行结果数据"
    },
    {
      "service": ":01000003",
      "success": false,
      "error": "错误信息"
    }
  ]
}
```

**字段说明**

| 字段 | 类型 | 说明 |
|------|------|------|
| code | number | 状态码，0 表示成功，非 0 表示失败 |
| cmd | string | 执行的命令名称 |
| error | string | 错误信息（仅当 code 非 0 时存在） |
| results | array | 各服务的执行结果列表 |
| results[].service | string | 服务地址 |
| results[].success | boolean | 该服务上的执行是否成功 |
| results[].data | any | 执行成功时的返回数据 |
| results[].error | string | 执行失败时的错误信息 |

**示例**

```bash
# 执行 reload_res 命令
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=reload_res"

# 执行带参数的命令
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=kill&address=:01000002"

# 指定服务执行
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=gc&services=:01000002,:01000003"
```

---

### 3. 执行 GM 命令（POST）

通过 POST 方式执行 GM 命令，适用于复杂参数或需要传递 JSON 数据的场景。

**请求**

```
POST /gm/execute
Content-Type: application/json
```

**请求体**

```json
{
  "cmd": "命令名称",
  "services": [":01000002", ":01000003"],
  "参数名1": "参数值1",
  "参数名2": "参数值2"
}
```

**字段说明**

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| cmd | string | 是 | 要执行的命令名称 |
| services | array | 否 | 指定执行的服务列表，地址或本地服务名均可（见[服务地址格式](#服务地址格式)）。不指定则在所有注册该命令的服务上执行 |
| 其他字段 | any | 否 | 命令所需的其他参数 |

**响应**

响应格式与 GET 方式相同。

**示例**

```bash
# 执行简单命令
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "reload_res"}'

# 执行带参数的命令
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "kill",
    "address": ":01000002"
  }'

# 指定服务执行
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "gc",
    "services": [":01000002", ":01000003"]
  }'
```

---

## 服务地址格式

服务地址支持以下格式：

1. **十六进制地址**：`:01000002`（以冒号开头的十六进制字符串）
2. **本地服务名**：如 `.entity_agent:role:1`，用 `skynet.localname` 查找；省略前导点（`entity_agent:role:1`）也可以。找不到的名字记为该服务执行失败，不会退回到全部服务上执行
3. **整数地址**：POST JSON 的 `services` 数组可传整数地址；GET 查询参数始终是字符串，建议使用 `:01000002` 形式

---

## 错误码

| 错误码 | 值 | 说明 |
|--------|-----|------|
| OK | 0 | 成功 |
| 通用错误 | 1 | 通用错误 |
| PARAM_ERROR | 10 | 参数错误 |
| AUTH_FAILED | 11 | 鉴权失败 |

---

## 命令清单

命令由各服务自行注册，所以一个节点上有哪些命令取决于它起了哪些服务，以 `/gm/list` 的返回为准。下表是引擎内置的部分。

### 系统与调试

`service/gm_sys.lua` 注册（由 `.gm` 用 `uniqueservice` 拉起，所有节点都有）。`address` 参数接受 `:01000002`、`.gm` 这类本地名，或不带前缀的十六进制。

| 命令 | 参数 | 说明 |
|------|------|------|
| `list` | — | 列出 `.launcher` 拉起的服务，返回 `{地址 = 启动命令}` |
| `service` | — | 列出 unique service |
| `stat` | `timeout` | 各服务的消息数、CPU、队列等统计 |
| `mem` | `timeout` | 各服务的 Lua 堆占用 |
| `gc` | `timeout` | 让每个 Lua 服务做一次 GC |
| `cmem` | — | 按服务统计的 C 内存占用 |
| `jmem` | — | jemalloc 统计 |
| `dumpheap` | — | jemalloc heap dump |
| `profactive` | `flag` | 开关 jemalloc heap profiling，`on` / `off`；不传只返回当前状态 |
| `netstat` | — | 网络连接统计 |
| `kill` | `address` | 杀掉服务 |
| `exit` | `address` | 让服务自己退出（debug EXIT） |
| `start` | `service`、`args` | 启动一个 lua 服务 |
| `log` | `service`、`args` | 启动 lua 服务并打开消息日志 |
| `snax` | `service`、`args` | 启动 snax 服务 |
| `clearcache` | — | 清 Lua 代码缓存 |
| `inject` | `address`、`filename`、`args` | 把节点上的 lua 文件注入到服务里执行 |
| `dbgcmd` | `address`、`cmd`、`args` | 执行任意 debug 命令 |
| `task` / `uniqtask` | `address` | 查看服务的协程 / 唯一任务 |
| `killtask` | `address`、`threadname` | 杀掉指定协程 |
| `info` | `address`、`args` | 服务自报的 INFO |
| `ping` | `address` | 往返耗时（1/100 秒） |
| `logon` / `logoff` | `address` | 开关该服务的消息日志 |
| `signal` | `address`、`sig` | 给服务发信号，不带 `sig` 时为默认信号 |
| `trace` | `address`、`proto`、`flag` | 开关协议 trace |
| `getenv` | `name` | 读 skynet 配置项 |
| `setenv` | `name`、`value` | 写 skynet 配置项 |

`stat` / `mem` / `gc` 的 `timeout` 单位是 skynet 的 1/100 秒，不传默认 300（3 秒），传 `0` 或负数表示不限时。

### 重载

| 命令 | 注册于 | 参数 | 说明 |
|------|--------|------|------|
| `reload_res` | `lualib/skyext/res.lua`（res 服务） | `filepaths` | 重载策划配置表：只换内容真的变了的文件，再广播 `res_reload` 事件；不传 `filepaths` 则扫 `res_path`、`res_lazy_path` 下全部文件。`filepaths` 用 POST JSON 传数组，或用 GET 传逗号分隔的字符串；路径必须以 `.lua` 结尾，有一个不合法或文件不存在就整体失败、不做任何重载 |
| `reload_sproto_schema` | `service/sproto_loader.lua` | — | 重新加载已载入的全部 sproto schema |
| `reload_orm_schema` | `lualib/skyext/dbmgr.lua`（dbmgr 服务） | — | 重新 require `game.orm.schema` 并就地替换，见[热更新](hotfix.md#orm-schema-热更) |

这三条都是热更流程里的步骤，单独执行见[热更新](hotfix.md)。

`lualib/skyext/profiler.lua` 里还有 `profiler_start` / `profiler_status` / `profiler_result`，但仓库内没有服务 `require` 它，默认不加载，也还是原型状态。

### 示例命令

```bash
# 列出所有服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=list"

# 杀死指定服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=kill&address=:01000002"

# 启动新服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=start&service=test&args=arg1"

# 重载指定的几张配置表
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" -H "Content-Type: application/json" \
  -d '{"cmd": "reload_res", "filepaths": ["example/res/hero.lua"]}'
```

---

## 鉴权

### 传 token

`/gm/execute`（GET/POST）和 `/gm/list` 都需要 token，传递方式二选一：

- HTTP Header: `Authorization: Bearer <token>`
- 请求参数（query 或 body）: `token=<token>`

`cmd`、`services`、`token` 三个字段不会作为命令参数下传，其余字段原样进 `params`。

### 配 token

配在 `example/etc/nodes/common.app.lua`：

```lua
gm_auth_token = "..."
```

token 用 `openssl rand -hex 32` 现生成，由 `skyext.secret` 校验强度。**未配置、命中占位符黑名单（如 `CHANGE_ME_TO_RANDOM_TOKEN`）、或少于 16 字符**时打一条 ERROR 日志并拒绝所有 `/gm/*` 请求。`allow_insecure_secret` 只放宽登录密钥，对 GM 无效。

### 为什么不分级

GM 口是管理员接口：`kill`、`inject`、`setenv`、`getenv`、热更都在里面，拿到 token 就等于拿到进程控制权，再按指令分级也挡不住什么。要分人分权、要留操作记录，应该由对接这个接口的 admin 后台来做——它有账号体系，也知道是谁点的按钮。框架这一侧只负责认 token 和执行。

因此部署上真正要守住的是：GM 端口默认只听 `127.0.0.1`，需要对外时用 `gm_http_host` 显式放开并限制来源。

### 执行记录

每次执行完写一条 INFO 日志，鉴权失败写一条 WARN：

```
GM command executed peer=10.0.0.9:51324 cmd=gc result=ok
GM auth failed peer=10.0.0.9:51324 error=invalid token
```

`result` 为 `ok` / `partial`（部分服务失败）/ `failed`。进程内部调用的 `peer` 记 `internal`。日志写在执行**之后**，一行就能看出操作有没有落地；执行途中进程挂掉则不会留下这一行。

## 热更命令

### hotfix — 执行热更新

```bash
# dry-run 预演
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix", "hotfix_dir": "example/hotfix/20260831-patch1", "mode": "dry_run"}'

# 正式执行（需 confirm=true）
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix", "hotfix_dir": "example/hotfix/20260831-patch1", "confirm": "true"}'
```

**参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| hotfix_dir | string | 是 | 相对于 skynet `root`（示例为仓库根目录）的热更包路径，如 `example/hotfix/20260831-patch1`；必须是不含 `..` 的相对路径，与 CLI `hotfix refresh <dir>` 的取值完全一致 |
| mode | string | 否 | `run`（默认）或 `dry_run`（仅预演） |
| confirm | string | 否 | 执行模式下必须传 `"true"` |

**响应（执行模式）**

外层仍为 `{code, cmd, results}`；检查每项 `results[].success`。成功时该项 `data.steps` 包含步骤列表；热更执行失败时该项 `data.guidance` 可包含处置建议。不要只根据外层 `code = 0` 判断热更成功。操作前请阅读[热更新文档](hotfix.md)中的路径与 `update_files` 限制。

**响应（dry_run 模式）**

预演成功时，`results[].data` 为执行计划：`steps` 列表、`patchers` 目标服务命中情况和 `warnings`。

### hotfix_history — 查看热更历史

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix_history", "limit": "10"}'
```

**参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| limit | string | 否 | 返回最近 N 条记录（默认 10） |

---

## 死信队列命令

可靠消息连续投递失败达到上限后会被移入死信队列（见[实体系统设计](https://github.com/hanxi/skyext/blob/main/docs/design/entity_system.md)）。死信队列存在 MongoDB 里，是整个集群共享的一份数据，所以 `entity_dlq` 按节点单例注册这三条命令——每个实体类型注册一次会让一次查询变成 N 次重复查询。

### dlq_list — 列出死信

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "dlq_list", "target_type": "role", "limit": "20"}'
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| target_type | string | 否 | 按实体类型过滤 |
| target_id | string | 否 | 按实体 ID 过滤；能转成整数就按整数匹配，否则按字符串 key |
| limit | string | 否 | 最多返回条数，默认 50，上限 500（超过按 500 截断）；必须是 ≥1 的整数 |

返回 `{count, messages}`，按 `dead_time` 升序（最早进队的在前）。每条只含 `msg_id`、`seq`、`target_type`、`target_id`、`cmd`、`attempts`、`create_time`、`dead_time`、`dead_reason`——**不含 `args`**：那是业务负载，可能带玩家数据，不该经 GM 接口整份吐出来。要看负载请直接查库。

### dlq_replay — 重放一条死信

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "dlq_replay", "msg_id": "10023"}'
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| msg_id | string | 是 | 消息 ID，必须能转成整数 |

消息状态回到 `pending`，并尝试唤醒目标实体。返回里的 `poked` 表示唤醒是否成功；**`poked = false` 不代表重放失败**——消息已经回到队列，实体下次加载或重试定时器会接上。

重放前要先确认死因已经消除。投递失败通常是 handler 抛错，如果代码没改、数据没修，重放只会把同一条消息再送进死信队列一轮。

### dlq_discard — 丢弃一条死信

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "dlq_discard", "msg_id": "10023", "operator": "alice"}'
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| msg_id | string | 是 | 消息 ID，必须能转成整数 |
| operator | string | 否 | 操作人，记入文档便于追责 |

文档不会被删除，只是不再出现在 `dlq_list` 里。这条消息承载的业务效果就此永久丢失，填上 `operator`。

---

## 停服命令

### shutdown — 停服

由引擎服务 `service/node_shutdown.lua` 注册，每个调用了 `node_shutdown_api.start()` 的节点都有（示例的 `launcher.lua` 已调用）。

```bash
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=shutdown&timeout=60"
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| timeout | string | 否 | 等实体卸载的秒数，默认 60 |

立即返回 `shutdown started`，停服在后台进行：`stop_accepting` 钩子（role/gateway 节点的 `gate_tcp` 在这里关 gate，不再接新连接）→ 卸载本节点全部实体（落库、释放锁、踢下在线玩家）→ `release` 钩子（snowflake 归还机器号）→ 撤销节点租约 → 进程退出。有实体在超时内卸不掉时进程**不退出**并打 ERROR 日志，排查后可以再发一次。重复发送时返回 `already shutting down`。进度看节点日志。

游戏层挂钩子：

```lua
local node_shutdown_api = require "skyext.node_shutdown_api"
-- 停服时回调本服务的 CMD.stop_accepting
node_shutdown_api.add_hook("stop_accepting", "stop_accepting")
```

## 区服目录命令

由引擎服务 `service/realm.lua` 注册。区服目录存在 etcd，所有节点 watch，改动即时生效。

| 命令 | 参数 | 说明 |
|------|------|------|
| `realm_list` | — | 查看当前目录（servers / games / zones / gates） |
| `realm_gates` | — | 只看当前在线的网关，返回 `{<节点名> = {tcp_addr, ws_url, weight}}` |
| `realm_open` | `server`、`game`、`name`、`tag`、`zone` | 开服。`game` 不存在时一并创建，此时必须给一个已存在的 `zone`；`tag` 默认是大写的 `server` |
| `realm_set_zone` | `game`、`zone` | 调战区，`zone` 不存在时自动创建 |

```bash
curl -H "Authorization: Bearer <token>" \
  "http://localhost:9092/gm/execute?cmd=realm_open&server=s4&game=game3&zone=zone1&name=四区"
```

开服后，配了 `scope = "game"` 的作用域实体（如示例排行榜）会在几秒内为新 game 自动加载一份。

## 示例 Role 节点命令

由 `example/service/admin/main.lua`（admin 服务，role 节点启动时 `newservice("admin")`）注册，属于示例游戏层，不是引擎内置命令。它演示非实体服务如何经可靠消息改实体数据。

### send_mail — 发系统邮件

```bash
curl -H "Authorization: Bearer <token>" \
  "http://localhost:9092/gm/execute?cmd=send_mail&rid=123&title=补偿&content=维护补偿&res_type=101&res_id=10086&res_size=5"
```

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| rid | string | 是 | 收件人，角色必须存在 |
| title | string | 是 | 标题 |
| content | string | 否 | 正文 |
| res_type / res_id / res_size | string | 否 | 附件，三项一起给；领取时加进背包 |

返回可靠消息的 `msg_id`。邮件经可靠消息投递，收件人离线或在别的节点上都能收到。

## 指标命令

### metrics — 导出 Prometheus 文本

```bash
curl -X GET "http://localhost:9092/gm/execute?cmd=metrics" \
  -H "Authorization: Bearer <token>"
```

无参数。返回当前节点全部指标的 Prometheus 文本格式，内容与 `/metrics` 抓取端点一致。给没有部署 Prometheus、只想临时看一眼的场景用；常规采集请配抓取端点，详见[指标采集与导出](metrics.md)。

---

## 注意事项

1. **权限控制**：只有 token 这一道，拿到就是管理员，详见上文[鉴权](#鉴权)
2. **服务地址**：执行命令前请确认服务地址的正确性
3. **参数验证**：某些命令的参数有特定格式要求，请参考具体命令的文档
4. **多服务执行**：不指定 `services` 时，GM 服务会逐个调用所有已注册该命令的服务；当前实现是顺序调用，并非并发
5. **超时设置**：`timeout` 参数的单位各命令不同——`stat` / `mem` / `gc` 是 skynet 的 1/100 秒，`shutdown` 是秒

---

## Web 管理界面

访问 `http://localhost:<gm_http_port>/` 可以打开 Web 管理界面（页面源文件 `public/gm.html`），提供可视化的命令管理功能：

- 命令列表浏览和搜索
- 参数表单填写
- 命令执行和结果查看
- 页面顶部的 token 输入框存在浏览器 localStorage 里，之后的请求自动带 `Authorization` 头

---

## 开发指南

### 注册新的 GM 命令

在服务中使用 `gm_api.register()` 注册命令：

```lua
local gm_api = require "skyext.gm_api"

local GM_CMD = {}

GM_CMD.my_command = {
    desc = "我的命令描述",
    params = {
        param1 = "参数1的描述",
        param2 = "参数2的描述",
    },
    handler = function(params)
        -- 处理逻辑
        local result = do_something(params.param1, params.param2)
        return true, result  -- 返回 (成功标志, 结果数据)
    end,
}

-- 注册命令
gm_api.register(GM_CMD)
```

`desc` 和 `handler` 必填，`params` 可选。注册时把 handler 以 `GM_<大写命令名>` 挂进本服务的命令表（经 `skyext.cmd_api`），所以服务必须用 `cmd_api.dispatch` 接管 lua 消息。

命令名在节点内是全局的：多个服务注册同一个名字会被归并成一条命令，执行时在所有注册过它的服务上各跑一次（`service_count` 就是这个数）；`desc`、`params` 不一致时以最后注册的为准并打 WARN 日志。

### 命令处理函数规范

- **参数**：接收一个 `params` 表，包含所有传入的参数（值都是 HTTP 传来的字符串，POST JSON 则保留原类型）
- **返回值**：返回两个值
  - 第一个值：布尔类型，表示执行是否成功
  - 第二个值：任意类型，成功时为结果数据，失败时为错误信息
