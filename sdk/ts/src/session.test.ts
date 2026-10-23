// session.test.ts —— sdk/lua/skyext/client/session.test.lua 的移植（同一基线的
// 双实现互证），钉住的是**协议语义**：下行怎么计数、续接怎么重发在途请求、对账
// 对不上怎么办。写错了不会报错，只会在断线重连之后悄悄错位。
//
// fake transport + fake codec：包就是 { kind, name, reqId, body } 的 JSON 文本，
// 不做真的编解码——这里测计数和重发，不测 sproto（真 spb 在 codec.test.ts），
// 也不测真 socket（E2E 在 test/e2e/，由 SKYEXT_E2E=1 门控）。
import { describe, expect, test } from "bun:test";
import { SessionClient } from "./session.js";
import type { Codec } from "./codec.js";
import type { Endpoint, Transport, TransportConn } from "./transport.js";
import { ErrCode } from "./errcode.js";
import type { ProtoArgs } from "./types.js";
import { fromText, toText } from "./bin.js";

const URL = "ws://127.0.0.1:7013";
const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

interface FakePacket {
    kind: "REQUEST" | "RESPONSE";
    name?: string;
    reqId?: number;
    body?: ProtoArgs;
}

// ---------------------------------------------------------------- fake codec

const fakeCodec: Codec = {
    pack(name: string, args?: ProtoArgs, session?: number): Uint8Array {
        const packet: FakePacket = { kind: "REQUEST", name, reqId: session, body: args };
        return fromText(JSON.stringify(packet));
    },
    dispatch(bytes: Uint8Array) {
        let packet: FakePacket;
        try {
            packet = JSON.parse(toText(bytes)) as FakePacket;
        } catch {
            return null; // 解不开码 → 会话层照样计数（义务 2）
        }
        if (packet.kind === "REQUEST") {
            return { type: "request" as const, name: packet.name ?? "", args: packet.body };
        }
        return { type: "response" as const, session: packet.reqId!, args: packet.body };
    },
    checksum: "fake-checksum",
};

// ------------------------------------------------------------- fake harness

class FakeConn implements TransportConn {
    open = true;
    private messageCbs: ((bytes: Uint8Array) => void)[] = [];
    private closedCbs: (() => void)[] = [];

    constructor(
        readonly id: number,
        private h: Harness,
    ) {}

    send(bytes: Uint8Array): void {
        if (!this.open) {
            throw new Error("connection closed");
        }
        this.h.writes.push({ conn: this, packet: JSON.parse(toText(bytes)) as FakePacket });
    }

    close(): void {
        this.open = false;
    }

    onMessage(cb: (bytes: Uint8Array) => void): void {
        this.messageCbs.push(cb);
    }

    onClosed(cb: () => void): void {
        this.closedCbs.push(cb);
    }

    /** 测试侧：给会话投一个下行包（事件式，立即触发回调） */
    deliver(bytes: Uint8Array): void {
        for (const cb of this.messageCbs) {
            cb(bytes);
        }
    }

    /** 测试侧：模拟迟到的断开通知 */
    fireClosed(): void {
        this.open = false;
        for (const cb of this.closedCbs) {
            cb();
        }
    }
}

interface Harness {
    writes: { conn: FakeConn; packet: FakePacket }[];
    conns: FakeConn[];
    states: string[];
    pushes: { name: string; args?: ProtoArgs }[];
    connectFail: boolean;
    loginParam: LoginParamStub;
    session: SessionClient;
    current(): FakeConn;
    last(): FakePacket | undefined;
    sent(name: string): FakePacket;
    reply(reqId: number, body?: ProtoArgs): void;
    pushMsg(name: string, body?: ProtoArgs): void;
    settle(ms?: number): Promise<void>;
    login(nonce?: unknown): Promise<{ started: boolean }>;
    call(name: string, body?: ProtoArgs): Promise<ProtoArgs | null>;
    dropAndResume(resp: ProtoArgs): Promise<void>;
}

type LoginParamStub = ProtoArgs | null;

