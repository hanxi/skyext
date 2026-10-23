# 客户端 SDK

skyext 提供两个官方客户端 SDK，都完整实现[客户端接入规范](client_protocol.md)（含五条义务），并共享同一套语义测试基线（`session.test.lua` / `session.test.ts`，12 个用例逐条对应）：

| SDK | 位置 | 运行环境 | 传输 | 典型用途 |
| --- | --- | --- | --- | --- |
| Lua | `sdk/lua/`（`skyext.client.*`） | skynet 节点内 | TCP（2 字节长度前缀）/ WS | 机器人、压测、GM 工具、内嵌 Lua 的客户端 |
| TypeScript | `sdk/ts/`（包名 `skyext-client`） | 浏览器 / 小程序 / bun / node | WS（binary 帧） | H5、微信等小程序、桌面端 |

两者都是三层结构，可整用也可拆用：**Account HTTP 层**（登录签发、选服、角色、网关发现）→ **会话层**（连接、login/resume/ping、计数、续接）→ **门面**（TS 独有，把前两层串成「拿 token → 进游戏」一条路）。

协议字节、握手时序、五条义务的语义细节都在规范文档里，本篇只讲两个 SDK 怎么用。

## TypeScript SDK

### 安装

ESM，直接导出 TS 源码（`exports` 指向 `src/index.ts`），由 bun / vite 等打包器直接消费。游戏项目把 skyext 作为 submodule 时用 `file:` 依赖：

```json
{ "dependencies": { "skyext-client": "file:./skyext/sdk/ts" } }
```

还需要 `sproto.spb`——游戏项目 `./bin/skyext generate proto` 的产物，随客户端打包或由静态资源下发。**必须和服务端用同一份**：登录时 SDK 自动带上它的 md5（`proto_checksum`），不一致服务端会拒绝登录。

### 快速上手

```ts
import { SkyextClient } from "skyext-client";

const spb = new Uint8Array(await (await fetch("/sproto.spb")).arrayBuffer());
const client = new SkyextClient({
    accountHosts: ["https://account.example.com"],
    spb,
    // 每次完整登录调用一次；续接不调用。token 来源可插拔：
    // dev_login、gamepass OAuth、平台 SDK 都行
    tokenProvider: () => platformSdk.getToken(),
    onPush: (name, args) => { /* 服务端主动推送 */ },
    onState: (state) => { /* "online" | "offline" | "relogin" */ },
});

// 1) Account 层：登录 → 选服 → 建角（正式项目里 token 由平台签发）
const token = await client.account.devLogin("dev1");
const server = await client.account.pickRecommendedServer();
const role = await client.account.ensureRole(token!, "玩家1", server!);

// 2) 进游戏：/gates 发现在线网关 → WS 建连（失败自动换下一台）→ login/resume
await client.enterGame({ rid: role!.rid, server: role!.server });

// 3) 业务请求。断线续接后按原 request id 自动重发，等待跨越重连；
//    会话彻底不可用时 resolve null
const info = await client.request("role.login_info");

// 4) 切网检测（切 WiFi/蜂窝）时不等心跳超时，立刻走续接
client.reconnect();

client.close();
```

`enterGame` 返回首次握手是否成功；返回 `false` 不抛错——会话层会按 `reconnectDelayMs` 持续重连，`onState` 能观察到全过程。

### API 概览

**`SkyextClient`**（门面，`client.ts`）

| 成员 | 说明 |
| --- | --- |
| `enterGame({ rid, server })` | 建连进游戏，只能调一次；`server` 必须是角色的出生服 |
| `request<T>(name, param?)` | 业务请求，无超时；未 `enterGame` 时返回 `null` |
| `reconnect()` / `close()` | 主动续接 / 关闭（关闭后 pending 全部失败） |
| `account` / `codec` | 内部两层的实例，可单独使用 |
| `online` / `nonce` / `recv` | 可观测性：在线状态、续接凭据（成功后必轮换）、下行计数 |

**`AccountClient`**（`account.ts`）：`new AccountClient({ hosts, fetchImpl? })`。hosts 随机起点轮换，**只在传输失败/非 200 时换下一台**；业务错误（200 + `code ≠ 0`）是有效应答，原样返回。所有方法失败返回 `null`。token 只进 `Authorization: Bearer` 头，绝不进 URL。

