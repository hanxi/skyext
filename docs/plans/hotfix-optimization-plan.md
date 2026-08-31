# SkyExt 热更模块优化行动计划

> 创建日期：2026-08-31
> 状态：待执行
> 前置调研：已完成对热更链路全量代码走读（service/hotfix.lua、tools/hotfix.lua、gm 通道、res/sproto 重载、launcher 启动链路），问题清单见本文第 2 节。
> 路线决策：**patcher 保持手写**，不做自动生成；本计划聚焦让手写热更流程更安全、更可观测、更可运维。

## 1. 背景与目标

### 1.1 现状

热更体系由四部分组成：

- **热更包** `hotfix/<日期>-patch<N>/`：`hotfix.conf.lua`（元信息 + 开关 + 文件清单）+ `codeN.lua`（手写 patcher，契约：返回 `{ targets = {".gm",...}, run = function() end }`）
- **编排服务** `service/hotfix.lua`：每节点由 `lualib/launcher.lua` 启动，注册 GM 命令 `hotfix` / `hotfix_history`，执行流程为 load_config → verify_checksum → clearcache → reload_res → reload_sproto → reload_orm_schema → inject_code
- **支撑 GM 命令**：`clearcache`（gm_sys）、`reload_res`（res/sharetable）、`reload_sproto_schema`（sproto_loader）、`reload_orm_schema`
- **CLI 工具** `tools/hotfix.lua`：`refresh` 子命令回写 checksum

### 1.2 目标

1. 消除"热更假成功"类正确性缺陷（P0）
2. 注入过程可控（超时、锁、fail-fast、dry-run），失败有明确处置指引（P1）
3. 高危入口有鉴权，动态多实例服务可被覆盖（P2）
4. 工具链与文档补齐，契约成文（P3）

### 1.3 范围内文件

| 文件 | 改动性质 |
|---|---|
| `service/hotfix.lua` | 核心改造（模板、超时、锁、fail-fast、历史、dry-run、targets） |
| `lualib/gm_router.lua` | 鉴权 |
| `lualib/gm_api.lua` | 不动（仅确认） |
| `tools/hotfix.lua` | checksum 模块化、配置回写健壮化 |
| `lualib/hotfix_checksum.lua` | 新增（两端共用） |
| `public/gm.html` | token 输入支持 |
| `etc/common.app.lua` | 新增 `gm_auth_token` 配置项 |
| `docs/hotfix.md` | 新增（契约 + SOP + 处置手册） |
| `docs/gm_api.md` | 增补 hotfix 命令条目 |
| `test/test_hotfix/` | 新增测试 |

## 2. 问题总览

| 编号 | 级别 | 问题 | 位置 |
|---|---|---|---|
| #1 | P0 | **双重静默吞错**：① 注入模板中 load/xpcall 失败仅 log+return nil，skynet.call 以 ok=true,result=nil 返回，inject_to_service 判为成功；② inject_code_files 始终 return true，record_step 的 inject_ok 永远为 true，即使 results 数组中有个别失败项也不影响 step 级判定——history 最终记 success=true | service/hotfix.lua 注入模板 + inject_code_files |
| #2 | P0 | `/gm/execute` 无鉴权，可远程注入任意 Lua 代码（gm_api.md 注意事项已承认缺失） | lualib/gm_router.lua |
| #3 | P1 | checksum 校验不对称：service 端 update_files 读失败仅 warn 跳过，tools 端对同场景 fail-fast，两端行为不一致 | service/hotfix.lua verify_checksum |
| #4 | P1 | 步骤失败不中断，无 fail-fast，多 target 注入可状态分裂 | service/hotfix.lua execute_hotfix |
| #5 | P1 | 注入无超时，patcher 卡死 → skynet.call 永久阻塞 → cleanup() 永远不会执行 → g_hotfix_lock 永久占用 | service/hotfix.lua inject_to_service |
| #6 | P1 | 失败无处置指引，无回滚说明 | service/hotfix.lua execute_hotfix |
| #7 | P1 | 热更历史仅存内存（g_hotfix_history = {}），重启丢失，无审计 | service/hotfix.lua |
| #8 | P2 | targets 只支持静态 localname（skynet.localname 精确查找），覆盖不了动态多实例 | service/hotfix.lua find_service_address |
| #9 | P2 | 跨节点无编排，clearcache 生效范围（package.loaded）未文档化 | 全局 |
| #10 | P2 | patcher 顶层代码在 hotfix 进程内先执行一次（parse_patcher_targets 中 pcall(func)），然后注入模板在目标服务中再执行一次，顶层副作用会跑错进程 | service/hotfix.lua parse_patcher_targets |
| #11 | P2 | 无 dry-run 预演 | service/hotfix.lua |
| #12 | P3 | MD5 双实现（service 端 require "md5"，tools 端 os.tmpname + io.popen("md5sum")），tools 端有 tmpname 安全隐患 | tools/hotfix.lua calculate_md5 |
| #13 | P3 | 配置回写用 gsub 全局替换，无替换次数校验，且替换后未 reload 验证 | tools/hotfix.lua update_config_file |
| #14 | P3 | gitsha_base 只记录不校验运行版本 | service/hotfix.lua |
| #15 | P3 | patcher 契约、SOP、失败处置均无文档 | docs/ |
| #16 | P3 | code_files 执行顺序依赖 ipairs 数组顺序，属隐式约定（文档问题，非代码缺陷） | hotfix.conf.lua |

