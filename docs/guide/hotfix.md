# 热更新（Hotfix）文档

## 1. 概述

热更体系由四部分组成：

- **热更包** `example/hotfix/<日期>-patch<N>/`：`hotfix.conf.lua`（元信息 + 开关 + 文件清单）+ `codeN.lua`（手写 patcher）。热更包目录和 `update_files` 里的路径**都相对于工程根目录**（skynet 的 `root`，示例配置里是仓库根目录），CLI 与 GM 接口取值完全一致，例如 `example/hotfix/20260120-patch1`
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

ORM Schema 热更一般会伴随着代码热更，流程是先替换 schema 文件，再重载 schema，再热更代码。**只适用于加字段、删字段**；改名和改类型是不兼容改动，见 [改 ORM schema](orm_schema_change.md)。`reload_orm_schema` 为 `true` 时，`clearcache` 必须为 `true`，因为 ORM Schema 是游戏构建目录下的 Lua 文件 `example/build/lualib/game/orm/schema.lua`（模块名 `game.orm.schema`，由 dbmgr 持有）。需在 `hotfix.conf.lua` 中手动设置 `reload_orm_schema = true`。

`reload_orm_schema` 是**就地重载**：dbmgr 持有的那张 schema 表、以及表里每个 schema 对象的引用都保持不变，只把字段定义换成新的，新增的类型补进来、删除的类型移除。必须保持引用不变——生成代码里 `role.new(init)` 这类闭包、以及已加载 doc 的类型判定都直接持有这些对象，换一张新表等于让老 doc 全部失效。重载结束后 `package.loaded["game.orm.schema"]` 会被还原成同一张表，所以之后 `require` 拿到的就是已生效的那份；若重新 `require` 得到的还是同一张表（例如 `clearcache` 没生效），重载会被直接拒绝而不是静默清空 schema。

仍然要注意作用域：GM 命令只在注册它的服务（dbmgr）的 Lua VM 里生效，`clearcache` 不等于清除其它服务自己的 `package.loaded`。其它服务里已经 require 过 schema 的模块仍持有旧副本，操作前应为目标服务设计安全的模块替换和已加载实体迁移，并用集成测试验证，不能只凭热更接口返回成功判断 schema 已生效。

### 代码热更

代码热更采用 inject 的方式执行，只进行小范围的代码替换。当热更包中的 `clearcache` 为 `true` 时，会 clear lua code cache。当有代码文件需要热更时，需在 `hotfix.conf.lua` 中手动设置 `clearcache = true`。

正式发布包含 `code_files` 时，还应准备对应修复问题后的 `update_files`。旧服务会执行 `code_files` 中的补丁；新服务启动后则应加载已替换的正常源码。只注入 patcher 而不部署更新文件，重启后修复将失效。

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
| `targets` | `string[]` | 是 | 目标服务名数组：精确注册名（如 `.entity_agent:role:1`），或某类实体的全部 agent（`.entity_agent:role:*`） |
| `run` | `function` | 是 | 注入函数，在每个目标服务进程内执行 |

### 顶层代码约束

Patcher 文件的**顶层代码**在沙箱中解析，仅允许：

- `local` 声明
- 表构造
- 基础函数：`type`、`tostring`、`tonumber`、`pairs`、`ipairs`、`select`、`unpack`、`table.*`、`string.*`、`math.*`

访问 `require`、`print` 或其他全局变量会报错。这是为了防止顶层副作用在热更服务进程（而非目标服务）中执行。

`run` 函数不受此限制——它在目标服务进程中通过注入模板执行，拥有完整的运行时环境。

### targets 解析

- 精确名（如 `".entity_agent:role:1"`）通过 `skynet.localname` 查找，只能命中当前节点已注册的服务；多节点需分别执行 hotfix 命令。
- 实体 agent 的注册名形如 `.entity_agent:<类型>:<序号>`（`skyext.entity.types.format_agent_service_name`）。写成 `.entity_agent:<类型>:*` 时，按该类型在 `entity_types` 里配置的 `agent_count`（缺省 1）展开成 `:1` … `:N`：
  - 有任何一个 agent 在本节点查不到，整条目标失败，**一个都不注入**——同类型实体跑两套代码比不打补丁更糟；
  - 一个都查不到（本节点不承载该类型）记为 `Service not found`；
  - 类型未配置报 `Unknown entity type`。