function harness(): Harness {
    const h = {
        writes: [] as { conn: FakeConn; packet: FakePacket }[],
        conns: [] as FakeConn[],
        states: [] as string[],
        pushes: [] as { name: string; args?: ProtoArgs }[],
        connectFail: false,
        loginParam: { token: "tok", rid: 1 } as LoginParamStub,
        session: null as unknown as SessionClient,
    } as Harness;

    const transport: Transport = {
        async connect(endpoint: Endpoint): Promise<TransportConn> {
            expect(endpoint.url).toBe(URL);
            if (h.connectFail) {
                throw new Error("connection refused");
            }
            const conn = new FakeConn(h.conns.length + 1, h);
            h.conns.push(conn);
            return conn;
        },
    };

    h.session = new SessionClient({
        resolveEndpoints: () => [{ url: URL }],
        transport,
        codec: fakeCodec,
        loginParam: () => h.loginParam,
        handshakeTimeoutMs: 200,
        reconnectDelayMs: 20,
        pingIntervalMs: 60_000, // 语义测试里让心跳保持安静
        onPush: (name, args) => h.pushes.push({ name, args }),
        onState: (state) => h.states.push(state),
    });

    h.current = () => h.conns[h.conns.length - 1];
    h.last = () => h.writes[h.writes.length - 1]?.packet;
    h.sent = (name: string) => {
        for (let i = h.writes.length - 1; i >= 0; i--) {
            if (h.writes[i].packet.name === name) {
                return h.writes[i].packet;
            }
        }
        throw new Error(`no ${name} was sent`);
    };
    h.reply = (reqId: number, body?: ProtoArgs) => {
        const packet: FakePacket = { kind: "RESPONSE", reqId, body };
        h.current().deliver(fromText(JSON.stringify(packet)));
    };
    h.pushMsg = (name: string, body?: ProtoArgs) => {
        const packet: FakePacket = { kind: "REQUEST", name, body };
        h.current().deliver(fromText(JSON.stringify(packet)));
    };
    h.settle = (ms = 60) => sleep(ms);

    // 起会话并应答它的 login。start 会阻塞在握手上，所以先挂着再回包
    h.login = async (nonce: unknown = "n1") => {
        const startedP = h.session.start();
        await h.settle();
        h.reply(h.sent("login.login").reqId!, { code: ErrCode.OK, rid: 1, nonce });
        return { started: await startedP };
    };

    // 业务请求：发出去、拿到回包，中间要让出去等响应
    h.call = async (name: string, body?: ProtoArgs) => {
        const p = h.session.call(name);
        await h.settle();
        h.reply(h.sent(name).reqId!, body ?? { code: ErrCode.OK });
        return p;
    };

    // 断线并应答重连时的 resume
    h.dropAndResume = async (resp: ProtoArgs) => {
        h.session.reconnect();
        await h.settle();
        h.reply(h.sent("login.resume").reqId!, resp);
        await h.settle();
    };

    return h;
}

// ------------------------------------------------------------------- 用例

describe("client.session 登录", () => {
    test("登录成功后记下凭据，下行计数从 0 开始", async () => {
        const h = harness();
        const { started } = await h.login("nonce-a");
        const s = h.session;
        expect(started).toBe(true);
        expect(s.online).toBe(true);
        expect(s.nonce).toBe("nonce-a");
        expect(s.rid).toBe(1);
        // 登录响应由登录服务直写 socket，根本没经过服务端的会话层，不能计数
        expect(s.recv).toBe(0);
        s.close();
    });

    test("登录被拒时不置为在线，也不记凭据", async () => {
        const h = harness();
        const startedP = h.session.start();
        await h.settle();
        h.reply(h.sent("login.login").reqId!, { code: 101 }); // TOKEN_ERROR：项目扩展错误码
        const started = await startedP;
        expect(started).toBe(false);
        expect(h.session.online).toBe(false);
        expect(h.session.nonce).toBeNull();
        h.session.close();
    });
});

describe("client.session 下行计数", () => {
    test("业务回包和服务端推送都计数", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        await h.call("bag.get_bag");
        expect(s.recv).toBe(1);
        h.pushMsg("mail.new", { mail_id: 7 });
        await h.settle(10);
        expect(s.recv).toBe(2);
        expect(h.pushes[0].name).toBe("mail.new");
        s.close();
    });

    test("ping 的回包不计数：它是传输层握手，在计数边界之外", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        await h.call("bag.get_bag");
        const pingP = s.request("login.ping", { recv: s.recv }, 5000);
        await h.settle(10);
        h.reply(h.sent("login.ping").reqId!, { sent: 1 });
        expect(await pingP).toEqual({ sent: 1 });
        expect(s.recv).toBe(1);
        s.close();
    });

    test("解不开码的下行包也计数：服务端发出时计了数", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        h.current().deliver(fromText("这不是一个能解码的包"));
        await h.settle(10);
        expect(s.recv).toBe(1);
        s.close();
    });
});

