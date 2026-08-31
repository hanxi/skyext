# 热更新（Hotfix）文档

## 1. 概述

热更体系由四部分组成：

- **热更包** `hotfix/<日期>-patch<N>/`：`hotfix.conf.lua`（元信息 + 开关 + 文件清单）+ `codeN.lua`（手写 patcher）
- **编排服务** `service/hotfix.lua`：加载配置 → 校验 checksum → clearcache → reload_res → reload_sproto → reload_orm_schema → inject_code
- **支撑 GM 命令**：`clearcache`、`reload_res`、`reload_sproto_schema`、`reload_orm_schema`
- **CLI 工具** `tools/hotfix.lua`：`refresh` 子命令回写 checksum 和 time

---

## 2. Patcher 契约

每个 `codeN.lua` 文件必须返回一个 table，包含以下字段：

```lua
return {
    targets = { ".gm", ".hotfix", "roleagent*" },
    run = function()
        -- 在目标服务进程内执行
        -- 可安全使用 require、访问全局变量
        package.loaded["some_module"] = nil
        local new_mod = require "some_module"
        -- ...
    end,
}
```

### 字段说明

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `targets` | `string[]` | 是 | 目标服务名数组。支持精确名（`.gm`）和尾通配（`roleagent*`） |
| `run` | `function` | 是 | 注入函数，在每个目标服务进程内执行 |

### 顶层代码约束

Patcher 文件的**顶层代码**在沙箱中解析，仅允许：

- `local` 声明
- 表构造
- 基础函数：`type`、`tostring`、`tonumber`、`pairs`、`ipairs`、`select`、`unpack`、`table.*`、`string.*`、`math.*`

访问 `require`、`print` 或其他全局变量会报错。这是为了防止顶层副作用在热更服务进程（而非目标服务）中执行。

`run` 函数不受此限制——它在目标服务进程中通过注入模板执行，拥有完整的运行时环境。

### targets 通配规则

- 精确名：`".gm"` → 通过 `skynet.localname` 查找
- 尾通配：`"roleagent*"` → 查询 `.launcher` 获取本节点全部服务名，按前缀匹配
- 系统服务黑名单（`.launcher`、`.service_mgr`、`.gm`、`.hotfix`、`.logger`）不参与通配命中，但可通过精确名指定
- 通配仅覆盖本节点；多节点各自执行 hotfix 命令

### 执行顺序

同一热更包的多个 patcher 按 `code_files` 数组顺序执行。**该顺序即依赖顺序**，后执行的 patcher 可依赖前者的修改效果。

---

## 3. 配置文件格式（hotfix.conf.lua）

```lua
return {
    desc = "修复角色背包溢出",
    gitsha_base = "abc1234",
    gitsha_update = "def5678",
    time = "2026-08-31 10:00:00",  -- 由 tools/hotfix.sh refresh 自动回写
    checksum = "a1b2c3d4...",       -- 由 tools/hotfix.sh refresh 自动计算

    -- 可选字段
    fail_fast = true,   -- 默认 true；false 则步骤失败后继续执行后续步骤
    clearcache = true,
    reload_res = false,
    reload_sproto = false,
    reload_orm_schema = false,

    update_files = {
        "lualib/some_module.lua",
    },
    code_files = {
        "code1.lua",
        "code2.lua",
    },
}
```

---

## 4. update_files 生效原理

1. `update_files` 中列出的文件在部署时已替换到磁盘
2. `checksum` 校验确保磁盘文件与热更包一致
3. `clearcache`（`skynet.cache.clear()`）清除 Lua 代码缓存，下次 `require` 加载新代码
4. **注意**：已被服务 `require` 过的模块仍保留在 `package.loaded` 中。活跃服务需在 patcher 的 `run` 函数中显式重载：

```lua
run = function()
    package.loaded["some_module"] = nil
    local new_mod = require "some_module"
end
```

---

## 5. 操作 SOP

### 5.1 开发机准备热更包

```bash
mkdir hotfix/20260831-patch1
# 编辑 hotfix.conf.lua、update_files、codeN.lua
# ...

# 生成 checksum 和 time
./tools/hotfix.sh refresh hotfix/20260831-patch1
```

### 5.2 部署文件到目标节点

将 `hotfix/20260831-patch1/` 和 `update_files` 中列出的文件发布到各节点。

