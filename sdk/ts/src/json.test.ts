// int64 安全 JSON 解析。rid 是 17 位 int64（> 2^53），裸 JSON.parse 会静默丢精度：
// JSON.parse('{"rid":70067467908940524}').rid === 70067467908940520（错）。
// 这里验证 parseJson 把它还原成精确的 bigint，且不误伤字符串内容与浮点数。
import { describe, expect, test } from "bun:test";
import { parseJson, quoteUnsafeIntegers } from "./json.js";

describe("json int64", () => {
    test("unsafe integer becomes exact bigint", () => {
        const v = parseJson('{"rid":70067467908940524}') as { rid: bigint };
        expect(v.rid).toBe(70067467908940524n);
    });

    test("naive JSON.parse would corrupt it (guard against regression)", () => {
        // 注意：测试源码里的 70067467908940524 number 字面量本身已被 float64
        // 腐蚀，只能用字符串对比才能看出差别
        const naive = JSON.parse('{"rid":70067467908940524}').rid as number;
        expect(naive.toString()).not.toBe("70067467908940524");
        const v = parseJson('{"rid":70067467908940524}') as { rid: bigint };
        expect(v.rid.toString()).toBe("70067467908940524");
    });

    test("safe integers stay number", () => {
        const v = parseJson('{"a":9007199254740991,"b":0,"c":-5,"d":1000000000000000}') as Record<
            string,
            unknown
        >;
        expect(v.a).toBe(9007199254740991);
        expect(typeof v.a).toBe("number");
        expect(v.b).toBe(0);
        expect(v.c).toBe(-5);
        expect(v.d).toBe(1000000000000000);
    });

    test("negative unsafe integer becomes bigint", () => {
        const v = parseJson('{"v":-70067467908940524}') as { v: bigint };
        expect(v.v).toBe(-70067467908940524n);
    });

    test("floats and exponents are untouched", () => {
        const v = parseJson('{"f":1.5,"e":1e300,"g":-2.5e-8}') as Record<string, number>;
        expect(v.f).toBe(1.5);
        expect(v.e).toBe(1e300);
        expect(v.g).toBe(-2.5e-8);
    });

    test("digits inside strings are not rewritten", () => {
        const text = '{"s":"rid: 70067467908940524, \\"q\\": 99999999999999999999","n":70067467908940524}';
        const v = parseJson(text) as { s: string; n: bigint };
        expect(v.s).toBe('rid: 70067467908940524, "q": 99999999999999999999');
        expect(v.n).toBe(70067467908940524n);
    });

    test("escaped backslash before string end does not desync the scanner", () => {
        const text = '{"s":"ends with backslash\\\\","n":70067467908940524}';
        const v = parseJson(text) as { s: string; n: bigint };
        expect(v.s).toBe("ends with backslash\\");
        expect(v.n).toBe(70067467908940524n);
    });

    test("arrays and nesting", () => {
        const v = parseJson('[70067467908940524,5,{"deep":{"rid":70067467908940525}}]') as [
            bigint,
            number,
            { deep: { rid: bigint } },
        ];
        expect(v[0]).toBe(70067467908940524n);
        expect(v[1]).toBe(5);
        expect(v[2].deep.rid).toBe(70067467908940525n);
    });

    test("/roles style response", () => {
        const text =
            '{"code":0,"roles":[{"rid":70067467908940524,"server":"s1","name":"robot1"}]}';
        const v = parseJson(text) as { code: number; roles: { rid: bigint; server: string; name: string }[] };
        expect(v.code).toBe(0);
        expect(v.roles[0].rid).toBe(70067467908940524n);
        expect(v.roles[0].name).toBe("robot1");
    });

    test("quoteUnsafeIntegers keeps valid json shape", () => {
        const out = quoteUnsafeIntegers('{"a":1,"b":70067467908940524,"c":"70067467908940524"}');
        // 结果必须仍是合法 JSON
        expect(() => JSON.parse(out)).not.toThrow();
        expect(out).toContain('"a":1');
        expect(out).not.toContain('"b":70067467908940524');
        expect(out).toContain('"c":"70067467908940524"');
    });

    test("unicode content passes through", () => {
        const v = parseJson('{"name":"机器人🎉","rid":70067467908940524}') as {
            name: string;
            rid: bigint;
        };
        expect(v.name).toBe("机器人🎉");
        expect(v.rid).toBe(70067467908940524n);
    });
});
