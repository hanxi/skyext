# 客户端 SDK 规划（Lua + TypeScript）

> **归档：已交付的实施规划（2026-10）。** 保留作为决策记录：为什么是双实现、nonce 为什么改 `binary`、int64 为什么走 `bigint`、vendor sproto-js 打了哪些补丁。文中「现状」「将要」均指规划当时；现行用法以[客户端 SDK](../guide/client_sdk.md)和代码为准。与规划的出入：语义用例实际为 12 个；小程序 wx transport 只以适配示例写在 client_sdk.md，未随包发布。

为 skyext 提供官方客户端 SDK，按[客户端接入规范](../guide/client_protocol.md)实现全部五条义务，覆盖「拿 token → 选服建角 → 连网关 → 登录 → 断线续接」完整链路。两个实现、一份规范、同一套协议语义测试基线：

- **`sdk/lua/`**：把现有参考实现 `example/lualib/client_session.lua` 升格为正式 SDK，补 Account HTTP 层；robot 改为纯编排，继续充当验收用例。
- **`sdk/ts/`**：新写 TypeScript SDK（浏览器/小游戏，WS 直连 gate_ws）；phaser-game 迁移到它，脱离 goscon/SCP 旧链路。

## 已确认的决策

| 决策点 | 结论 |
| --- | --- |
| SDK 语言 | Lua（robot/压测/skynet 内工具）+ TypeScript（浏览器/小游戏） |
| 代码位置 | skyext 仓库内新顶层目录 `sdk/lua/`、`sdk/ts/`（为将来 sdk/csharp 等留位） |
| 范围 | 完整链路：Account HTTP 层 + 会话层 |
| 示例迁移 | robot 切到 sdk/lua；phaser-game 切到 sdk/ts（独立仓库，提交前单独确认） |

## 依据与可复用资产

- **实现依据**：`docs/guide/client_protocol.md`（规范）；`example/lualib/client_session.lua`（Lua 参考实现，434 行）与其 `client_session.test.lua`（11 个协议语义用例——两种 SDK 共同的测试基线）。
- **Lua 侧资产**：`skyext.httpc`（引擎 HTTP 客户端，robot 在用）、`skyext.errcode`（OK=0 等引擎错误码；游戏层 `example/lualib/errcode.lua` 是它的扩展）、`skyext.sproto_api`（协议加载）。
- **TS 侧资产**：npm 包 `@imhanxi/sproto-js`（`createNew(number[]) → host("base.package") → attach/dispatch`），用法见 `sconn-client/dist/network.js`；**但它对 string 做 UTF-8 编解码，见下面的关键问题**。proto_checksum = spb 字节的 MD5 hex（服务端 `service/sproto_loader.lua` 用 `md5.sumhexa`）。spb 由 `./bin/skyext generate proto` 生成。
- **不用**：sconn-client 的 SCP 连接层（sconn.js/conn.js）——那是 goscon 旧链路。

---

## Lua SDK（sdk/lua/）

### 目录与命名空间

```
sdk/lua/skyext/client/
├── session.lua        ← example/lualib/client_session.lua 迁移
├── session.test.lua   ← 同迁（11 个语义用例；harness 的 source 路径更新）
├── account.lua        ← 新增：robot main.lua 内联 HTTP 逻辑抽取
└── account.test.lua   ← 新增：fake httpc 单测
```

require 路径 `skyext.client.session` / `skyext.client.account`，符合 AGENTS.md 的 `skyext.*` 命名空间约定（物理上与 `lualib/skyext/` 分树，靠 package.path 并存）。

### session.lua 迁移改造（小改，不重写）

- `require "errcode"`（游戏层，SDK 不该依赖）→ `require "skyext.errcode"`（只用 OK）
- 保留 skynet（socket/netpack/websocket/协程）与 `skyext.sproto_api`、`skyext.log` 依赖：Lua SDK 的定位是跑在 skynet 节点里的客户端（robot 即是），不为假想的非 skynet 平台做独立版（non-goals 判断标准一）
- 文件头的「参考实现/规范」注释改为指向 `docs/guide/client_protocol.md` 与 `sdk/ts/`（对等实现）
- 测试 harness 中 `loadfile` 的源码路径改为 `sdk/lua/skyext/client/session.lua`

### account.lua（从 robot 抽取，语义不变）