## 3. 阶段计划

### Phase 1：正确性修复（P0）— 预计 1 天

#### 1.1 修复注入模板静默失败（#1）

改动 `service/hotfix.lua` 的 `g_hotfix_code_template`：

- `load` 失败：`error("hotfix load error: " .. tostring(err))`（替换现在的 log + return）
- `xpcall(f, debug.traceback)` 失败：`error("hotfix chunk error: " .. tostring(r))`
- `pcall(patcher.run)` 失败：维持现有 `error(...)` 不变
- 补充：模板内在目标服务中再校验一次 `type(patcher) == "table"` 且 `type(patcher.run) == "function"`、`type(patcher.targets) == "table"`，不符则 error，防止解析期与注入期内容不一致

效果：任何失败经 `debug` 协议传播 → `inject_to_service` 的 `pcall(skynet.call, ...)` 捕获 → 该 target 记失败。

同时修复 `inject_code_files` 的返回值：当 `results` 中存在任一 `success=false` 的条目时，第一个返回值改为 `false`，使 `record_step("inject_code", inject_ok, ...)` 能正确反映注入失败，进而传导到 history.success。

**验收**：构造含语法错误的 patcher 注入，`hotfix` 命令返回失败、`inject_code` 步骤 `success=false`、history 同步为 false。

#### 1.2 注入超时保护（#5）

改动 `service/hotfix.lua`：

- 新增 `call_with_timeout(addr, protocol, cmd, ..., timeout_sec)`：
  - `skynet.fork` 内 `pcall(skynet.call, ...)`，完成后 `skynet.wakeup` 主协程
  - 主协程 `skynet.sleep(100)` 循环等待，超过 `timeout_sec`（默认 30，可由 `hotfix_inject_timeout` 环境变量配置）即返回 `(false, "inject timeout")`
  - 注意：fork 内的 call 无法真正取消，超时后它完成时仅写一条 log（`late inject result`），不参与本次结果
- `inject_to_service` 改用 `call_with_timeout`

#### 1.3 锁泄漏保护（#5 关联）

改动 `service/hotfix.lua`：

- `g_hotfix_lock` 由 boolean 改为时间戳（`os.time()`）
- `execute_hotfix` 入口：锁存在且 `os.time() - g_hotfix_lock < LOCK_MAX_HOLD`（默认 300s）→ 拒绝；超时 → `log.warn("force release stale hotfix lock")` 后抢占
- 执行开始置锁、结束（cleanup）清空，逻辑不变

**验收**：patcher.run 内 `skynet.sleep(6000)`（60s）→ 注入 30s 超时返回失败；随后再次执行 hotfix，300s 内被锁拒绝、模拟超时后可重新执行。

### Phase 2：健壮性与可观测（P1）— 预计 1.5 天

#### 2.1 checksum 校验统一 fail-fast（#3）

改动 `service/hotfix.lua` `verify_checksum`：

- `update_files` 读文件失败 → 直接 `return false, "Update file not readable: <path>: <err>"`（删除现在的 warn-跳过逻辑）
- 报错文案区分两类：`file missing/unreadable`（文件层）与 `checksum mismatch: expected X got Y`（内容层）

