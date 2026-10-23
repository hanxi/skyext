// E2E：真服务器全链路，SKYEXT_E2E=1 门控（沿用 SKYTEST_INTEGRATION 约定）。
// 前置：mongo/etcd 已起、account1 + role1 在跑（./bin/skyext serve example），
// example/build/proto/sproto.spb 与服务端一致（./bin/skyext generate proto）。
//
// 覆盖链路：dev_login → /servers → /create_role → /gates → WS 直连 →
// login.login（proto_checksum 双向对账，服务端 proto_checksum_enable = true）→
// role.login_info → 在途请求中 reconnect() → resume 成功（token 不再被调用、
// 凭据轮换）→ 在途请求完成 → close。
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { AccountClient, SkyextClient } from "../../src/index.js";
import type { ProtoArgs, SessionState } from "../../src/types.js";

const E2E = process.env.SKYEXT_E2E === "1";
const describeE2E = E2E ? describe : describe.skip;

const ACCOUNT_HOSTS = [process.env.SKYEXT_ACCOUNT ?? "http://127.0.0.1:8080"];
const spbPath = fileURLToPath(new URL("../../../../example/build/proto/sproto.spb", import.meta.url));

async function waitFor(cond: () => boolean, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
        if (cond()) {
            return;
        }
        await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("waitFor: 超时");
}

describeE2E("skyext-client E2E", () => {
    test(
        "真服务器全链路：login → 业务请求 → 断线续接 → 在途请求完成",
        async () => {
            const spb = new Uint8Array(readFileSync(spbPath));
            const account = new AccountClient({ hosts: ACCOUNT_HOSTS });

            // 1. dev_login 拿 token（唯一账号名，避免撞上已有角色/其他测试）
            const stamp = Date.now();
            const token = await account.devLogin(`ts_e2e_${stamp}`);
            expect(token).toBeTruthy();

            // 2. 选服：recommended 优先
            const server = await account.pickRecommendedServer();
            expect(server).toBeTruthy();

            // 3. 全新账号必然没有角色 → ensureRole 走建角。rid 是 17 位 int64
            const role = await account.ensureRole(token!, `e2e${stamp % 1000000}`, server!);
            expect(role).toBeTruthy();
            expect(role!.rid.toString().length).toBeGreaterThan(10);

            // 4. /gates 网关发现：至少一台开了 ws
            const gates = await account.gates();
            expect(gates).toBeTruthy();
            expect(gates!.some((g) => g.ws_url)).toBe(true);

            // 5. 进游戏：WS 直连 + login.login
            const states: SessionState[] = [];
            let tokenCalls = 0;
            const client = new SkyextClient({
                accountHosts: ACCOUNT_HOSTS,
                spb,
                tokenProvider: () => {
                    tokenCalls += 1;
                    return token!;
                },
                onState: (s) => states.push(s),
                session: { reconnectDelayMs: 100, handshakeTimeoutMs: 5000 },
            });
            const ok = await client.enterGame({ rid: role!.rid, server: server! });
            if (!ok) {
                // CI 冷启动时 gate 的 etcd 注册可能晚端口一拍：supervisor 会持续
                // 重试，等到在线为止（enterGame 失败不抛错是设计行为）
                await waitFor(() => client.online, 15_000);
            }
            expect(client.online).toBe(true);
            expect(tokenCalls).toBe(1);
            expect(client.nonce).toBeTruthy(); // 拿到续接凭据

            // 6. 业务请求：role.login_info 的 rid 必须与 /create_role 返回的精确一致
            //    （int64 全链路：HTTP JSON bigint → sproto bigint → 服务端精确匹配）
            const info = await client.request<{
                code?: number;
                info?: { rid: bigint | number; name: string };
            }>("role.login_info");
            expect(info?.code).toBe(0);
            expect(info!.info!.rid.toString()).toBe(role!.rid.toString());
            expect(info!.info!.name).toBe(role!.name);

            // 7. 在途请求中掐线：request 发出后立刻 reconnect（不 await），
            //    回包要么进重放缓冲、要么命中幂等缓存，总之请求必须完成
            const nonceBefore = Array.from(client.nonce as number[]);
            expect(nonceBefore.length).toBe(16); // crypto.random_bytes(16)
            const inflight = client.request<ProtoArgs>("mail.list");
            client.reconnect();
            const mailResp = await inflight;
            expect(mailResp?.code).toBe(0);
            // 空邮箱时 mails 可能是空数组或缺省（sproto 空数组语义），只断言形态
            if (mailResp?.mails !== undefined) {
                expect(Array.isArray(mailResp.mails)).toBe(true);
            }

            await waitFor(() => client.online, 10_000);

            // 8. 证明走的是 resume 而不是重新 login：
            //    - 凭据轮换（每次成功续接服务端都换新 nonce）
            //    - tokenProvider 没有被再次调用（resume 不验 token）
            //    - 状态机没有第二次进入 relogin
            const nonceAfter = Array.from(client.nonce as number[]);
            expect(nonceAfter.length).toBe(16);
            expect(nonceAfter).not.toEqual(nonceBefore);
            expect(tokenCalls).toBe(1);
            expect(states).toContain("offline");
            expect(states.filter((s) => s === "relogin").length).toBe(1); // 只有首次登录那次

            client.close();
            expect(client.online).toBe(false);

            // close 之后不再重连
            const statesAtClose = states.length;
            await new Promise((resolve) => setTimeout(resolve, 400));
            expect(states.length).toBe(statesAtClose);
        },
        60_000,
    );
});
