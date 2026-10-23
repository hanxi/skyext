// skyext 客户端 SDK 公开入口。规范：docs/guide/client_protocol.md；
// Lua 对等实现：sdk/lua/（skyext.client.account / skyext.client.session）。
//
// 分层（自下而上，可单独使用）：
//   codec      sproto 编解码（loadCodec）+ md5 checksum
//   account    Account HTTP：dev_login / 选服 / 角色 / 网关发现
//   session    会话层：登录、计数、心跳、断线续接（五条义务的实现）
//   client     门面：account + session 串成「拿 token → 进游戏」一条路

export { loadCodec, type Codec, type CodecResult, type CodecRequest, type CodecResponse } from "./codec.js";
export { md5, md5Hex } from "./md5.js";
export { parseJson, quoteUnsafeIntegers } from "./json.js";
export {
    toBytes,
    fromBytes,
    toText,
    fromText,
    textToByteString,
    byteStringToText,
    toNumberArray,
    fromNumberArray,
} from "./bin.js";
export { ErrCode, type ErrCodeValue } from "./errcode.js";
export type { GateInfo, ServerInfo, RoleInfo, SessionState, ProtoArgs, ProtoValue } from "./types.js";
export {
    wsTransport,
    type Transport,
    type TransportConn,
    type Endpoint,
} from "./transport.js";
export { SessionClient, type SessionOptions, type LoginParam } from "./session.js";
export { AccountClient, type AccountOptions } from "./account.js";
export { SkyextClient, type SkyextClientOptions, type EnterGameOptions } from "./client.js";
