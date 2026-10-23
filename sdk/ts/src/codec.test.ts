// codec 端到端：用仓库里真实的 sproto.spb（./bin/skyext generate proto 产物），
// 两个 Codec 实例分别扮演客户端与服务端，验证 pack/dispatch 全链路。
// 重点盯三处补丁的交界：binary 字段字节精确往返、int64/bigint、UTF-8 文本。
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { loadCodec, type CodecRequest, type CodecResponse } from "./codec.js";

const spbPath = fileURLToPath(new URL("../../../example/build/proto/sproto.spb", import.meta.url));
const spb = new Uint8Array(readFileSync(spbPath));

const client = loadCodec(spb);
const server = loadCodec(spb);

function serverRecv(packed: Uint8Array): CodecRequest {
    const r = server.dispatch(packed);
    expect(r?.type).toBe("request");
    return r as CodecRequest;
}

function clientRecv(packed: Uint8Array): CodecResponse {
    const r = client.dispatch(packed);
    expect(r?.type).toBe("response");
    return r as CodecResponse;
}

describe("codec", () => {
    test("loads real spb, checksum is md5 hex and consistent across instances", () => {
        expect(client.checksum).toMatch(/^[0-9a-f]{32}$/);
        expect(server.checksum).toBe(client.checksum);
    });

    test("truncated spb throws instead of silently mis-decoding", () => {
        // createNew 对尾部个别字节损坏是宽容的（真正的防线是 login 时
        // 双向核对 proto_checksum），但长度对不上必须当场暴露
        expect(() => loadCodec(spb.slice(0, spb.length >> 1))).toThrow();
        expect(() => loadCodec(new Uint8Array(0))).toThrow();
    });

    test("login.ping roundtrip (session 3)", () => {
        const req = serverRecv(client.pack("login.ping", { recv: 6 }, 3));
        expect(req.name).toBe("login.ping");
        expect(req.session).toBe(3);
        expect(req.args).toEqual({ recv: 6 });

        const resp = clientRecv(req.respond!({ sent: 6 }));
        expect(resp.session).toBe(3);
        expect(resp.args).toEqual({ sent: 6 });
    });

    test("login.login: int64 rid stays exact as bigint, binary nonce stays byte-exact", () => {
        const rid = 70067467908940524n; // 17 位，> 2^53，float64 存不下
        const nonce = Array.from(crypto.getRandomValues(new Uint8Array(16)));

        const req = serverRecv(
            client.pack(
                "login.login",
                { token: "jwt.token.value", rid, proto_checksum: client.checksum, server: "s1" },
                1,
            ),
        );
        expect(req.name).toBe("login.login");
        expect(req.args!.rid).toBe(rid);
        expect(req.args!.proto_checksum).toBe(client.checksum);

        const resp = clientRecv(req.respond!({ code: 0, rid, nonce }));
        expect(resp.args!.code).toBe(0);
        expect(resp.args!.rid).toBe(rid); // bigint 精确回来
        expect(resp.args!.nonce).toEqual(nonce); // 16 字节逐个相等
    });

    test("login.resume: nonce rotated, both directions byte-exact (Uint8Array accepted)", () => {
        const rid = 70067467908940525n;
        const oldNonce = crypto.getRandomValues(new Uint8Array(16));
        const newNonce = crypto.getRandomValues(new Uint8Array(16));

        // 编码侧接受 Uint8Array（encodeDeep 转 number[]），随机字节含 0x00/0xff 也无所谓
        const req = serverRecv(client.pack("login.resume", { rid, nonce: oldNonce, recv: 10 }, 2));
        expect(req.args!.rid).toBe(rid);
        expect(req.args!.nonce).toEqual(Array.from(oldNonce));
        expect(req.args!.recv).toBe(10);

        const resp = clientRecv(req.respond!({ code: 0, nonce: newNonce, sent: 10 }));
        expect(resp.args!.nonce).toEqual(Array.from(newNonce));
        expect(resp.args!.sent).toBe(10);
    });

    test("mail.send: UTF-8 text roundtrip incl. emoji (codec boundary does the conversion)", () => {
        const req = serverRecv(
            client.pack("mail.send", { to_rid: 5, title: "你好🎉", content: "测试邮件 ✓ ümlaut" }, 7),
        );
        expect(req.name).toBe("mail.send");
        expect(req.args!.title).toBe("你好🎉");
        expect(req.args!.content).toBe("测试邮件 ✓ ümlaut");
        expect(clientRecv(req.respond!({ code: 0 })).args).toEqual({ code: 0 });
    });

    test("mail.list: nested structs and arrays", () => {
        // 空 request {} 也要能打包
        const req = serverRecv(client.pack("mail.list", {}, 9));
        expect(req.args ?? {}).toEqual({});
        const mails = [
            {
                mail_id: 1001,
                title: "奖励",
                content: "你好🎉",
                send_time: 1760000000000,
                sender: { rid: 70067467908940524n, name: "机器人" },
                attach: [{ res_type: 1, res_id: 2, res_size: 30 }],
            },
            // 缺失的数组字段解码后是空数组（与 C sproto 的 decode_empty_array
            // 行为一致），缺失的结构体字段才是真的缺省
            { mail_id: 1002, title: "系统", content: "维护公告", send_time: 1760000000001, attach: [] },
        ];
        const resp = clientRecv(req.respond!({ code: 0, mails }));
        expect(resp.args!.mails).toEqual(mails);
    });

    test("duplicate response: second dispatch yields {type:'response', session} with args undefined", () => {
        // 续接后服务端可能重发同一 request id 的回包。类型信息已被第一份消费，
        // host.dispatch 会抛错，codec 必须认出 session 让会话层去计数丢弃（义务 2）
        const req = serverRecv(client.pack("mail.claim", { mail_id: 42 }, 11));
        const bytes = req.respond!({ code: 0 });

        const first = clientRecv(bytes);
        expect(first.session).toBe(11);
        expect(first.args).toEqual({ code: 0 });

        const second = client.dispatch(bytes);
        expect(second?.type).toBe("response");
        expect((second as CodecResponse).session).toBe(11);
        expect((second as CodecResponse).args).toBeUndefined();
    });

    test("garbage bytes dispatch to null, not an exception", () => {
        const cases: Uint8Array[] = [
            new Uint8Array(0),
            new Uint8Array([0xff]),
            new Uint8Array([0xff, 0xff, 0xff]),
            Uint8Array.from({ length: 64 }, (_, i) => (i * 37 + 11) & 0xff),
        ];
        for (const c of cases) {
            expect(client.dispatch(c)).toBeNull();
        }
    });

    test("int32 negatives roundtrip (regression: expand64 must sign-extend)", () => {
        // C sproto 把 int32 范围内的负数编成 4 字节补码，上游 JS 解码不符号扩展，
        // -5 会解成 4294967291。补丁后必须精确还原
        for (const score of [-5, -1, -2147483648, 0, 2147483647]) {
            const req = serverRecv(client.pack("rank.submit", { score }, 12));
            expect(req.args!.score).toBe(score);
        }
    });

    test("int64 boundary: 2^53 stays number, beyond becomes bigint, negatives two's-complement", () => {
        const cases: (number | bigint)[] = [
            9007199254740991, // 2^53 - 1
            9007199254740992, // 2^53
            9007199254740993n, // 2^53 + 1 → bigint
            70067467908940524n,
            -9007199254740993n,
            9223372036854775807n, // int64 max
            -9223372036854775808n, // int64 min
        ];
        for (const score of cases) {
            const req = serverRecv(client.pack("rank.submit", { score }, 13));
            const got = req.args!.score;
            if (typeof score === "bigint") {
                expect(got).toBe(score);
            } else {
                // 2^53 编成 8 字节后解回来也是精确值；约定 |v| ≤ 2^53 给 number
                expect(typeof got === "bigint" ? Number(got) : got).toBe(score);
            }
        }
    });

    test("server-initiated request without session still dispatches as request", () => {
        // 客户端也可能要解服务端主动发起的请求；respond 只在带 session 时出现
        const bytes = server.pack("login.ping", { recv: 1 }); // 不传 session
        const r = client.dispatch(bytes);
        expect(r?.type).toBe("request");
        expect((r as CodecRequest).name).toBe("login.ping");
        expect((r as CodecRequest).session).toBeUndefined();
        expect((r as CodecRequest).respond).toBeUndefined();
    });
});
