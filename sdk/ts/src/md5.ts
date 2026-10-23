// 纯 TS 的 md5（RFC 1321），输出 hex。用于 proto_checksum：
// 服务端算法是 service/sproto_loader.lua 的 md5.sumhexa(spb 文件字节)，
// login.login 时两端必须逐字符一致，否则服务端拒绝登录（PROTO_CHECKSUM）。
// 浏览器/小程序环境没有 Node crypto，所以自带实现；spb 只有几十 KB，性能足够。

// 每轮的循环左移位数
const S = [
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
];

// K[i] = floor(2^32 * |sin(i+1)|)，与 RFC 1321 附录里的常数表逐项一致
const K = new Int32Array(64);
for (let i = 0; i < 64; i++) {
    K[i] = Math.floor(Math.abs(Math.sin(i + 1)) * 0x100000000) | 0;
}

/** md5 摘要，16 字节 */
export function md5(data: Uint8Array): Uint8Array {
    const origLen = data.length;
    // 补齐规则：追加 0x80，再补 0 至长度 ≡ 56 (mod 64)，最后 8 字节放原始 bit 长度（小端）
    const paddedLen = (((origLen + 8) >>> 6) + 1) << 6;
    const m = new Uint8Array(paddedLen);
    m.set(data);
    m[origLen] = 0x80;
    const view = new DataView(m.buffer);
    // setUint32 自动模 2^32，低 32 位 = origLen*8 mod 2^32；高 32 位 = floor(origLen / 2^29)
    view.setUint32(paddedLen - 8, origLen * 8, true);
    view.setUint32(paddedLen - 4, Math.floor(origLen / 0x20000000), true);

    let a0 = 0x67452301;
    let b0 = 0xefcdab89;
    let c0 = 0x98badcfe;
    let d0 = 0x10325476;
    const w = new Int32Array(16);

    for (let off = 0; off < paddedLen; off += 64) {
        for (let i = 0; i < 16; i++) {
            w[i] = view.getInt32(off + i * 4, true);
        }
        let a = a0;
        let b = b0;
        let c = c0;
        let d = d0;
        for (let i = 0; i < 64; i++) {
            let f: number;
            let g: number;
            if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) & 15;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) & 15;
            } else {
                f = c ^ (b | ~d);
                g = (7 * i) & 15;
            }
            f = (f + a + K[i] + w[g]) | 0;
            a = d;
            d = c;
            c = b;
            b = (b + ((f << S[i]) | (f >>> (32 - S[i])))) | 0;
        }
        a0 = (a0 + a) | 0;
        b0 = (b0 + b) | 0;
        c0 = (c0 + c) | 0;
        d0 = (d0 + d) | 0;
    }

    const out = new Uint8Array(16);
    const ov = new DataView(out.buffer);
    ov.setInt32(0, a0, true);
    ov.setInt32(4, b0, true);
    ov.setInt32(8, c0, true);
    ov.setInt32(12, d0, true);
    return out;
}

/** md5 摘要的 hex 字符串（小写，与服务端 md5.sumhexa 输出一致） */
export function md5Hex(data: Uint8Array): string {
    let s = "";
    const digest = md5(data);
    for (let i = 0; i < 16; i++) {
        s += digest[i].toString(16).padStart(2, "0");
    }
    return s;
}
