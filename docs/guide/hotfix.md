# 热更新（Hotfix）文档

## 1. 概述

热更体系由四部分组成：

- **热更包** `example/hotfix/<日期>-patch<N>/`：`hotfix.conf.lua`（元信息 + 开关 + 文件清单）+ `codeN.lua`（手写 patcher）；CLI 使用相对于 `example/` 的 `hotfix/...` 路径，GM 接口使用相对于仓库根目录的 `example/hotfix/...` 路径
- **编排服务** `service/hotfix.lua`：加载配置 → 校验 checksum → clearcache → reload_res → reload_sproto → reload_orm_schema → inject_code
- **支撑 GM 命令**：`clearcache`、`reload_res`、`reload_sproto_schema`、`reload_orm_schema`
- **CLI 工具** `./bin/skyext hotfix`（实现位于 `scripts/commands/hotfix.lua`）：`refresh` 子命令回写 checksum 和 time

---

## 1.1 热更类型

热更新分为 4 种情况，可单独或组合使用：

### 策划配置表热更

采用 `sharetable.query` 的方式热更策划配置表。需在 `hotfix.conf.lua` 中手动设置 `reload_res = true`。只有策划配表热更的热更包，`clearcache` 不需要为 `true`。

### sproto 协议热更

协议的热更一般会伴随着代码热更，流程是先替换协议文件，再重载协议，再热更代码。协议文件路径取决于 `sproto_schema_path` 配置项（示例值 `example/build/proto/sproto.spb`）。需在 `hotfix.conf.lua` 中手动设置 `reload_sproto = true`。只有 sproto 协议热更的热更包，`clearcache` 不需要为 `true`。

### ORM Schema 热更

ORM Schema 热更一般会伴随着代码热更，流程是先替换 schema 文件，再重载 schema，再热更代码。**ORM Schema 热更只允许新增字段，不允许删除和修改字段。** `reload_orm_schema` 为 `true` 时，`clearcache` 必须为 `true`，因为 ORM Schema 是游戏构建目录下的 Lua 文件 `example/build/lualib/game/orm/schema.lua`（模块名 `game.orm.schema`）。需在 `hotfix.conf.lua` 中手动设置 `reload_orm_schema = true`。注意活跃服务的 `package.loaded["game.orm.schema"]` 仍可能保留旧模块：`clearcache` 不等于清除 `package.loaded`；操作前应为目标服务设计安全的模块替换和已加载实体迁移，并用集成测试验证，不能只凭热更接口返回成功判断 schema 已生效。

### 代码热更

代码热更采用 inject 的方式执行，只进行小范围的代码替换。当热更包中的 `clearcache` 为 `true` 时，会 clear lua code cache。当有代码文件需要热更时，需在 `hotfix.conf.lua` 中手动设置 `clearcache = true`。

正式发布包含 `code_files` 时，还应准备对应修复问题后的 `update_files`。旧服务会执行 `code_files` 中的补丁；新服务启动后则应加载已替换的正常源码。只注入 patcher 而不部署更新文件，重启后修复将失效；当前 `update_files` 的路径限制见第 4 节。

---

## 2. Patcher 契约

每个 `codeN.lua` 文件必须返回一个 table，包含以下字段：

```lua
return {
    targets = { ".entity_agent:role:1" },  -- 以当前节点中实际注册的服务名为准
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
| `targets` | `string[]` | 是 | 目标服务名数组；当前应使用精确注册名（如 `.entity_agent:role:1`），不要依赖尾通配 |
| `run` | `function` | 是 | 注入函数，在每个目标服务进程内执行 |

### 顶层代码约束

Patcher 文件的**顶层代码**在沙箱中解析，仅允许：

- `local` 声明
- 表构造
- 基础函数：`type`、`tostring`、`tonumber`、`pairs`、`ipairs`、`select`、`unpack`、`table.*`、`string.*`、`math.*`

访问 `require`、`print` 或其他全局变量会报错。这是为了防止顶层副作用在热更服务进程（而非目标服务）中执行。

`run` 函数不受此限制——它在目标服务进程中通过注入模板执行，拥有完整的运行时环境。

### targets 解析与当前限制

- 精确名（如 `".entity_agent:role:1"`）通过 `skynet.localname` 查找，只能命中当前节点已注册的服务；多节点需分别执行 hotfix 命令。
- 代码预留了尾通配：查询 `.launcher` 的 `LIST` 结果，按名称前缀筛选，并排除系统服务黑名单。但 skynet 的 `LIST` 实际返回 `{[服务地址] = 启动命令}`，现有热更实现却把 key 当服务名、value 当服务地址，因此**尾通配在当前版本不可靠，不要用于实际热更**。历史 `roleagent*` 目标也不再适用，role 已迁移到 entity agent。
- 精确名可以指向 `.gm`、`.hotfix` 等系统服务，但对它们注入代码需额外评估风险。

### 执行顺序

同一热更包的多个 patcher 按 `code_files` 数组顺序执行。**该顺序即依赖顺序**，后执行的 patcher 可依赖前者的修改效果。

---

## 3. 配置文件格式（hotfix.conf.lua）

```lua
return {
    desc = "修复角色背包溢出",
    gitsha_base = "abc1234",
    gitsha_update = "def5678",
    time = "2026-08-31 10:00:00",  -- 由 hotfix refresh 命令自动回写
    checksum = "a1b2c3d4...",       -- 由 hotfix refresh 命令自动计算

    -- 可选字段
    fail_fast = true,   -- 默认 true；false 则步骤失败后继续执行后续步骤
    clearcache = true,
    reload_res = false,
    reload_sproto = false,
    reload_orm_schema = false,

    update_files = {},  -- 此示例只展示 code_files；普通文件更新的路径限制见下文
    code_files = {
        "code1.lua",
        "code2.lua",
    },
}
```

---

## 4. update_files 生效原理

1. `update_files` 中列出的文件在部署时已替换到磁盘
2. `checksum` 校验磁盘内容是否与计算时一致
3. `clearcache`（`skynet.cache.clear()`）清除 Lua 代码缓存，下次 `require` 加载新代码
4. **注意**：已被服务 `require` 过的模块仍保留在 `package.loaded` 中。活跃服务需在 patcher 的 `run` 函数中显式重载：

```lua
run = function()
    package.loaded["some_module"] = nil
    local new_mod = require "some_module"
