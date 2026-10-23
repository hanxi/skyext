// account.test.ts —— AccountClient 语义测试（fake fetch），与
// sdk/lua/skyext/client/account.test.lua 同一基线：hosts 轮换、Bearer 头、
// 业务错误 vs 传输错误的区分、int64 rid 精度。
import { afterEach, describe, expect, test } from "bun:test";
import { AccountClient } from "./account.js";

interface RecordedCall {
    url: string;
    method: string;
    headers: Record<string, string>;
    body: string | null;
}

/** route 返回 null = 传输失败（fetch reject）；否则按 status/text 应答 */
function stubFetch(route: (url: string) => { status?: number; text?: string } | null) {
    const calls: RecordedCall[] = [];
    const impl = (async (input: string | URL | Request, init?: RequestInit) => {
        const url = String(input);
        calls.push({
            url,
            method: init?.method ?? "GET",
            headers: { ...(init?.headers as Record<string, string> | undefined) },
            body: typeof init?.body === "string" ? init.body : null,
        });
        const r = route(url);
        if (!r) {
            throw new Error(`connection refused: ${url}`);
        }
        return new Response(r.text ?? "", { status: r.status ?? 200 });
    }) as typeof fetch;
    return { calls, impl };
}

// AccountClient 的起点 cursor 是随机的；轮换测试需要确定性的起点
let origRandom: (() => number) | null = null;
function fixRandom(v: number): void {
    origRandom = Math.random;
    Math.random = () => v;
}
afterEach(() => {
    if (origRandom) {
        Math.random = origRandom;
        origRandom = null;
    }
});