#### 2.2 fail_fast 支持（#4）

- `hotfix.conf.lua` 新增可选字段 `fail_fast`，**默认 true**（缺省即安全）；显式 `false` 才沿用"失败继续"
- `execute_hotfix` 各步骤（clearcache/reload_res/reload_sproto/reload_orm_schema）失败时：`fail_fast=true` 则立即 return（跳过后续步骤与 inject）
- `inject_code_files` 内部：`fail_fast=true` 时任一 target 注入失败 → 停止后续所有 patcher/target 注入，返回失败（多文件 patcher 部分成功即状态分裂，宁可中止）
- 步骤函数返回值统一为 `(ok, info)`

#### 2.3 失败处置指引（#6）

- 新增 `STEP_GUIDANCE` 映射表（步骤名 → 处置建议），例如：
  - `load_config` 失败 → "检查 hotfix.conf.lua 必填字段，修正后重新执行"
  - `verify_checksum` 失败 → "先在开发机执行 ./tools/hotfix.sh refresh <dir> 重新生成 checksum；确认磁盘文件与热更包未被改动"
  - `clear_cache` 失败 → "GM 通道异常，检查 .gm 服务；本包尚未注入任何代码，可安全重试"
  - `reload_res` 失败 → "res 未重载，配表与代码可能不一致；排查 sharetable 后重试或回退 update_files"
  - `inject_code` 失败 → "部分服务可能已打补丁，禁止直接重跑整包；按 results 中逐服务确认状态后决定重注或回滚"
- `execute_hotfix` 返回值中增加 `guidance` 字段（取第一个失败步骤的指引）

#### 2.4 热更历史持久化（#7）

- 路径：`skynet.getenv("root") .. "/hotfix_history.jsonl"`，JSON Lines 追加写（cjson.encode）
- 写入时机：每次 `execute_hotfix` 结束（含失败），追加一条 history_entry（增加字段 `node`：取 `skynet.getenv("nodename")` 或 cluster 配置的节点名，用于区分节点）
- 启动恢复：`skynet.start` 时读文件尾部最多 `MAX_HISTORY`(100) 条填充 `g_hotfix_history`（读文件过大时只保留最后 ~32KB 再按行截取）
- 写入失败仅 log.warn，不影响热更主流程

#### 2.5 dry-run 预演（#11）

- `GM_CMD.hotfix` 参数新增 `mode`（可选，`"run"` 默认 / `"dry_run"`）
- dry-run 执行：load_config → verify_checksum → 逐个沙箱解析 patcher（见 3.3）并解析 targets 得到服务地址 → **不执行** clearcache/reload/inject
- 返回：将执行的动作清单（每个 patcher → targets → 命中的服务地址列表）、步骤预估、异常项（服务未找到等）

**验收**：Phase 2 整体验收用例见第 4 节 T3~T7。

### Phase 3：安全与覆盖能力（P2）— 预计 2 天

#### 3.1 GM 通道鉴权（#2）

- `etc/common.app.lua` 新增 `gm_auth_token = "<随机长串>"`（部署时生成）
- `lualib/gm_router.lua`：新增 `check_auth(req)`，校验 `Authorization: Bearer <token>` 或 query/body 参数 `token`
  - `/gm/execute`（GET/POST）：**未配置 token 时一律拒绝**（安全默认），错误码用 `errcode.PARAM_ERROR` 语义或新增 `errcode.AUTH_FAILED`
  - `/gm/list`：只读，允许无 token 访问（保持面板可用）；后续如需收紧再改
  - token 校验失败统一 `log.warn` 记录来源 IP
- `public/gm.html`：右上角新增 token 输入框（localStorage 持久化），fetch 请求自动附带
- `docs/gm_api.md`：补充鉴权说明
- 热更命令二次确认：`GM_CMD.hotfix` handler 校验 `params.confirm == "true"`，否则返回"高危操作，请传 confirm=true"（防误触，也防 CSRF 式简单 GET 触发）

#### 3.2 targets 支持通配，覆盖动态多实例（#8）

改动 `service/hotfix.lua` `find_service_address` 侧：

