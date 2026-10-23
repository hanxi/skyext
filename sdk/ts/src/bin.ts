// 字节助手。wire 上的 sproto string 字段是字节序列（文本为 UTF-8 字节，binary
// 字段为任意字节），JS 字符串是 UTF-16 码元序列，两组 helper 把转换边界说清楚：
//
//   toBytes / fromBytes   latin1 字节串 ↔ Uint8Array，逐字节无损，wire 层用
//   toText / fromText     UTF-8 ↔ Uint8Array，API 层的业务文本用
//
// vendored sproto（src/sproto/sproto.ts 补丁 1）已做字节透明：它编解码出的
// JS 字符串都是字节串。UTF-8 转换统一发生在 codec.ts 的 API 边界，业务代码
// 不直接接触字节串。

const textEncoder = new TextEncoder();
// fatal=false：服务端 string 字段理应都是合法 UTF-8，真出现非法字节时替换为
// U+FFFD 而不是抛错——收包路径上抛错会把整个连接拖下水
const textDecoder = new TextDecoder();

/** latin1 字节串 → Uint8Array。每个字符只取 charCode 低 8 位，与 fromBytes 互逆 */
export function toBytes(s: string): Uint8Array {
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
        out[i] = s.charCodeAt(i) & 0xff;
    }
    return out;
}

/** Uint8Array / number[] → latin1 字节串（每字节一个字符，charCode ∈ [0,255]） */
export function fromBytes(b: Uint8Array | number[]): string {
    const n = b.length;
    let s = "";
    // 分段 fromCharCode，避免大数组展开实参爆栈
    const CHUNK = 0x8000;
    for (let i = 0; i < n; i += CHUNK) {
        const end = Math.min(i + CHUNK, n);
        const part: number[] = new Array(end - i);
        for (let j = i; j < end; j++) {
            part[j - i] = (b as ArrayLike<number>)[j] & 0xff;
        }
        s += String.fromCharCode(...part);
    }
    return s;
}

/** UTF-8 解码为文本 */
export function toText(b: Uint8Array): string {
    return textDecoder.decode(b);
}

/** 文本按 UTF-8 编码 */
export function fromText(s: string): Uint8Array {
    return textEncoder.encode(s);
}

/** UTF-8 文本 → latin1 字节串（sproto string 字段编码前的形态） */
export function textToByteString(s: string): string {
    return fromBytes(fromText(s));
}

/** latin1 字节串 → UTF-8 文本（sproto string 字段解码后的形态） */
export function byteStringToText(s: string): string {
    return toText(toBytes(s));
}

/** Uint8Array → number[]（vendored sproto 的输入输出都是 number[]） */
export function toNumberArray(b: Uint8Array): number[] {
    return Array.from(b);
}

/** number[] → Uint8Array */
export function fromNumberArray(a: number[]): Uint8Array {
    return Uint8Array.from(a);
}