```lua
local account = require "skyext.client.account"
local a = account.new({ hosts = { "http://127.0.0.1:8080" } }) -- 多 host 随机起点、失败轮换
local token   = a:dev_login("robot1")        -- POST /dev_login（仅开发；正式 token 由平台签发）
local servers = a:servers()                  -- GET /servers（免登录）
local server  = a:pick_recommended_server()  -- recommended 优先，无则回退 "s1"（robot 现行策略）
local roles   = a:roles(token)               -- GET /roles（Bearer 头，token 不进 URL——保留原注释）
local role    = a:ensure_role(token, name, server) -- 有角色取第一个，没有则 POST /create_role
local gates   = a:gates()                    -- GET /gates（免登录，只含真在线的网关）
```

基于 `skyext.httpc` + `cjson.safe`，实现即 robot `main.lua` 里 fetch_token / pick_server / fetch_gates / authed / ensure_role 五个函数的搬迁与规整。

### robot 切换

`example/nodes/robot/robotagent/main.lua`：删掉五个内联 HTTP 函数（约 70 行），改用 `skyext.client.account`；`require "client_session"` → `require "skyext.client.session"`。**保留** play / check_resume / run 编排、gate 错开轮换、tcp+ws 双传输一致性验证——robot 继续是 Lua SDK 的端到端验收用例（`./bin/skyext serve robot` 即 E2E）。

### 工程接入

- `example/etc/paths.conf.lua`：lua_path 链加 `skyext_root .. "sdk/lua/?.lua;"` 与 `?/init.lua`（放在游戏生成物之后、引擎 `lualib/` 之前；游戏层可有意遮蔽 SDK，SDK 与引擎命名空间不相交）
- `scripts/commands/test.lua`：discover 默认 targets `{ "lualib", "service", "example", "test" }` 加 `"sdk"`，否则 sdk 下的 `.test.lua` 不会被 `./bin/skyext test` 扫到（walk 已自动跳过 node_modules）
- luacheck / stylua：`.luacheckrc` 的 exclude_files 不含 sdk/，自动覆盖，无需改动
- framework 打包走全仓 walk，sdk/lua 自动进包

### Lua SDK 验证

- `./bin/skyext test sdk/` —— 迁移后的 11 个语义用例 + 新增 account 单测
- `./bin/skyext serve robot` —— tcp/ws 双传输全链路 + 断线续接验收（现有流程，零新增设施）

---

## TypeScript SDK（sdk/ts/）

### 关键技术问题：sproto string 必须字节透明

服务端续接凭据 `nonce = crypto.random_bytes(16)`（`lualib/skyext/entity/session.lua`）是**原始随机字节**。Lua 侧 sproto 对 string 字节透明，robot 能原样带回；而 `@imhanxi/sproto-js` 解码走 `utf82string`、编码走 `string2utf8`——随机字节不是合法 UTF-8，往返必坏，**resume 将永远失败，且平时完全看不出来**。

采纳的方案分两层，各司其职：

1. **schema 层**：`login.sproto` 的三处 nonce 字段声明为 `binary`（sproto 里 binary 是 string 的子类型，**线上格式完全不变**，Lua/C 等字节透明绑定零感知）。sproto-js 对 binary 字段解码产出 `number[]` 字节数组、编码接受 `number[]` 原样透传，凭据从表示层上就不可能经过任何文本转换。
2. **编解码层**：仍然把 sproto-js 源码 vendor 进 `sdk/ts/src/sproto/`（MIT，实施前核实 LICENSE），string 编解码改为字节透明（latin1：编码 `charCodeAt & 0xFF`，解码逐字节 `fromCharCode`）——vendor 出来的 sproto 只做纯字节编解码，**UTF-8 转换上移到 `codec.ts` 的 API 边界**：解码出来的 JS 字符串（只可能来自 `string` 字段）统一按 UTF-8 转成文本；用户传入的 JS 字符串统一按 UTF-8 转成字节串；`Uint8Array` 转 `number[]`。游戏业务代码拿到的就是普通 JS 文本，不需要知道任何编码细节。

`bin.ts` 提供两组 helper 支撑上述边界：

- `toBytes / fromBytes`：latin1 字节串 ↔ Uint8Array（wire 层）
- `toText / fromText`：UTF-8 文本 ↔ Uint8Array / 字节串（API 层）

备选：给上游 `@imhanxi/sproto-js` 增加 raw-string 选项发新版，SDK 改回依赖 npm 包、删 vendor 目录（binary 字段不受影响，补丁只涉及 string 字段）。

### 关键技术问题：int64 精度（rid 必须无损往返）