- targets 条目支持模式 `"roleagent*"`（尾通配，`*` 只允许出现在末尾）
- 实现方式：`skynet.call(".launcher", "lua", "LIST")` 获取本节点全部服务名 → Lua pattern 匹配（`^roleagent.*$`，pattern 转义除尾 `*` 外的特殊字符）→ 命中地址集合去重
- 系统服务黑名单：`.launcher`、`.service_mgr`、`.gm`、`.hotfix`、`.logger` 永不参与通配命中（精确写明除外）
- 命中 0 个服务 → 该条 target 记失败（与现状一致），fail_fast 时中止
- 明确限制：**通配仅覆盖本节点**；多节点各自执行 hotfix 命令（见 3.3 的跨节点决策）

#### 3.3 patcher 解析沙箱化（#10）

改动 `service/hotfix.lua` `parse_patcher_targets`：

- `load(code, "@"..path, sandbox_env)`，`sandbox_env = setmetatable({}, { __index = function(_, k) error("patcher top-level cannot access global: " .. tostring(k), 2) end })`
- 效果：顶层只允许 `local` 声明与表构造（现有 code1/code2 形态天然合规）；顶层出现 `require`/`print`/读全局等副作用直接报错 → 强制"顶层纯声明"契约
- patcher.run 的实际执行不受影响（注入模板在目标服务内用普通环境 load）

#### 3.4 跨节点策略（#9，本期最小化）

- **本期不做**跨节点自动编排；产出为：
  - `docs/hotfix.md` SOP 明确"逐节点触发 + 逐节点核对 history"的操作步骤
  - history_entry 增加 `node` 字段（见 2.4），为后续聚合做准备
  - 后续任务（Out of scope）：由 monitor 节点聚合各节点 history、提供"集群热更一致性视图"

#### 3.5 clearcache 生效范围验证（#9 关联，验证任务）

- 在测试环境验证 `skynet.cache.clear()` 是否覆盖 `package.loaded`（构造：模块 A 被服务 S require 后替换磁盘文件 → clearcache → 观察 S 内再次 require 是否拿到新代码）
- 结论写入 `docs/hotfix.md`："update_files 生效原理"一节，明确活跃服务需 patcher 显式 `package.loaded[...] = nil; require ...` 重载

### Phase 4：工具链与文档（P3）— 预计 1 天

#### 4.1 统一 checksum 实现（#12）

- 新增 `lualib/hotfix_checksum.lua`：
  - `M.compute(config, hotfix_dir, root_dir)`：按 update_files → code_files 顺序读文件（任一失败 fail-fast 并返回明确错误），`table.concat` 后 `md5.sumhexa`
  - `M.verify(config, hotfix_dir, root_dir)`：compute + 比对，返回 `(ok, err)`，错误文案区分 file missing / mismatch
- `service/hotfix.lua` 的 `verify_checksum` 改为调用该模块
- `tools/hotfix.lua`：优先 `require "md5"`（bin/lua 已含该 cmod，service 端在用），失败再回退外部命令方案；读取校验逻辑改为调用 `hotfix_checksum`

#### 4.2 配置回写健壮化（#13）

改动 `tools/hotfix.lua` `update_config_file`：

- gsub 后检查替换次数（gsub 第四返回值）：`time` 与 `checksum` 各必须恰好 1 次，否则报错且**不写文件**
- 写回后重新 `load` 配置验证 `config.checksum == new_checksum` 且 `config.time == new_time`，形成闭环

#### 4.3 gitsha 版本核对（#14，最小化）

- `execute_hotfix` 在 load_config 后：读环境变量 `build_version`（etc 配置写入，部署流水线注入），若存在且 ≠ `config.gitsha_base` → `log.warn` 并在返回结果中附加提示"当前部署版本与热更基线不一致，请人工确认补丁适用性"（仅警告不阻断）
- 构建链路（tools/dist.py）自动生成版本文件的改造列为后续任务（Out of scope）

#### 4.4 文档（#15、#16）