| 方法 | 对应接口 |
| --- | --- |
| `devLogin(account)` | `POST /dev_login`（仅开发环境） |
| `servers()` / `pickRecommendedServer()` | `GET /servers` |
| `roles(token, server?)` / `createRole(token, server, name)` / `ensureRole(token, name, server)` | `GET /roles`、`POST /create_role` |
| `gates()` | `GET /gates`（在线网关列表） |

**`SessionClient`**（`session.ts`）：不走门面时直接用它——`resolveEndpoints`（每轮重连调用，返回 `Endpoint[]`）、`codec`、`loginParam`（返回 `login.login` 请求体）三个必填项，加 `transport`（默认 `wsTransport()`）与心跳/超时调参（`pingIntervalMs=15000`、`pingTolerance=2`、`reconnectDelayMs=1000`、`handshakeTimeoutMs=5000`）。五条义务全部在这一层实现。

**`loadCodec(spb)`**（`codec.ts`）：`{ pack, dispatch, checksum, recoverDispatch }`，sproto 编解码 + md5。

### int64 约定

rid 是 17 位 int64，超出 JS 安全整数。SDK 的约定：**超过 2^53 的整数一律 `bigint`，安全范围内保持 `number`**。JSON 侧由 `parseJson` 保证（内部把不安全整数字面量加引号后再 `JSON.parse`），sproto 侧由 vendored 编解码器保证（int64 字段直接收发 `bigint`）。业务代码拿到 `RoleInfo.rid` 时按 `bigint | number` 处理，回填给 `enterGame` / 协议参数时原样传回即可，不要 `Number()` 它。

### 小程序 transport 适配

小程序没有标准 `WebSocket` 对象，但有 `wx.connectSocket`。实现 `Transport` 接口注入即可（会话层只依赖接口）：

```ts
import type { Transport, TransportConn, Endpoint } from "skyext-client";

export function wxTransport(): Transport {
    return {
        connect(endpoint: Endpoint): Promise<TransportConn> {
            return new Promise((resolve, reject) => {
                const task = wx.connectSocket({ url: endpoint.url });
                let opened = false;
                let closedNotified = false;
                let messageCb: ((bytes: Uint8Array) => void) | null = null;
                let closedCb: (() => void) | null = null;
                const notifyClosed = () => {
                    if (!closedNotified) {
                        closedNotified = true;
                        closedCb?.();
                    }
                };
                const conn: TransportConn = {
                    send: (bytes) => task.send({ data: bytes.buffer }),
                    close: () => task.close({}),
                    onMessage: (cb) => { messageCb = cb; },
                    onClosed: (cb) => {
                        closedCb = cb;
                        if (closedNotified) { cb(); }
                    },
                };
                task.onOpen(() => { opened = true; resolve(conn); });
                task.onMessage((res) => messageCb?.(new Uint8Array(res.data as ArrayBuffer)));
                task.onClose(() => {
                    if (opened) { notifyClosed(); } else { reject(new Error("ws 握手失败")); }
                });
                task.onError(() => {
                    // 建连前的错误直接 reject；建连后交给 onClose 统一归口
                    if (!opened) { reject(new Error(`ws 无法连接 ${endpoint.url}`)); }
                });
            });
        },
    };
}

new SkyextClient({ /* … */ transport: wxTransport() });
```

要点和内置 `wsTransport` 一致：`connect` 在建连成功时 resolve；此后所有断开事件**归一为一次 `onClosed`**；`onClosed` 注册晚于断开时要立即补发。TCP 传输（原生 APP）不走这个接口——目前只有 Lua SDK 提供，TS 侧需要时按同一模式包一层长度前缀分帧即可。

## Lua SDK

### 引用

`skyext` 节点的 `lua_path` 已包含 `sdk/lua/`（`example/etc/paths.conf.lua`），直接 require：

```lua
local client_account = require "skyext.client.account"
local client_session = require "skyext.client.session"
```

依赖 skynet 的 socket/httpc，所以运行环境是 skynet 节点（机器人、压测工具、GM 脚本），不是独立 Lua 进程。sproto 编解码用节点已加载的协议（`skyext.sproto_api`），不需要单独传 spb。

### 快速上手

完整可跑的例子就是机器人：`example/nodes/robot/robotagent/main.lua`（`./bin/skyext serve robot`，需先起 account1/role1）。核心编排：