实体 id（rid）是 17 位 int64（如 `70067467908940524`），超过 JS 安全整数 2^53。float64 存不下：裸 `JSON.parse` 与 sproto-js 上游的整数解码都会**静默**把它腐蚀成邻近的浮点值，login 带着错 rid 会被服务端的精确匹配拒绝——phaser-game 现在就潜伏着这个 bug（`rid: number` + 裸 `response.json()`）。两条数据通道分别处理：

1. **sproto 通道**（vendored 补丁 2，搜「补丁」+ bigint）：8 字节整数解码按二进制补码还原，|v| ≤ 2^53 给 `number`、超出给 `bigint`（上游只有 float64 一条路；负 int64 还会解成巨大无符号数，一并修掉）；编码接受 `bigint`，超 int32 按 8 字节补码写出。顺带修了 `expand64`：4 字节整数按 int32 符号扩展，与 C 实现一致（上游不扩展，int32 负数解成无符号正数）。
2. **HTTP/JSON 通道**（`json.ts` 的 `parseJson`）：词法扫描把不安全整数字面量加引号标记（字符串内部的数字不动），`JSON.parse` reviver 还原成 `bigint`。account 层所有响应走 `parseJson`。

约定：安全范围内的整数一律保持 `number`，业务代码只在 rid 上见到 `bigint | number`（见 `types.ts` 的 `RoleInfo`）。request id 计数器不受影响——自增到 2^53 实际不可达，不引入 bigint（见「风险与开放问题」）。

### 目录结构

```
sdk/ts/
├── package.json            # 包名 skyext-client（可再议），ESM，bun 构建，提交 bun.lock
├── tsconfig.json
├── README.md
├── src/
│   ├── index.ts            # 公开导出
│   ├── types.ts            # GateInfo / ServerInfo / RoleInfo / SessionOptions / ClientState ...
│   ├── errcode.ts          # 错误码常量，注释指向 lualib/skyext/errcode.lua
│   ├── bin.ts              # 字节助手（latin1 / UTF-8 两组）
│   ├── md5.ts              # 纯 TS md5（hex），RFC 测试向量 + spb 交叉核对
│   ├── sproto/             # vendor 的 sproto 编解码器 + 字节透明补丁
│   ├── codec.ts            # loadCodec(spb) → { pack, dispatch, checksum }
│   ├── transport.ts        # Transport 接口 + wsTransport（binary 帧；小程序注入自定义适配）
│   ├── session.ts          # SessionClient：状态机、计数、心跳、续接、pending 管理
│   ├── account.ts          # AccountClient：devLogin / servers / roles / createRole / gates / ensureRole
│   ├── client.ts           # SkyextClient facade：tokenProvider + gate 轮换 + 会话生命周期
│   ├── session.test.ts     # 移植 11 个语义用例（fake transport + fake codec）
│   ├── codec.test.ts       # 真 spb：pack/dispatch、随机 16 字节 nonce 往返、md5 对账
│   └── account.test.ts     # fake fetch
└── test/
    └── e2e/login.test.ts   # 真服务器全链路（SKYEXT_E2E=1 门控）
```

### 接口草案（细节实施时定）