- 新增 `docs/hotfix.md`，包含：
  1. **patcher 契约**：`{ targets, run }` 字段说明；顶层必须纯声明（沙箱强制）；`run` 在目标服务进程内执行，可安全 require/访问全局；一个 code 文件可声明多个 targets；同 targets 的多个 patcher 按 `code_files` 数组顺序执行（显式声明该顺序即依赖顺序）
  2. **update_files 生效原理**：磁盘替换 → checksum 校验 → clearcache 为下次加载做准备 → 活跃服务由 patcher 显式重载 `package.loaded`（以 3.5 验证结论为准）
  3. **完整 SOP**：开发机生成热更包（改 update_files / 写 patcher）→ `./tools/hotfix.sh refresh <dir>` → 发布文件到各节点 → dry-run 预演 → 逐节点 `POST /gm/execute {cmd:"hotfix", confirm:"true", ...}` → 逐节点核对 history 与业务验证
  4. **失败处置手册**：与 2.3 的 STEP_GUIDANCE 同步
- `docs/gm_api.md` 增补 `hotfix`、`hotfix_history` 两个命令条目（参数、鉴权、示例 curl）

## 4. 测试与验收

新增 `test/test_hotfix/`（仿照 `test/test_jwt/` 结构：`main.lua` + `test.conf`），用例：

| 编号 | 场景 | 期望 |
|---|---|---|
| T1 | 正常 patcher（targets=".gm"）注入 | 各服务 success=true，run 内修改生效 |
| T2 | patcher 语法错误 / 顶层报错 | 注入失败，history success=false（对应 #1） |
| T3 | patcher.run 内 skynet.sleep(6000) | 30s 超时返回失败，锁 300s 后可重入（对应 #5） |
| T4 | update_files 缺文件 | 报 "file not readable" 而非 mismatch（对应 #3） |
| T5 | reload_res 失败 + fail_fast 默认 | 后续步骤中止（对应 #4） |
| T6 | dry-run | 仅返回动作清单，磁盘/服务状态无变化（对应 #11） |
| T7 | targets="roleagent*" 多实例 | 命中全部实例并逐一注入（对应 #8） |
| T8 | 无 token 调 /gm/execute | 拒绝；带 token 成功（对应 #2） |
| T9 | tools refresh：配置含注释字段/异常格式 | 次数校验生效，误替换被拦截（对应 #13） |

手工验收：Phase 3.5 的 clearcache 范围验证结论记录进 docs/hotfix.md。

## 5. 风险与回退

| 风险 | 缓解 |
|---|---|
| 注入模板改为 error 传播后，存量运维脚本依赖"永远成功"的旧行为 | 变更记录在 docs/hotfix.md 变更日志；先在测试环境跑 T1/T2 |
| fork+sleep 超时方案遗留悬挂协程 | 超时后协程完成仅写日志；接受 skynet call 无法取消的平台限制，文档注明 |
| GM 通道加鉴权导致现有 gm.html / 内部脚本失效 | gm.html 同步升级 token 输入；脚本升级为带 token；灰度期可临时配置 token 后观察日志 |
| fail_fast 默认值改变行为（旧配置隐式"继续执行"） | hotfix.conf.lua 显式支持 `fail_fast = false`；变更日志强调默认值变化 |
| 通配 targets 误命中 | 黑名单硬编码 + dry-run 先行核对命中列表 |

## 6. Out of Scope（后续任务）

1. 跨节点热更自动编排与集群一致性视图（依赖 monitor 节点聚合各节点 history）
2. patcher 自动生成工具（git diff → 骨架 + TODO，已决策暂不做，手写路线优先）
3. 函数级热替换库（lua-patch/LuaHunk 式 upvalue 迁移）
4. dist.py 构建 → 版本文件 → gitsha 自动校验的完整闭环
5. 热更历史接入独立审计/告警通道

## 7. 执行顺序与工作量

| Phase | 内容 | 工作量 | 依赖 |
|---|---|---|---|
| Phase 1 | #1 模板修复 + inject_code_files 返回值修复、#5 超时+锁 | 1 天 | 无 |
| Phase 2 | #3 校验、#4 fail-fast、#6 指引、#7 持久化、#11 dry-run | 1.5 天 | Phase 1 |
| Phase 3 | #2 鉴权、#8 通配 targets、#10 沙箱、#9 最小化+验证 | 2 天 | Phase 2 |
| Phase 4 | #12 统一 checksum、#13 回写健壮化、#14 版本核对、#15 文档 | 1 天 | 无（可与 Phase 3 并行） |

合计约 5.5 人日。Phase 1 独立可发布；每 Phase 结束跑对应测试用例并在 `docs/hotfix.md` 变更日志登记。
