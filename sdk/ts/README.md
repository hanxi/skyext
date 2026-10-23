# skyext-client

skyext 客户端 SDK（TypeScript）：Account HTTP + sproto 会话层，浏览器/小程序经 WebSocket 直连网关，支持断线续接。协议语义见[客户端接入规范](../../docs/guide/client_protocol.md)，使用文档见[客户端 SDK 指南](../../docs/guide/client_sdk.md)；Lua 对等实现在 [`sdk/lua/`](../lua/)。

## 安装

ESM，直接导出 TS 源码，由 bun / vite 等打包器消费。游戏项目（skyext 作 submodule）用 `file:` 依赖：

```json
{ "dependencies": { "skyext-client": "file:./skyext/sdk/ts" } }
```

另需游戏项目 `./bin/skyext generate proto` 产出的 `sproto.spb`（登录时 SDK 自动带其 md5 作为 `proto_checksum`，与服务端不一致会被拒绝登录）。

## 快速上手

```ts
import { SkyextClient } from "skyext-client";

const client = new SkyextClient({
    accountHosts: ["http://127.0.0.1:8080"],
    spb: new Uint8Array(await (await fetch("/sproto.spb")).arrayBuffer()),
    tokenProvider: () => myTokenSource.getToken(), // 每次完整登录调用；续接不调用
    onPush: (name, args) => console.log("push", name, args),
    onState: (state) => console.log("state", state), // online / offline / relogin
});

const token = await client.account.devLogin("dev1");
const server = await client.account.pickRecommendedServer();
const role = await client.account.ensureRole(token!, "玩家1", server!);
await client.enterGame({ rid: role!.rid, server: role!.server });

const info = await client.request("role.login_info"); // 断线续接后按原 id 自动重发
client.close();
```

分层可拆用：`AccountClient`（HTTP）、`SessionClient`（会话层，五条义务的实现）、`loadCodec`（sproto 编解码）、`wsTransport`（可替换的小程序适配点）。详见指南的 API 概览。

## 开发

```bash
bun install
bun test                 # 单元测试（fake transport/fetch + 真 spb 编解码）
bunx tsc --noEmit        # 类型检查
SKYEXT_E2E=1 bun test test/e2e   # 真服务器全链路，需先起 account1/role1
```

## 目录

```
src/
├── index.ts       # 公开导出
├── types.ts       # GateInfo / ServerInfo / RoleInfo / SessionState …
├── errcode.ts     # 错误码，与 lualib/skyext/errcode.lua 逐项对应
├── bin.ts         # 字节助手（latin1 / UTF-8 两组）
├── json.ts        # parseJson：JSON 里超 2^53 的整数解成 bigint（rid 无损）
├── md5.ts         # 纯 TS md5（proto_checksum）
├── sproto/        # vendored sproto-js（MIT）+ 两个 skyext 补丁，升级须重新应用：
│                  #   1. string 字节透明（latin1）  2. int64 用 bigint（含 expand64 符号扩展）
├── codec.ts       # loadCodec(spb) → { pack, dispatch, checksum }
├── transport.ts   # Transport 接口 + wsTransport
├── session.ts     # SessionClient：状态机、计数、心跳、续接
├── account.ts     # AccountClient
└── client.ts      # SkyextClient 门面
test/e2e/          # 真服务器全链路（SKYEXT_E2E=1 门控）
```

约定：超过 2^53 的整数（rid 是 17 位 int64）一律 `bigint`，安全范围内保持 `number`。