### 5.3 dry-run 预演

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "hotfix",
    "hotfix_dir": "hotfix/20260831-patch1",
    "mode": "dry_run"
  }'
```

检查返回的 `plan`：

- `steps`：将执行的步骤列表
- `patchers`：每个 patcher 命中的目标服务及地址
- `warnings`：未找到的服务等异常

### 5.4 逐节点执行

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "hotfix",
    "hotfix_dir": "hotfix/20260831-patch1",
    "confirm": "true"
  }'
```

### 5.5 逐节点核对 history

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix_history", "limit": "5"}'
```

确认每条记录 `success=true`，检查各步骤状态。

---

## 6. 失败处置手册

| 失败步骤 | 处置建议 |
|----------|---------|
| `load_config` | 检查 hotfix.conf.lua 必填字段(desc/checksum/gitsha_base/gitsha_update/time)，修正后重新执行 |
| `verify_checksum` | 先在开发机执行 `./tools/hotfix.sh refresh <dir>` 重新生成 checksum；确认磁盘文件与热更包未被改动 |
| `clear_cache` | GM 通道异常，检查 `.gm` 服务是否正常运行；本包尚未注入任何代码，可安全重试 |
| `reload_res` | res 未重载，配表与代码可能不一致；排查 sharetable 后重试或回退 update_files |
| `reload_sproto` | sproto schema 重载失败，检查 sproto 文件格式；可安全重试 |
| `reload_orm_schema` | ORM schema 重载失败，检查 schema 定义；可安全重试 |
| `inject_code` | **部分服务可能已打补丁**，禁止直接重跑整包；按 results 中逐服务确认状态后决定重注或回滚 |

### 关于回滚

热更系统**不提供自动回滚**。原因：

- patcher.run 可能产生无法自动逆转的副作用（修改内存数据、发消息等）
- 部分成功状态下重跑整包会导致已成功服务二次注入

推荐处置：

1. 根据 results 逐服务核对状态
2. 对失败服务修正 patcher 后单独重注
3. 极端情况下考虑滚动重启

---

## 7. 安全

### GM 鉴权

`/gm/execute` 接口需要携带鉴权 token：

- HTTP Header: `Authorization: Bearer <token>`
- 或请求参数: `token=<token>`

Token 在 `etc/app/common.app.lua` 中配置 `gm_auth_token`。**未配置 token 时接口禁用。**

`/gm/list` 接口同样需要鉴权。

### hotfix 二次确认

执行模式（非 dry_run）下必须传 `confirm=true`，防止误触。

---

## 8. 可观测性

### 热更历史

- 内存中保留最近 100 条记录
- 持久化到 `<root>/hotfix_history.jsonl`（JSON Lines 格式追加写）
- 每条记录包含：`time`、`node`（节点名）、`hotfix_dir`、`steps`、`success`
- 服务启动时从文件恢复历史

### 超时保护

- 注入操作默认 30 秒超时（环境变量 `hotfix_inject_timeout` 可配）
- 超时后返回失败，但目标服务内的协程无法取消（skynet 限制），完成后仅写日志

### 锁机制

- 同一时间只允许一次热更操作
- 锁定超过 300 秒自动释放（防止超时导致的死锁）

---

## 9. 变更日志

### v2 (2026-08-31)

- **Breaking**: 注入模板不再静默吞错，load/xpcall 失败改为 `error()` 传播
- **Breaking**: `fail_fast` 默认为 `true`（旧配置隐式为 false）。如需旧行为请显式设置 `fail_fast = false`
- **Breaking**: `/gm/execute` 新增鉴权，未配置 `gm_auth_token` 时接口禁用
- **Breaking**: `hotfix` 命令执行模式需传 `confirm=true`
- 新增 `dry_run` 预演模式
- 新增注入超时保护（默认 30s）
- 新增锁泄漏保护（超时自动释放）
- 新增 `fail_fast` 配置，步骤失败可中止后续操作
- 新增失败处置指引（`guidance` 字段）
- 新增历史持久化到 `hotfix_history.jsonl`
- 新增 targets 尾通配支持（`roleagent*`）
- 新增 patcher 顶层沙箱（禁止顶层访问全局变量）
- 新增 `build_version` 与 `gitsha_base` 不一致警告
- 统一 checksum 计算模块（`lualib/hotfix_checksum.lua`）
- 工具端配置回写增加替换次数校验和回写验证
