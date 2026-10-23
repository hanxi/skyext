import { describe, expect, test } from "bun:test";
import {
    byteStringToText,
    fromBytes,
    fromNumberArray,
    fromText,
    textToByteString,
    toBytes,
    toNumberArray,
    toText,
} from "./bin.js";

describe("bin", () => {
    test("latin1 roundtrip covers all 256 byte values", () => {
        const all = new Uint8Array(256);
        for (let i = 0; i < 256; i++) {
            all[i] = i;
        }
        const s = fromBytes(all);
        expect(s.length).toBe(256);
        expect(toBytes(s)).toEqual(all);
    });

    test("random 16-byte nonce survives bytestring roundtrip byte-exact", () => {
        // 服务端 nonce = crypto.random_bytes(16)，任意字节都可能出现
        for (let round = 0; round < 32; round++) {
            const nonce = crypto.getRandomValues(new Uint8Array(16));
            expect(toBytes(fromBytes(nonce))).toEqual(nonce);
        }
    });

    test("utf8 roundtrip with multibyte text", () => {
        const text = "你好🎉 ümlaut mail 邮件";
        expect(toText(fromText(text))).toBe(text);
    });

    test("text <-> bytestring boundary is explicit", () => {
        // "你" = 3 个 UTF-8 字节 → 3 个 latin1 字符
        const bs = textToByteString("你");
        expect(bs.length).toBe(3);
        expect(Array.from(toBytes(bs))).toEqual([0xe4, 0xbd, 0xa0]);
        expect(byteStringToText(bs)).toBe("你");
    });

    test("invalid utf8 decodes to replacement char instead of throwing", () => {
        // 收包路径上抛错会把连接拖下水，替换字符是可接受的降级
        expect(toText(new Uint8Array([0xff, 0xfe]))).toBe("��");
    });

    test("number array helpers", () => {
        expect(toNumberArray(new Uint8Array([1, 2, 255]))).toEqual([1, 2, 255]);
        expect(fromNumberArray([1, 2, 255])).toEqual(new Uint8Array([1, 2, 255]));
    });

    test("fromBytes accepts number[] (sproto binary 字段的形态)", () => {
        expect(toBytes(fromBytes([0, 128, 255]))).toEqual(new Uint8Array([0, 128, 255]));
    });
});
