// sproto 编解码门面。包住 vendored sproto（src/sproto/），对上提供干净契约：
//
//   pack(name, args, session) → Uint8Array     上行请求（wire 格式：0-pack 后的 sproto 包）
//   dispatch(data) → CodecResult | null        下行包：REQUEST（服务端推送）或 RESPONSE
//   checksum                                    spb 的 md5 hex，login 时作 proto_checksum
//
// 边界约定（业务代码只看这里，不接触 sproto 内部表示）：
//   - string 字段：JS 侧一律是 UTF-8 文本。pack 时深度遍历自动转字节串，
//     dispatch 时自动转回文本（vendored sproto 补丁 1 保证 wire 层字节透明）
//   - binary 字段（如 nonce）：JS 侧是 number[] 字节数组（编码也接受 Uint8Array），
//     任何方向都不经过字符串，随机字节原样往返
//   - integer 字段：安全范围内是 number，超出 2^53（如 17 位 rid）是 bigint
//     （vendored sproto 补丁 2）
//   - dispatch 返回 null 表示包无法解码：丢这一个包并记录，不要断连接——
//     包边界由传输层保证，坏一个包不影响后续（与 Lua SDK 行为一致）
//   - 重复响应（续接后同一 request id 的第二份回包）能正常 dispatch 出
//     {type:"response"}，args 为 undefined——计数与丢弃是会话层的义务，见
//     docs/guide/client_protocol.md 义务 2

import { createNew } from "./sproto/index.js";
import type { SprotoHost, SprotoInstance } from "./sproto/sproto.js";
import { md5Hex } from "./md5.js";
import { byteStringToText, textToByteString, toNumberArray } from "./bin.js";
import type { ProtoArgs } from "./types.js";

/** sproto 包头类型名，与服务端 lualib/skyext/sproto_api.lua 一致 */
const PACKAGE_NAME = "base.package";

export interface CodecRequest {
    type: "request";
    /** 协议名，如 "mail.notify" */
    name: string;
    /** 请求体；协议无 request 定义时缺省 */
    args?: ProtoArgs;
    /** 服务端带 session 发起的请求才有（客户端通常只收无 session 的推送） */
    session?: number;
    /** 回包函数，仅 session 请求有。给测试/mock 服务端用，正式客户端用不到 */
    respond?: (args?: ProtoArgs) => Uint8Array;
}

export interface CodecResponse {
    type: "response";
    /** 对应 pack 时传入的 request id */
    session: number;
    /** 响应体。协议无 response 定义、或这是重复响应（类型信息已被第一份消费）时缺省 */
    args?: ProtoArgs;
}

export type CodecResult = CodecRequest | CodecResponse;

export interface Codec {
    pack(name: string, args?: ProtoArgs, session?: number): Uint8Array;
    dispatch(data: Uint8Array): CodecResult | null;
    readonly checksum: string;
}

// ------------------------------------------------------------------ 深度转换

function isPlainObject(v: unknown): v is Record<string, unknown> {
    return typeof v === "object" && v !== null && !Array.isArray(v) && !(v instanceof Uint8Array);
}

/** API → wire：文本转 UTF-8 字节串，Uint8Array 转 number[]，其余原样 */
function encodeDeep(v: unknown): unknown {
    if (typeof v === "string") {
        return textToByteString(v);
    }
    if (v instanceof Uint8Array) {
        return toNumberArray(v);
    }
    if (Array.isArray(v)) {
        return v.map(encodeDeep);
    }
    if (isPlainObject(v)) {
        const out: Record<string, unknown> = {};
        for (const key of Object.keys(v)) {
            out[key] = encodeDeep(v[key]);
        }
        return out;
    }
    return v;
}

/** wire → API：字节串按 UTF-8 转文本，number[]（binary 字段/整数数组）原样，bigint 原样 */
function decodeDeep(v: unknown): unknown {
    if (typeof v === "string") {
        return byteStringToText(v);
    }
    if (Array.isArray(v)) {
        return v.map(decodeDeep);
    }
    if (isPlainObject(v)) {
        const out: Record<string, unknown> = {};
        for (const key of Object.keys(v)) {
            out[key] = decodeDeep(v[key]);
        }
        return out;
    }
    return v;
}

// ------------------------------------------------------------------ Codec

/**
 * 从 spb 二进制（./bin/skyext generate proto 的产物）创建编解码器。
 * schema 损坏时抛错；checksum 供 login.login 的 proto_checksum 字段使用。
 */
export function loadCodec(spb: Uint8Array): Codec {
    // 不标注类型：让 if 守卫把 null 从推断类型里窄化掉，闭包里也能保持
    const sp = createNew(toNumberArray(spb));
    if (!sp) {
        throw new Error("sproto: 无法解析 schema（spb 损坏或格式不对）");
    }
    const host: SprotoHost = sp.host(PACKAGE_NAME);
    const packFn = host.attach(sp);
    const checksum = md5Hex(spb);

    // host.dispatch 对「重复响应」会抛错：第一份响应已把 session 的类型信息
    // 消费掉，第二份进来 decode(undefined) 炸。续接场景这是正常事件（义务 2），
    // 手动解包头把 session 认出来，按无 body 的响应返回，让会话层去计数
    // 箭头函数而不是 function 声明：函数声明会提升到守卫之前创建，
    // TS 就不敢把 sp 的 null 窄化带进闭包
    const recoverDispatch = (arr: number[]): CodecResult | null => {
        try {
            const bin = sp.unpack(arr);
            const header = sp.decode(host.package as never, bin) as Record<string, unknown> | null;
            if (header && !header.type && typeof header.session === "number") {
                return { type: "response", session: header.session };
            }
        } catch {
            // 连包头都解不出来：真正的坏包
        }
        return null;
    };

    return {
        pack(name: string, args?: ProtoArgs, session?: number): Uint8Array {
            const encoded = args === undefined ? undefined : (encodeDeep(args) as ProtoArgs);
            const bytes = (packFn as (n: string, a?: ProtoArgs, s?: number) => number[])(name, encoded, session);
            return Uint8Array.from(bytes);
        },

        dispatch(data: Uint8Array): CodecResult | null {
            const arr = toNumberArray(data);
            let r;
            try {
                r = host.dispatch(arr);
            } catch {
                return recoverDispatch(arr);
            }
            if (r.type === "REQUEST") {
                const result: CodecRequest = {
                    type: "request",
                    name: r.pname ?? "",
                    args: r.result ? (decodeDeep(r.result) as ProtoArgs) : undefined,
                    session: r.session,
                };
                if (r.responseFunc) {
                    const respond = r.responseFunc;
                    result.respond = (a?: ProtoArgs) =>
                        Uint8Array.from(respond((a ? encodeDeep(a) : {}) as ProtoArgs));
                }
                return result;
            }
            // 垃圾字节可能「成功」解出既无 type 也无 session 的包头。
            // 真响应必带 session，这种包按无法解码处理
            if (typeof r.session !== "number") {
                return null;
            }
            return {
                type: "response",
                session: r.session,
                args: r.result ? (decodeDeep(r.result) as ProtoArgs) : undefined,
            };
        },

        checksum,
    };
}