- 通配只支持上面这一种形式，其他写法（`.agent*`、`.entity_agent:*` 等）直接拒绝：skynet 只能按名字查地址，没有枚举注册名的接口，做不了任意前缀匹配。
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

    update_files = {    -- 修好的源码，相对于工程根目录；引擎文件和游戏文件写在同一套路径下
        "example/nodes/role/modules/bag/init.lua",
    },
    code_files = {      -- 给正在运行的服务打的补丁，只能是热更包目录下的文件
        "code1.lua",
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

### 路径基准

`update_files` 的每一项、以及热更包目录本身，都相对于**工程根目录**——即 skynet 配置里的 `root`（示例配置中 `root = "./"`，就是仓库根目录）。`code_files` 不带路径，只能是热更包目录下的文件。

选这个基准的原因：skynet 自己的 `luaservice`、`lua_path` 就以 `root` 解析，热更要替换的文件最终由 skynet 按这组路径加载，checksum 若按另一个基准计算必然对不上；而且 `update_files` 需要同时覆盖引擎文件（`service/gm.lua`、`lualib/skyext/...`）和游戏文件（`example/lualib/...`），只有工程根目录能同时容纳两者。

因此 `./bin/skyext hotfix refresh <dir>` 和 GM `hotfix` 接口的 `hotfix_dir` 取**同一个字符串**：

```bash
./bin/skyext hotfix refresh example/hotfix/20260120-patch1
# GM: {"cmd":"hotfix","hotfix_dir":"example/hotfix/20260120-patch1"}
```

---

## 5. 操作 SOP

### 示例热更包

`example/hotfix/20260120-patch1` 是可以直接跑的示例，只用专门为它准备的文件，产品代码改动不会影响它的 checksum：

- `update_files` 是示例配表 `example/res/lazy/hotfix_demo.lua`（懒加载目录，只有被访问时才加载），配合 `reload_res = true`；
- `code1.lua` 的 `targets` 是 `.entity_agent:role:*`，在每个 role 实体 agent 里读 `res.hotfix_demo.version` 并返回。

起一个 role 节点（GM 需配 `gm_auth_token`）后按 5.3、5.4 执行，`inject_code` 的每条结果是当前 `version`。把配表里的 `version` 改掉、`hotfix refresh` 后再执行一次，结果随之变化。

### 5.1 开发机准备热更包

```bash
mkdir -p example/hotfix/20260120-patch1
# 在该目录编写 hotfix.conf.lua 和 codeN.lua
# ...

# 路径相对于工程根目录；在项目根目录执行
./bin/skyext hotfix refresh example/hotfix/20260120-patch1
```

只注入 `code_files`、不带 `update_files` 的热更包可以用于预演和临时止血，但服务重启后修复不保留，不能当作正式发布方案。

### 5.2 部署文件到目标节点

将 `example/hotfix/20260120-patch1/` 以及 `update_files` 列出的更新文件一并发布到各节点对应路径。更新文件在节点上的位置须与 `update_files` 写法一致——都相对于该节点的工程根目录。

### 5.3 dry-run 预演

```bash
curl -X POST http://localhost:9092/gm/execute \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "cmd": "hotfix",
    "hotfix_dir": "example/hotfix/20260120-patch1",
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
    "hotfix_dir": "example/hotfix/20260120-patch1",
    "confirm": "true"
  }'
```

执行后除检查外层 `code`，还须逐项检查 `results[].success`，成功时再核对 `results[].data.steps`；`code = 0` 只表示命令已被 GM 服务找到，不代表各节点的热更均成功。

`inject_code` 步骤的 `result` 是每个目标服务一条：成功时 `result` 是补丁在目标服务里 `print` 的内容，`run` 有非 nil 返回值时也会被打印进来；补丁抛错时该条 `success = false`，`error` 里是 `Patcher failed:` 加报错与 traceback。

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

执行失败时，响应的 `guidance` 字段给出第一个失败步骤对应的处置建议，内容即下表。

| 失败步骤 | 处置建议 |
|----------|---------|
| `load_config` | 检查 hotfix.conf.lua 必填字段(desc/checksum/gitsha_base/gitsha_update/time)，修正后重新执行 |
| `verify_checksum` | 先在开发机执行 `./bin/skyext hotfix refresh <dir>` 重新生成 checksum；确认磁盘文件与热更包未被改动 |
| `clear_cache` | GM 通道异常，检查 `.gm` 服务是否正常运行；本包尚未注入任何代码，可安全重试 |
| `reload_res` | res 未重载，配表与代码可能不一致；排查 sharetable 后重试或回退 update_files |
| `reload_sproto` | sproto schema 重载失败，检查 sproto 文件格式；可安全重试 |
| `reload_orm_schema` | ORM schema 重载失败，检查 schema 定义；可安全重试 |
| `inject_code` | 部分服务可能已打补丁，禁止直接重跑整包；按 results 中逐服务确认状态后决定重注或回滚 |
| `internal_error` | 热更执行过程中出现未预期的内部错误，请检查日志排查原因 |

checksum 不过时，先核对发布文件与预期版本，确认 `update_files` 在目标节点的落位与第 4 节的路径基准一致，内容正确后再 refresh——不要用刷新 checksum 掩盖文件差异。

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

`/gm/execute` 接口需要携带 token：

- HTTP Header: `Authorization: Bearer <token>`
- 或请求参数: `token=<token>`

token 在 `example/etc/nodes/common.app.lua` 的 `gm_auth_token` 里配置。**未配置、仍是占位符、或少于 16 字符时 GM 接口整体禁用**；`allow_insecure_secret` 对 GM 无效。详见 [GM HTTP API](gm_api.md#鉴权)。

`/gm/list` 接口同样需要 token。每次热更都会打一条 `GM command executed` 的日志。

### hotfix 二次确认

执行模式（非 dry_run）下必须传 `confirm=true`，防止误触。

---

## 8. 可观测性

### 热更历史

- 内存中保留最近 100 条记录，`hotfix_history` 按时间倒序返回
- 持久化到 `<root>/hotfix_history.jsonl`（JSON Lines 格式追加写）
- 每条记录包含：`time`、`node`（节点名）、`hotfix_dir`、`steps`、`success`
- 服务启动时读文件末尾 32KB 恢复历史，解析不出来的行跳过

### 版本基线检查

节点启动参数 `build_version` 与热更包 `gitsha_base` 不一致时，不阻止执行，但会打 WARN 日志，并在响应的 `version_warning` 字段给出提示，需人工确认补丁是否适用于当前部署版本。

### 超时保护

- 注入操作默认 30 秒超时（节点配置 `hotfix_inject_timeout` 可改，单位秒）
- 超时后返回失败，但目标服务内的协程无法取消（skynet 限制），完成后仅写日志

### 锁机制

- 同一时间只允许一次热更操作
- 锁定超过 300 秒自动释放（防止超时导致的死锁）