describe("client.session 续接", () => {
    test("带上 nonce 和已收计数续接，成功后轮换凭据", async () => {
        const h = harness();
        await h.login("nonce-a");
        const s = h.session;
        await h.call("bag.get_bag");
        await h.dropAndResume({ code: ErrCode.OK, nonce: "nonce-b", sent: 1 });

        const req = h.sent("login.resume");
        expect(req.body).toEqual({ rid: 1, nonce: "nonce-a", recv: 1 });
        expect(s.nonce).toBe("nonce-b");
        expect(s.online).toBe(true);
        // 续接的响应同样不计数
        expect(s.recv).toBe(1);
        s.close();
    });

    test("续接成功后用原 request id 重发在途请求，服务端才认得出是同一个", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        let answered = false;
        let ret: ProtoArgs | null = null;
        const p = s.call("bag.use_item", { id: 1 }).then((v) => {
            answered = true;
            ret = v;
        });
        await h.settle();
        const original = h.sent("bag.use_item").reqId!;

        await h.dropAndResume({ code: ErrCode.OK, nonce: "nonce-b", sent: 0 });
        const resent = h.last()!;
        expect(resent.name).toBe("bag.use_item");
        expect(resent.reqId).toBe(original);
        // 业务调用没有超时，它一直等着，正是续接机制存在的意义
        expect(answered).toBe(false);

        h.reply(original, { code: ErrCode.OK });
        await p;
        // 断言用 cast 绕开 TS 对流量的窄化：赋值发生在 then 回调里，编译器不追踪
        expect(ret as ProtoArgs | null).toEqual({ code: ErrCode.OK });
        s.close();
    });

    test("重发后收到两份响应时，认领一份、另一份计数后丢掉", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        void s.call("bag.use_item", { id: 1 });
        await h.settle();
        const original = h.sent("bag.use_item").reqId!;

        // 断线前服务端其实已经回过一次，这份在重放流里；重发命中幂等缓存又回一次。
        // 服务端两份都计了，客户端只认领得了一份——另一份要是不计数，recv 就永久少一
        await h.dropAndResume({ code: ErrCode.OK, nonce: "nonce-b", sent: 0 });
        h.reply(original, { code: ErrCode.OK });
        await h.settle(10);
        expect(s.recv).toBe(1);
        h.reply(original, { code: ErrCode.OK });
        await h.settle(10);
        expect(s.recv).toBe(2);
        s.close();
    });

    test("续接被拒时退化成完整登录，计数清零、在途请求全部失败", async () => {
        const h = harness();
        await h.login("nonce-a");
        const s = h.session;
        await h.call("bag.get_bag");
        let answered = false;
        let ret: unknown = "unset";
        void s.call("bag.use_item", { id: 1 }).then((v) => {
            answered = true;
            ret = v;
        });
        await h.settle();

        s.reconnect();
        await h.settle();
        h.reply(h.sent("login.resume").reqId!, { code: ErrCode.RESUME_UNAVAILABLE });
        await h.settle();
        h.reply(h.sent("login.login").reqId!, { code: ErrCode.OK, rid: 1, nonce: "nonce-c" });
        await h.settle();

        expect(s.online).toBe(true);
        expect(s.nonce).toBe("nonce-c");
        expect(s.recv).toBe(0);
        // 会话状态在服务端已经没了，在途请求不能继续等下去
        expect(answered).toBe(true);
        expect(ret).toBeNull();
        expect(h.states).toContain("relogin");
        s.close();
    });

    test("没有凭据时直接走登录，不发 resume", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        s.invalidateNonce();
        const before = h.writes.length;
        s.reconnect();
        await h.settle();
        expect(h.writes.length).toBeGreaterThan(before);
        for (const w of h.writes.slice(before)) {
            expect(w.packet.name).toBe("login.login");
        }
        s.close();
    });
});

describe("client.session 连接管理", () => {
    test("迟到的断开通知不影响已经建好的新连接", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        const stale = h.conns[0];
        await h.dropAndResume({ code: ErrCode.OK, nonce: "nonce-b", sent: 0 });
        expect(h.conns.length).toBe(2);

        stale.fireClosed(); // 旧连接迟到的断开通知
        await h.settle();
        expect(h.conns.length).toBe(2); // 没有误杀新连接、没有触发重连
        expect(s.online).toBe(true);
        expect(s.nonce).toBe("nonce-b");
        s.close();
    });

    test("close 之后不再重连，等待中的请求立刻放行", async () => {
        const h = harness();
        await h.login();
        const s = h.session;
        let answered = false;
        void s.call("bag.use_item", { id: 1 }).then(() => {
            answered = true;
        });
        await h.settle();

        s.close();
        await h.settle(10);
        expect(answered).toBe(true);
        expect(s.online).toBe(false);

        // 不再重连
        const conns = h.conns.length;
        const writes = h.writes.length;
        await h.settle(120);
        expect(h.conns.length).toBe(conns);
        expect(h.writes.length).toBe(writes);
    });
});