```ts
// transport.ts —— 事件式，映射浏览器 WebSocket；帧边界即包边界
export interface TransportConn {
  send(bytes: Uint8Array): void
  close(): void
  onMessage(cb: (bytes: Uint8Array) => void): void
  onClose(cb: () => void): void
}
export interface Transport {
  connect(endpoint: Endpoint): Promise<TransportConn> // 失败 reject，由上层换下一台
}

// session.ts —— client_session.lua 的等价物
export interface SessionOptions {
  resolveEndpoints: () => Endpoint[] | Promise<Endpoint[]> // 每次重连周期调用（gate 轮换）
  transport?: Transport                                    // 默认 wsTransport
  codec: Codec                                             // loadCodec(spb)
  loginParam: () => LoginParam | Promise<LoginParam>       // token 可能过期，所以是函数
  pingIntervalMs?: number     // 默认 15_000
  pingTolerance?: number      // 默认 2
  reconnectDelayMs?: number   // 默认 1_000
  handshakeTimeoutMs?: number // 默认 5_000
  onPush?: (name: string, msg: unknown) => void
  onState?: (state: 'online' | 'offline' | 'relogin') => void
}
export class SessionClient {
  start(): Promise<boolean>
  // 无 timeout 的 Promise 跨重连存活：续接成功后按原 id 重发，等待正是机制的意义
  request<T = unknown>(name: string, param?: object, timeoutMs?: number): Promise<T | null>
  reconnect(): void // 主动丢弃当前连接走续接（切网检测、测试用）
  close(): void
  readonly online: boolean
  // recv / nonce / rid 以只读暴露，供测试断言
}

// account.ts —— 与 sdk/lua account.lua 同语义
export class AccountClient {
  constructor(opts: { hosts: string[]; fetchImpl?: typeof fetch })
  devLogin(account: string): Promise<string>
  servers(): Promise<ServerInfo[]>
  pickRecommendedServer(): Promise<string>
  roles(token: string): Promise<RoleInfo[]>
  createRole(token: string, server: string, name: string): Promise<RoleInfo>
  ensureRole(token: string, name: string, server: string): Promise<RoleInfo>
  gates(): Promise<GateInfo[]>
}

// client.ts —— facade
const client = new SkyextClient({
  accountHosts: ['http://127.0.0.1:8080'],
  spb: new Uint8Array(await (await fetch('/resources/protocol/sproto.spb')).arrayBuffer()),
  tokenProvider: () => Promise<string>,  // gamepass OAuth / dev_login / 平台 SDK，可插拔
  onPush, onState,
})
await client.enterGame({ rid, server })  // /gates → 轮换建连 → resume 或 login
const info = await client.request('role.login_info')
client.close()
```

### 会话层语义要点（协程 → async/await 的映射）

| 义务 | TS 实现要点 |
| --- | --- |
| 1. 自增 request id、原 id 重发 | `nextReqId` 仅构造时置 0；`pending: Map<reqId, {name, param, resolve, answered}>`；resume 成功 → 按**原 reqId** 重发；login 成功 → 全部 resolve(null)、`recv = 0` |
| 2. 数收到的下行包 | 计数写在 onMessage 回调**第一行**（解码分发之前）；匹配不上 pending 的重复响应先计数再丢 |
| 3. 握手回包不计数 | `UNCOUNTED_RESPONSE = new Set(['login.login','login.resume','login.ping'])`，按请求名判断；push 照常计数 |
| 4. 自己发现断线 | 15s 一次 `login.ping {recv}`，**收到响应**才重置 miss 计数，连续 2 次超时 → drop；`resp.sent !== recv` → 清 nonce、drop（走完整登录） |
| 5. 不假设 resume 响应与重放保序 | resume 响应靠 reqId 认领、不计数；任何下行包到达即处理，不等 resume 响应 |

其余要点：resume 失败（**任何**错误码）→ 清 nonce → 完整登录，不重试；成功 → 保存**轮换后**的新 nonce。TransportConn 带代际标记，迟到的断开通知不影响新连接（对应 Lua 的 `drop(conn)`）。收包回调抛错不能终止会话（参考实现 reader 的 pcall 教训）。握手类请求带超时，超时的 pending 条目**保留**用于计数分辨；业务请求默认无超时。

### TS 测试策略

1. **语义单测**（`session.test.ts`）：移植 `client_session.test.lua` 全部 11 个用例（fake transport + fake codec，测计数与重发、不测 sproto），bun test 运行——与 Lua 版构成同一基线的双实现互证。
2. **codec 单测**：真 spb pack/dispatch 回环；**随机 16 字节 nonce 往返逐字节相等**（头号风险点）；`md5(spb)` 与 `./bin/lua` 的 `md5.sumhexa` 一致。
3. **E2E**（`SKYEXT_E2E=1` 门控，沿用 `SKYTEST_INTEGRATION` 约定）：前置 account1 + role1 已启动、mongo/etcd 可用；dev_login → /servers → /roles|/create_role → /gates → WS 直连 → login.login → role.login_info → 在途请求中 `reconnect()` → resume 成功、凭据轮换、在途请求完成 → close。
4. **自检清单**：完成后逐条核对 `client_protocol.md` 第 7 节 12 条。

---

## CI、构建与打包

- **CI**（`.github/workflows/coverage.yml` 扩展）：
  - Lua：现有 `./bin/skyext test` 自动覆盖 sdk/lua（discover targets 加 "sdk" 之后）
  - TS 单测：安装 bun（`oven-sh/setup-bun`）→ `cd sdk/ts && bun install && bun run typecheck && bun test`
  - TS E2E：复用现有 mongo/etcd services；`generate proto` 后后台起 account1/role1，等端口就绪，`SKYEXT_E2E=1 bun test test/e2e/`，完毕杀进程
