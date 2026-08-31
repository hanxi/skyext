# GM 命令接口协议文档

## 概述

GM（Game Master）命令系统提供了一套 HTTP RESTful API，用于执行游戏管理命令。所有接口返回 JSON 格式数据。

**基础 URL**: `http://localhost:9092`

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
2. **服务名称**：`.gm` 或 `gm`（本地命名服务）
3. **整数地址**：直接的服务地址整数值

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

## 鉴权

`/gm/execute`（GET/POST）需要鉴权 token，传递方式二选一：

- HTTP Header: `Authorization: Bearer <token>`
- 请求参数（query 或 body）: `token=<token>`

Token 在 `etc/app/common.app.lua` 中通过 `gm_auth_token` 配置。**未配置 token 时 `/gm/execute` 接口一律拒绝。**

`/gm/list` 同样需要鉴权。

---

## 热更命令

### hotfix — 执行热更新

```bash
# dry-run 预演
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix", "hotfix_dir": "hotfix/20260831-patch1", "mode": "dry_run"}'

# 正式执行（需 confirm=true）
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix", "hotfix_dir": "hotfix/20260831-patch1", "confirm": "true"}'
```

**参数**

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| hotfix_dir | string | 是 | 热更包目录路径（相对于工程根目录） |
| mode | string | 否 | `run`（默认）或 `dry_run`（仅预演） |
| confirm | string | 否 | 执行模式下必须传 `"true"` |

**响应（执行模式）**

成功时返回 steps 数组；失败时返回 guidance 处置建议。详见 [docs/hotfix.md](hotfix.md)。

**响应（dry_run 模式）**

返回执行计划：steps 列表、patchers 目标服务命中情况、warnings。

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

1. **权限控制**：`/gm/execute` 已实现 token 鉴权，详见上文「鉴权」一节
2. **服务地址**：执行命令前请确认服务地址的正确性
3. **参数验证**：某些命令的参数有特定格式要求，请参考具体命令的文档
4. **并发执行**：当不指定 `services` 参数时，命令会在所有注册该命令的服务上并发执行
5. **超时设置**：某些命令支持 `timeout` 参数来设置超时时间（单位：秒）

---

## Web 管理界面

访问 `http://localhost:9092/` 可以打开 Web 管理界面，提供可视化的命令管理功能：

- 命令列表浏览和搜索
- 参数表单填写
- 命令执行和结果查看
- 响应式设计，支持移动端访问

---

## 开发指南

### 注册新的 GM 命令

在服务中使用 `gm_api.register()` 注册命令：

```lua
local gm_api = require "gm_api"

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

### 命令处理函数规范

- **参数**：接收一个 `params` 表，包含所有传入的参数
- **返回值**：返回两个值
  - 第一个值：布尔类型，表示执行是否成功
  - 第二个值：任意类型，成功时为结果数据，失败时为错误信息