end
```

> **当前目录布局的限制**：`hotfix refresh` 从 `example/` 读取 `update_files` 计算 checksum，而服务端从 skynet 的 `root = "./"`（仓库根目录）读取同名相对路径。两者不一致时，即使刷新成功，服务端校验也可能失败。本节下方的操作示例仅针对 `update_files = {}`、只注入 `code_files` 的热更；需要替换普通文件时，必须先统一这两个路径的解析并验证校验结果，不能直接套用该示例。

---

## 5. 操作 SOP

### 5.1 开发机准备热更包

以下步骤仅演示 `update_files = {}` 的 patcher 注入与预演；没有持久源码更新的热更在服务重启后不会保留修复，不能当作正式发布方案。

```bash
mkdir -p example/hotfix/20260831-patch1
# 在该目录编写 hotfix.conf.lua（update_files = {}）和 codeN.lua
# ...

# CLI 参数相对于 example/；在项目根目录执行
./bin/skyext hotfix refresh hotfix/20260831-patch1
```

### 5.2 部署文件到目标节点

将 `example/hotfix/20260831-patch1/` 发布到各节点对应路径。若正式方案还包含 `update_files`，需先解决上述路径不一致，再将更新文件一并发布。

### 5.3 dry-run 预演

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "hotfix",
    "hotfix_dir": "example/hotfix/20260831-patch1",
    "mode": "dry_run"
  }'
```

GM HTTP 响应外层是 `{code, cmd, results}`；先确认 `results[].success = true`，再查看该服务的 `results[].data`（预演计划）：

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
    "hotfix_dir": "example/hotfix/20260831-patch1",
    "confirm": "true"
  }'
```

执行后除检查外层 `code`，还须逐项检查 `results[].success`，成功时再核对 `results[].data.steps`；`code = 0` 只表示命令已被 GM 服务找到，不代表各节点的热更均成功。

### 5.5 逐节点核对 history

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"cmd": "hotfix_history", "limit": "5"}'
```

`results[].data` 是历史记录数组；确认每条记录的 `success = true`，并检查各记录的 `steps` 状态。

---

## 6. 失败处置手册

| 失败步骤 | 处置建议 |
|----------|---------|
| `load_config` | 检查 hotfix.conf.lua 必填字段(desc/checksum/gitsha_base/gitsha_update/time)，修正后重新执行 |
| `verify_checksum` | 先核对发布文件与预期版本，排查第 4 节所述路径不一致；确认内容正确后再执行 `./bin/skyext hotfix refresh <dir>`，不要仅通过刷新 checksum 掩盖文件差异 |
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

Token 在 `example/etc/nodes/common.app.lua` 中配置 `gm_auth_token`。**未配置或仍使用占位符 `CHANGE_ME_TO_RANDOM_TOKEN` 时，GM 接口禁用。**

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
- 当时新增 targets 尾通配接口（`roleagent*`）；当前 role 已迁移，且现有 `.launcher LIST` 结果与匹配逻辑不一致，实际操作不要使用该尾通配
- 新增 patcher 顶层沙箱（禁止顶层访问全局变量）
- 新增 `build_version` 与 `gitsha_base` 不一致警告
- 统一 checksum 计算模块（`lualib/skyext/hotfix_checksum.lua`）
- 工具端配置回写增加替换次数校验和回写验证