describe("account", () => {
    test("devLogin POSTs {account} 并返回 token", async () => {
        const { calls, impl } = stubFetch((url) =>
            url.endsWith("/dev_login") ? { text: '{"code":0,"token":"tok-123"}' } : null,
        );
        const acc = new AccountClient({ hosts: ["http://h1"], fetchImpl: impl });
        expect(await acc.devLogin("dev1")).toBe("tok-123");
        expect(calls.length).toBe(1);
        expect(calls[0].method).toBe("POST");
        expect(calls[0].headers["content-type"]).toBe("application/json");
        expect(JSON.parse(calls[0].body!)).toEqual({ account: "dev1" });
    });

    test("token 只走 Authorization 头，绝不出现在 URL", async () => {
        const { calls, impl } = stubFetch(() => ({ text: '{"code":0,"roles":[]}' }));
        const acc = new AccountClient({ hosts: ["http://h1"], fetchImpl: impl });
        await acc.roles("secret.token.value");
        expect(calls[0].headers.authorization).toBe("Bearer secret.token.value");
        expect(calls[0].url).not.toContain("secret");
        expect(calls[0].url).not.toContain("token=");
    });

    test("roles 支持可选 server 查询参数", async () => {
        const { calls, impl } = stubFetch(() => ({ text: '{"code":0,"roles":[]}' }));
        const acc = new AccountClient({ hosts: ["http://h1"], fetchImpl: impl });
        await acc.roles("tok", "s1");
        expect(calls[0].url).toBe("http://h1/roles?server=s1");
    });

    test("传输失败/非 200 换下一台，直到拿到有效响应", async () => {
        fixRandom(0); // cursor 从 hosts[0] 开始
        const { calls, impl } = stubFetch((url) => {
            if (url.startsWith("http://bad1")) return null; // 传输失败
            if (url.startsWith("http://bad2")) return { status: 502, text: "bad gateway" };
            return { text: '{"code":0,"token":"tok-ok"}' };
        });
        const acc = new AccountClient({
            hosts: ["http://bad1", "http://bad2", "http://good"],
            fetchImpl: impl,
        });
        expect(await acc.devLogin("dev1")).toBe("tok-ok");
        expect(calls.map((c) => new URL(c.url).host)).toEqual(["bad1", "bad2", "good"]);
    });

    test("下一次请求从轮换后的 cursor 继续（负载分摊）", async () => {
        fixRandom(0);
        const { calls, impl } = stubFetch(() => ({ text: '{"code":0,"servers":[]}' }));
        const acc = new AccountClient({ hosts: ["http://h1", "http://h2"], fetchImpl: impl });
        await acc.servers();
        await acc.servers();
        expect(calls.map((c) => new URL(c.url).host)).toEqual(["h1", "h2"]);
    });

    test("业务错误（code ≠ 0）是有效应答：不轮换，方法返回 null", async () => {
        const { calls, impl } = stubFetch(() => ({ text: '{"code":101,"msg":"token error"}' }));
        const acc = new AccountClient({
            hosts: ["http://h1", "http://h2"],
            fetchImpl: impl,
        });
        expect(await acc.devLogin("dev1")).toBeNull();
        expect(calls.length).toBe(1); // 200 + 合法 JSON = 拿到了应答，不换机器
    });

    test("全部 host 失败返回 null", async () => {
        const { impl } = stubFetch(() => null);
        const acc = new AccountClient({ hosts: ["http://h1", "http://h2"], fetchImpl: impl });
        expect(await acc.servers()).toBeNull();
        expect(await acc.gates()).toBeNull();
    });

    test("int64 rid 解析为精确 bigint（裸 JSON.parse 会丢精度）", async () => {
        const { impl } = stubFetch((url) =>
            url.includes("/roles")
                ? { text: '{"code":0,"roles":[{"rid":70067467908940524,"server":"s1","name":"r1"}]}' }
                : null,
        );
        const acc = new AccountClient({ hosts: ["http://h1"], fetchImpl: impl });
        const roles = await acc.roles("tok");
        expect(roles![0].rid).toBe(70067467908940524n);
        expect(roles![0].rid.toString()).toBe("70067467908940524");
    });

    test("pickRecommendedServer：recommended 优先，否则取第一个", async () => {
        const withRec = stubFetch(() => ({
            text: '{"code":0,"servers":[{"server":"s1","name":"一","status":"open"},{"server":"s2","name":"二","status":"open","recommended":true}]}',
        }));
        const acc1 = new AccountClient({ hosts: ["http://h1"], fetchImpl: withRec.impl });
        expect(await acc1.pickRecommendedServer()).toBe("s2");

        const noRec = stubFetch(() => ({
            text: '{"code":0,"servers":[{"server":"s1","name":"一","status":"open"},{"server":"s2","name":"二","status":"open"}]}',
        }));
        const acc2 = new AccountClient({ hosts: ["http://h1"], fetchImpl: noRec.impl });
        expect(await acc2.pickRecommendedServer()).toBe("s1");

        const empty = stubFetch(() => ({ text: '{"code":0,"servers":[]}' }));
        const acc3 = new AccountClient({ hosts: ["http://h1"], fetchImpl: empty.impl });
        expect(await acc3.pickRecommendedServer()).toBeNull();
    });

    test("ensureRole：有角色取第一个，没有才建", async () => {
        const has = stubFetch((url) =>
            url.includes("/roles")
                ? { text: '{"code":0,"roles":[{"rid":7,"server":"s1","name":"old"}]}' }
                : null,
        );
        const acc1 = new AccountClient({ hosts: ["http://h1"], fetchImpl: has.impl });
        expect((await acc1.ensureRole("tok", "new", "s1"))!.name).toBe("old");
        expect(has.calls.some((c) => c.url.includes("/create_role"))).toBe(false);

        const none = stubFetch((url) => {
            if (url.includes("/roles")) return { text: '{"code":0,"roles":[]}' };
            if (url.includes("/create_role"))
                return { text: '{"code":0,"role":{"rid":70067467908940524,"server":"s1","name":"new"}}' };
            return null;
        });
        const acc2 = new AccountClient({ hosts: ["http://h1"], fetchImpl: none.impl });
        const created = await acc2.ensureRole("tok", "new", "s1");
        expect(created!.name).toBe("new");
        expect(created!.rid).toBe(70067467908940524n);
        const createCall = none.calls.find((c) => c.url.includes("/create_role"))!;
        expect(createCall.headers.authorization).toBe("Bearer tok");
        expect(JSON.parse(createCall.body!)).toEqual({ server: "s1", name: "new" });
    });

    test("cjson 把空 Lua 表编码成 {}：空 roles/servers/gates 认成空列表而不是失败", async () => {
        const { impl } = stubFetch((url) => {
            if (url.includes("/roles")) return { text: '{"code":0,"roles":{}}' };
            if (url.includes("/servers")) return { text: '{"code":0,"servers":{}}' };
            if (url.includes("/gates")) return { text: '{"code":0,"gates":{}}' };
            return null;
        });
        const acc = new AccountClient({ hosts: ["http://h1"], fetchImpl: impl });
        expect(await acc.roles("tok")).toEqual([]);
        expect(await acc.servers()).toEqual([]);
        expect(await acc.gates()).toEqual([]);
        expect(await acc.pickRecommendedServer()).toBeNull();
    });

    test("gates 返回在线网关列表", async () => {
        const { impl } = stubFetch(() => ({
            text: '{"code":0,"gates":[{"node":"role1","tcp_addr":"127.0.0.1:7012","ws_url":"ws://127.0.0.1:7013","weight":1}]}',
        }));
        const acc = new AccountClient({ hosts: ["http://h1"], fetchImpl: impl });
        const gates = await acc.gates();
        expect(gates!.length).toBe(1);
        expect(gates![0].ws_url).toBe("ws://127.0.0.1:7013");
    });

    test("hosts 为空直接抛错（配置错误要立刻暴露）", () => {
        expect(() => new AccountClient({ hosts: [] })).toThrow();
    });
});
