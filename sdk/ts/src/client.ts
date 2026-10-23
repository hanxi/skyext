// 门面：account + codec + session 串成「拿 token → 进游戏」一条路。
//
//   const client = new SkyextClient({ accountHosts, spb, tokenProvider });
//   const token = await client.account.devLogin("dev1");        // 或由平台 SDK 签发
//   const role = await client.account.ensureRole(token, name, server);
//   await client.enterGame({ rid: role.rid, server });          // /gates → 轮换建连 → resume 或 login
//   const info = await client.request("role.login_info");
//   client.close();
//
// tokenProvider 是可插拔的：dev_login、gamepass OAuth、平台 SDK 都行——token
// 可能过期，每次完整登录都会重新调用（续接不需要 token）。

import { AccountClient, type AccountOptions } from "./account.js";
import { loadCodec, type Codec } from "./codec.js";
import { SessionClient, type SessionOptions } from "./session.js";
import type { Transport, Endpoint } from "./transport.js";
import type { ProtoArgs, SessionState } from "./types.js";

export interface SkyextClientOptions {
    /** Account 服务地址列表 */
    accountHosts: string[];
    /** sproto.spb 二进制（./bin/skyext generate proto 的产物） */
    spb: Uint8Array;
    /** 返回登录 token。每次完整登录调用一次；续接不调用 */
    tokenProvider: () => string | Promise<string>;
    /** fetch 实现注入（透传给 AccountClient） */
    fetchImpl?: typeof fetch;
    /** 传输实现注入（默认 wsTransport；小程序传自定义适配） */
    transport?: Transport;
    onPush?: (name: string, args?: ProtoArgs) => void;
    onState?: (state: SessionState) => void;
    /** 会话层调参（心跳/超时/重连间隔），缺省值见 SessionOptions */
    session?: Pick<
        SessionOptions,
        "pingIntervalMs" | "pingTolerance" | "reconnectDelayMs" | "handshakeTimeoutMs"
    >;
}

export interface EnterGameOptions {
    /** 角色 id（account 的 /roles、/create_role 返回；超 2^53 时是 bigint） */
    rid: bigint | number;
    /** 角色的出生服。login.login 报的 server 必须是出生服 */
    server: string;
}

export class SkyextClient {
    /** Account HTTP 层（servers / roles / gates / devLogin），可单独使用 */
    readonly account: AccountClient;
    /** sproto 编解码器；checksum 即 login.login 的 proto_checksum */
    readonly codec: Codec;

    private opts: SkyextClientOptions;
    private session: SessionClient | null = null;
    private loginRid: bigint | number = 0;
    private loginServer = "";

    constructor(opts: SkyextClientOptions) {
        this.opts = opts;
        this.account = new AccountClient({
            hosts: opts.accountHosts,
            fetchImpl: opts.fetchImpl,
        } satisfies AccountOptions);
        this.codec = loadCodec(opts.spb);
    }

    get online(): boolean {
        return this.session?.online ?? false;
    }

    /** 当前续接凭据（number[] 字节数组），null = 下次重连只能走完整登录。
     *  暴露它是为了可观测性：续接成功后凭据必须轮换（docs/archive/session_resume.md） */
    get nonce(): unknown {
        return this.session?.nonce ?? null;
    }

    /** 已收到的计数内下行包数，与服务端 sent 对账（义务 2） */
    get recv(): number {
        return this.session?.recv ?? 0;
    }

    /**
     * 建连并进游戏：/gates 拿在线网关 → 按列表轮换建连 → 有凭据先试续接，
     * 否则完整登录。返回首次握手是否成功；失败不抛错——会话层会持续重连
     */
    async enterGame(opts: EnterGameOptions): Promise<boolean> {
        if (this.session) {
            throw new Error("enterGame 只能调用一次；先 close() 再新建 SkyextClient");
        }
        this.loginRid = opts.rid;
        this.loginServer = opts.server;

        let cached: Endpoint[] = [];
        const resolveEndpoints = async (): Promise<Endpoint[]> => {
            // 每次重连周期刷新网关列表：网关键挂在节点租约上，列表只会包含
            // 真的在线的网关。account 暂时不可用时退回上一次的列表
            const gates = await this.account.gates();
            const fresh = (gates ?? [])
                .filter((g) => g.ws_url)
                .map((g) => ({ url: g.ws_url as string }));
            if (fresh.length > 0) {
                cached = fresh;
                return fresh;
            }
            if (cached.length > 0) {
                return cached;
            }
            throw new Error("没有可用的 ws 网关（/gates 为空或都未开 ws_url）");
        };

        this.session = new SessionClient({
            resolveEndpoints,
            transport: this.opts.transport,
            codec: this.codec,
            loginParam: async () => ({
                token: await this.opts.tokenProvider(),
                rid: this.loginRid,
                proto_checksum: this.codec.checksum,
                server: this.loginServer,
            }),
            onPush: this.opts.onPush,
            onState: this.opts.onState,
            ...this.opts.session,
        });
        return this.session.start();
    }

    /** 业务请求（无超时；断线续接后按原 id 重发，等待跨越重连） */
    request<T = ProtoArgs>(name: string, param?: ProtoArgs): Promise<T | null> {
        if (!this.session) {
            return Promise.resolve(null);
        }
        return this.session.request<T>(name, param);
    }

    /** 主动丢弃当前连接走续接（切网检测、测试用） */
    reconnect(): void {
        this.session?.reconnect();
    }

    close(): void {
        this.session?.close();
        this.session = null;
    }
}