- **TS 构建**：ESM + d.ts，`bun build`（与 phaser-game、sconn-client 生态一致）；`tsc --noEmit` 类型检查；不引入 eslint 等新工具
- **引用方式**：游戏项目（skyext 作 submodule）用 `file:` 依赖或 bun link 指向 `sdk/ts`；npm 发布后置
- **打包与忽略**：`scripts/commands/package.lua` framework 排除名单加 `node_modules`（否则发布包被 sdk/ts 依赖撑爆）；根 `.gitignore` 加 `node_modules/`

## phaser-game 迁移（submodule，独立仓库 hanxi/phaser-game）

1. `NetworkService.ts`：sconn-client `Network` → SDK 的 `SkyextClient`/`SessionClient`，直连 `/gates` 的 `ws_url`
2. `ServerDataService.ts`：`serverlist.json` 只保留 `account_hosts`；服务器列表改 `GET /servers`，网关改 `GET /gates`，删掉 rolenode 映射
3. token：gamepass OAuth 流程不变，接进 `tokenProvider`；`AccountService` 换用 SDK 的 `AccountClient`
4. `package.json` 去 `sconn-client`、加 SDK 依赖；spb 加载方式不变（fetch 后交给 SDK，checksum 由 SDK 计算）
5. 手测（浏览器）：登录 → 选服 → 建角 → 进游戏 → DevTools 断网/切网 → 验证 resume 业务无感
6. goscon 子模块从示例链路退役（README、fullstack 文档相应更新）

## 文档

- 新增 `docs/guide/client_sdk.md`：两个 SDK 的安装、快速上手、API 概览、小程序 transport 适配、常见错误码、指向 client_protocol.md 的义务与自检清单
- **引用路径更新**（client_session 迁移牵连）：`client_protocol.md`（第 5 行「可执行的参考实现」）、`login.md`（robot 代码摘录与路径）、`design/session_resume.md`（第 292 行）、AGENTS.md（项目边界表加 `sdk/` 行、loader 的 package.path 描述）、README.md（项目结构表加 `sdk/` 行）
- `docs/_sidebar.md` 加 client_sdk 条目
- `fullstack_client.md`：phaser-game 迁移后删 goscon 章节、更新链路图

## 实施阶段

| 阶段 | 内容 | 验证 |
| --- | --- | --- |
| 1 | **sdk/lua**：session 迁移 + account 抽取 + robot 切换 + paths.conf/test.lua 接入 + 文档引用更新 | `./bin/skyext test sdk/` 全绿；`serve robot` 双传输跑通含续接；luacheck/stylua 过 |
| 2 | **TS codec**：vendor sproto + 字节透明补丁 + bin/md5/codec | codec 单测：随机 nonce 往返、md5 与服务端对账 |
| 3 | **TS 会话层**：transport + session 状态机 | 11 个语义单测全绿；对照自检清单 |
| 4 | **TS 完整链路**：account + facade + E2E | 真服务器全链路跑通（含断开续接） |
| 5 | **工程化**：CI、打包排除、文档 | CI 绿；`package framework` 产物不含 node_modules |
| 6 | **phaser-game 迁移** + fullstack 文档更新 | 浏览器手测全链路 + 断网续接 |

阶段 1 独立于 TS 侧，先落地可以确立 `sdk/` 的目录、命名空间与测试接入约定；每阶段独立可提交（Conventional Commits，中文，直接进 main，提交前经用户确认）。

## 风险与开放问题

1. **sproto string 字节透明**（已给方案）：补丁范围小（encode/decode 两处），必须用随机字节往返测试钉死；vendor 前核实 `@imhanxi/sproto-js` 的 LICENSE。
2. **client_session 迁移的引用面**：robot、测试 harness、三处文档、AGENTS.md/README——阶段 1 一次改齐，`grep client_session` 清零验证。
3. **number[] ↔ Uint8Array 转换开销**：sproto-js 接口是 number[]；消息频率不高，先直转，有热点再优化。
4. **64 位 request id**：JS 安全整数 2^53 实际不可达，不引入 bigint。
5. **小程序适配**：本期只留 Transport 接口，不实现 wx.connectSocket 适配器。
6. **是否发布 npm**：本期不发布；包名（skyext-client / @skyext/client）后置决定。
7. **上游回收**：若 sproto-js 上游发版支持 raw string，SDK 可删 vendor 目录改回依赖。
