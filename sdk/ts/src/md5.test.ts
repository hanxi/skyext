// md5 测试向量：RFC 1321 附录 + 补块边界长度（55/56/63/64/65/119/120 字节，
// 覆盖「追加 0x80 与 8 字节长度后是否跨块」的临界情形）。
// 边界向量已用服务端同款实现核对：./bin/lua + skynet/lualib/md5.lua 的 md5.sumhexa。
// spb 文件的 checksum 对账不在这里做——proto 每次重新生成都会变，真正的对账点是
// E2E：login.login 带上 proto_checksum，服务端用 md5.sumhexa 逐字符校验。
import { describe, expect, test } from "bun:test";
import { md5, md5Hex } from "./md5.js";
import { fromText } from "./bin.js";

function hex(s: string): string {
    return md5Hex(fromText(s));
}

describe("md5", () => {
    test("RFC 1321 test suite", () => {
        expect(hex("")).toBe("d41d8cd98f00b204e9800998ecf8427e");
        expect(hex("a")).toBe("0cc175b9c0f1b6a831c399e269772661");
        expect(hex("abc")).toBe("900150983cd24fb0d6963f7d28e17f72");
        expect(hex("message digest")).toBe("f96b697d7cb7938d525a2f31aaf161d0");
        expect(hex("abcdefghijklmnopqrstuvwxyz")).toBe("c3fcd3d76192e4007dfb496cca67e13b");
        expect(hex("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")).toBe(
            "d174ab98d277d9f5a5611c2c9f419d9f",
        );
        expect(hex("12345678901234567890123456789012345678901234567890123456789012345678901234567890")).toBe(
            "57edf4a22be3c955ac49da2e2107b67a",
        );
    });

    test("padding boundary lengths (cross-checked against server md5.sumhexa)", () => {
        expect(hex("a".repeat(55))).toBe("ef1772b6dff9a122358552954ad0df65");
        expect(hex("a".repeat(56))).toBe("3b0c8ac703f828b04c6c197006d17218");
        expect(hex("a".repeat(63))).toBe("b06521f39153d618550606be297466d5");
        expect(hex("a".repeat(64))).toBe("014842d480b571495a4a0363793f7367");
        expect(hex("a".repeat(65))).toBe("c743a45e0d2e6a95cb859adae0248435");
        expect(hex("a".repeat(119))).toBe("8a7bd0732ed6a28ce75f6dabc90e1613");
        expect(hex("a".repeat(120))).toBe("5f61c0ccad4cac44c75ff505e1f1e537");
    });

    test("digest is 16 raw bytes", () => {
        const d = md5(fromText("abc"));
        expect(d.length).toBe(16);
        expect(d[0]).toBe(0x90);
        expect(d[15]).toBe(0x72);
    });

    test("high bytes are hashed as-is (not UTF-8 re-encoded)", () => {
        const raw = new Uint8Array(16);
        for (let i = 0; i < 16; i++) {
            raw[i] = (i * 37 + 11) & 0xff;
        }
        // 同样字节从两条路进来（直接 Uint8Array / 经 latin1 字节串还原）结果必须一致
        const viaByteString = Uint8Array.from(String.fromCharCode(...raw), (c) => c.charCodeAt(0));
        expect(md5Hex(raw)).toBe(md5Hex(viaByteString));
    });
});
