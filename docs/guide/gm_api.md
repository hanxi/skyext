# GM 命令接口协议文档

## 概述

GM（Game Master）命令系统提供了一套 HTTP RESTful API，用于执行游戏管理命令。所有接口返回 JSON 格式数据。

**基础 URL**: `http://localhost:<gm_http_port>`（代码默认 `9090`，由各节点 `gm_http_port` 配置覆盖；以下示例使用 RoleNode1 的端口 `9092`）

GM HTTP 服务是独立的命名实例，与节点的业务 HTTP 端口（如 Account 的 `account_http_port`）互不共用路由：业务端口不会暴露 `/gm/*`，GM 端口也不会暴露业务接口。监听地址默认只绑定 `127.0.0.1`，需要对外暴露时显式配置 `gm_http_host`（务必同时配好 `gm_accounts` 并限制来源）。

所有接口都要鉴权，每条指令按危险等级授权，每次执行都进审计，详见[鉴权与权限](#鉴权与权限)。

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
  "account": "ops",
  "role": "operator",
  "commands": [
    {
      "cmd": "命令名称",
      "desc": "命令描述",
      "params": {
        "参数名1": "参数描述1",
        "参数名2": "参数描述2"
      },
      "level": "write",
      "service_count": 2
    }
  ]
}
```

只返回**当前账号有权执行**的命令：看不到的命令就是跑不了的命令。

**字段说明**

| 字段 | 类型 | 说明 |
|------|------|------|
| code | number | 状态码，0 表示成功，非 0 表示失败 |
| account | string | 当前 token 对应的账号名 |
| role | string | 该账号的角色 |
| commands | array | 命令列表 |
| commands[].cmd | string | 命令名称 |
| commands[].desc | string | 命令描述 |
| commands[].params | object | 命令参数定义，key 为参数名，value 为参数描述 |
| commands[].level | string | 命令危险等级：`read` / `write` / `admin` |
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
| services | string | 否 | 指定执行的服务地址列表，逗号分隔，如 `:01000002,:01000003`。不指定则在所有注册该命令的服务上执行 |
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
| services | array | 否 | 指定执行的服务地址列表。不指定则在所有注册该命令的服务上执行 |
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
2. **服务名称**：接口代码会尝试用 `skynet.localname` 查找本地命名服务；当前以 `.` 开头的名称会先被去掉前缀，可能无法匹配实际注册的 `.gm` 等名称。指定服务时优先使用已核实的十六进制地址
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

## 常见命令示例

### 系统管理命令

```bash
# 列出所有服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=list"

# 查看服务统计信息
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=stat"

# 查看内存状态
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=mem"

# 强制垃圾回收
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=gc"

# 重载资源
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=reload_res"
```

### 服务控制命令

```bash
# 杀死指定服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=kill&address=:01000002"

# 退出服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=exit&address=:01000002"