```lua
-- Account 层：登录 → 建角 → 网关发现
local account = client_account.new({ hosts = { "http://127.0.0.1:8080" } })
local token = account:dev_login("robot1")
local role = account:ensure_role(token, "robot1", account:pick_recommended_server() or "s1")
local gates = account:gates()          -- 只含真的在线的网关，自己挑，连不上换下一台

-- 会话层：连接、登录、计数、心跳、续接全在里面
local s = client_session.new({
    transport = "tcp",                  -- 或 "ws"
    host = host, port = port,           -- tcp 用
    url = gate.ws_url,                  -- ws 用
    login_param = function()            -- 每次完整登录调用；续接不调用
        return {
            token = token,
            rid = role.rid,
            server = role.server,       -- 必须是出生服
            proto_checksum = sproto_api.get_sproto_info().checksum,
        }
    end,
    on_push = function(name, msg) end,  -- 服务端主动推送
    on_state = function(state) end,     -- "online" / "offline" / "relogin"
})
assert(s:start())                       -- 首次握手；失败后重连协程仍会持续重试

local ret = s:call("role.login_info")   -- 无超时：续接后按原 id 重发，等待跨越重连
s:reconnect()                           -- 主动丢弃连接走续接（切网检测/测试）
s:close()                               -- 关闭，pending 全部失败
```

### API 概览

**`client_account`**：`new({ hosts })`，语义与 TS 的 `AccountClient` 完全一致（随机起点轮换、传输失败才换台、业务错误原样返回、失败返回 `nil`）。方法：`dev_login(name)`、`servers()`、`pick_recommended_server()`、`roles(token)`、`create_role(token, server, name)`、`ensure_role(token, name, server)`、`gates()`。

**`client_session`**：`new(conf)` 后 `start()` / `call(name, param)` / `request(name, param, timeout)` / `reconnect()` / `close()`；可读字段 `online`、`nonce`（续接成功必轮换）、`recv`（下行计数，与服务端 `sent` 对账）、`rid`。调参项：`ping_interval=15`、`ping_tolerance=2`、`reconnect_delay=1`、`handshake_timeout=5`（单位秒）。

## 常见错误码

引擎错误码在 `lualib/skyext/errcode.lua`（唯一权威），TS 侧对应 `ErrCode`（`skyext-client` 导出）。会话层相关的这几个值得单独认识：

| 码 | 名称 | 客户端该做什么 |
| --- | --- | --- |
| 0 | `OK` | — |
| 11 | `AUTH_FAILED` | token 无效/过期：重新走签发流程再登录 |
| 23 | `SESSION_CLOSED` | 会话已关闭：重新登录 |
| 24 | `RESUME_UNAVAILABLE` | 这条会话续接不了（重放缓冲溢出/计数越界）。**清 nonce 走完整登录，绝不重试 resume**——SDK 已内置该行为 |
| 25 | `REQUEST_EXPIRED` | 该 request id 的响应已被幂等缓存淘汰：重走业务流程 |
| 26 | `REQUEST_CONFLICT` | 同一 request id 上次是另一条协议——说明客户端把请求计数器重置了，这是客户端 bug（义务 1） |

游戏业务自己的错误码（如示例项目的 `TOKEN_ERROR`、`NAME_TAKEN`，在 `example/lualib/errcode.lua`）是项目扩展，按各自项目定义处理。

## 测试与验收

```bash
# Lua：语义单测（fake 传输，12 用例）
./bin/skyext test sdk/

# Lua：真链路。先起 account1/role1，双传输各跑一遍完整业务 + 断线续接
./bin/skyext serve robot

# TypeScript：单测 + 类型检查
cd sdk/ts && bun install && bun test && bunx tsc --noEmit

# TypeScript：真服务器全链路（需先起 account1/role1；SKYEXT_ACCOUNT 可改地址）
cd sdk/ts && SKYEXT_E2E=1 bun test test/e2e
```

robot 与 TS E2E 验收的是同一条链路：登录 → 业务请求 → 主动断线 → 续接（凭据轮换、下行计数对账、不重新登录）→ 在途请求按原 id 完成。

## 自实现检查清单

给新平台写 SDK 时，照[客户端接入规范](client_protocol.md)实现，**不要逐行翻译现有实现**（Lua 版混了 skynet 协程细节，TS 版混了浏览器事件模型）。完成后用规范第 3 节的五条义务逐条自检，并把 `sdk/lua/skyext/client/session.test.lua` 的 12 个语义用例移植过去——两个官方 SDK 都是这么验收的。