# 启动新服务
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=start&service=test&args=arg1"
```

---

## 鉴权与权限

### 传 token

`/gm/execute`（GET/POST）和 `/gm/list` 都需要账号 token，传递方式二选一：

- HTTP Header: `Authorization: Bearer <token>`
- 请求参数（query 或 body）: `token=<token>`

### 配账号

账号配在 `example/etc/nodes/common.app.lua`，一人一个 token：

```lua
gm_accounts = {
    { name = "viewer", role = "readonly", token = "..." },
    { name = "ops", role = "operator", token = "..." },
    { name = "root", role = "admin", token = "..." },
}
```

token 用 `openssl rand -hex 32` 现生成，由 `skyext.secret` 校验强度。**未配置、命中占位符黑名单（如 `CHANGE_ME_TO_RANDOM_TOKEN`）、少于 16 字符、或与别的账号共用**的 token，对应账号会被丢弃并打一条 ERROR 日志；一个可用账号都没有时 `/gm/*` 全部拒绝。`allow_insecure_secret` 只放宽登录密钥，对 GM 鉴权无效。

### 指令等级与角色

每条 GM 指令注册时声明一个危险等级，**没声明的按 `admin` 算**（漏标的新指令应该是最难执行到的那一类）：

| 等级 | 含义 | 例子 |
|------|------|------|
| `read` | 只读查询，看不出手脚 | `list`、`stat`、`mem`、`netstat`、`dlq_list`、`hotfix_history` |
| `write` | 改运行时状态，但不碰代码和进程 | `gc`、`clearcache`、`reload_res`、`reload_orm_schema`、`dlq_replay` |
| `admin` | 能拿到进程控制权或机密 | `kill`、`exit`、`inject`、`setenv`、`getenv`、`hotfix`、`audit` |

内置角色：

| 角色 | 能执行到 |
|------|----------|
| `readonly` | `read` |
| `operator` | `read` + `write` |
| `admin` | 全部 |

需要"只读 + 几条指定指令"时自定义角色，`extra` 只能加不能减：

```lua
gm_roles = {
    release = { level = "read", extra = { "hotfix", "hotfix_history" } },
}
```

自定义角色与内置角色同名时覆盖内置的；`level` 写错或缺失的角色会被整个丢弃（挂在它下面的账号跟着失效），不会退化成放行。

同一条指令在多个服务上注册且等级不一致时，取**更严**的那个——执行是广播到所有服务的，按最松的放行等于绕过了严的那一侧。

### 审计

每次指令执行都写一条审计记录，包括越权被拒和鉴权失败的尝试（`/gm/list` 只在鉴权失败时记，成功的列表查询不记）。记录追加到 skynet `root` 下的 `gm_audit.jsonl`（可用 `gm_audit_path` 改路径），同时打一条 `GM audit` 的 INFO 日志：

```json
{"time":"2026-10-14 12:00:00","account":"ops","role":"operator","peer":"10.0.0.9:51324","cmd":"gc","result":"ok"}
```

| 字段 | 说明 |
|------|------|
| account / role | 账号与角色；鉴权失败记 `-`，进程内部调用记 `system` |
| peer | 调用方地址；内部调用记 `internal` |
| params | 指令参数；`token`、`password`、`secret` 替换为 `[redacted]`，超长值截断 |
| result | `ok` / `partial`（部分服务失败）/ `failed` / `denied`（越权）/ `auth_failed` / `unknown_command` |
| detail | 失败原因或拒绝原因 |

记录写在指令执行**之后**，一条记录就能看出操作有没有落地；执行途中进程挂掉则不会留下记录，这种情况查进程日志。审计文件写失败不会让 GM 指令跟着失败（磁盘满了还得能 kill 服务），但会打 ERROR 日志。

最近 100 条记录留在内存里，用 `audit` 指令查（`admin` 级）：

```bash
curl -H "Authorization: Bearer <token>" "http://localhost:9092/gm/execute?cmd=audit&limit=20"
```

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
| hotfix_dir | string | 是 | 相对于 skynet `root`（示例为仓库根目录）的热更包路径，如 `example/hotfix/20260831-patch1`；CLI 的 `hotfix refresh` 参数则相对于 `example/` |
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

## 注意事项

1. **权限控制**：账号 token 鉴权 + 按指令等级授权 + 操作审计，详见上文[鉴权与权限](#鉴权与权限)
2. **服务地址**：执行命令前请确认服务地址的正确性
3. **参数验证**：某些命令的参数有特定格式要求，请参考具体命令的文档
4. **多服务执行**：不指定 `services` 时，GM 服务会逐个调用所有已注册该命令的服务；当前实现是顺序调用，并非并发
5. **超时设置**：某些命令支持 `timeout` 参数来设置超时时间（单位：秒）

---

## Web 管理界面

访问 `http://localhost:<gm_http_port>/` 可以打开 Web 管理界面（页面源文件 `public/gm.html`），提供可视化的命令管理功能：

- 命令列表浏览和搜索
- 参数表单填写
- 命令执行和结果查看
- 响应式设计，支持移动端访问

---

## 开发指南

### 注册新的 GM 命令

在服务中使用 `gm_api.register()` 注册命令：

```lua
local gm_api = require "skyext.gm_api"

local GM_CMD = {}

GM_CMD.my_command = {
    desc = "我的命令描述",
    level = "write", -- read / write / admin，不写按 admin 算
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

### 命令处理函数规范

- **参数**：接收一个 `params` 表，包含所有传入的参数
- **返回值**：返回两个值
  - 第一个值：布尔类型，表示执行是否成功
  - 第二个值：任意类型，成功时为结果数据，失败时为错误信息
- **等级**：`level` 决定谁能执行，按"这条指令被滥用能造成多大后果"来定；能改进程状态的至少 `write`，能执行代码、控制进程或读出机密的必须 `admin`。写了不认识的等级会在注册时直接报错，不写则按 `admin` 处理
