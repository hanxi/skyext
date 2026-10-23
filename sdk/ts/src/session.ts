// 会话层：sdk/lua/skyext/client/session.lua 的 TypeScript 等价实现，两者共享
// 同一套协议语义测试基线（session.test.lua / session.test.ts 用例一一对应）。
// 规范与五条义务的完整细节见 docs/guide/client_protocol.md，服务端设计背景见
// docs/archive/session_resume.md。
//
// 客户端必须承担的义务，一条都不能省：
//   1. 每个请求带一个自增的 request id，续接之后**用原 id 重发**在途请求。
//      换 id 服务端就认不出来，扣费、抽卡会执行第二遍。计数器只增不减，重连路径上
//      绝不清零：续接不重建服务端会话，重置后的小 id 会命中另一个请求的缓存响应。
//   2. 数**收到的**下行包，不是数**认得的**。序号不在包里传（TCP/WS 在一条连接内
//      有序不丢），两端各数各的，只在 resume / ping 时对账。认不出 request id 的
//      响应（续接后的重复回包）照样要计数再丢；解不开码的包也要计数——服务端发出
//      时计了数，这里漏数一个，重放就错位，而且**不会报错**。
//   3. 传输层握手的回包不计数：login / resume / ping 的响应。
//   4. 自己发现断线：切网络时旧连接不产生 FIN/RST，它直接变黑洞。靠 ping 的
//      **响应**判活，单向心跳没有用。
//   5. resume 的响应和重放的包之间**没有顺序保证**（响应来自登录服务，重放来自
//      实体进程，跨节点时走两条 TCP 连接）。响应靠 request id 认领，又不计数，
//      早到晚到都不影响。
//
// 协程 → async/await 的映射：Lua 版 reader/supervisor/heartbeat 三条协程，这里
// reader 变成 TransportConn.onMessage 回调（事件驱动，无需读循环），supervisor
// 与 heartbeat 是 start() 拉起的两个 async 循环；close() 通过 wakers 把睡在
// reconnect/ping 间隔里的循环立刻叫醒退出，不留悬挂定时器。

import type { Codec } from "./codec.js";
import type { Endpoint, Transport, TransportConn } from "./transport.js";
import { wsTransport } from "./transport.js";
import { ErrCode } from "./errcode.js";
import type { ProtoArgs, SessionState } from "./types.js";

/** 处在下行计数边界之外的回包，必须和服务端 skyext.entity.session、
 *  sdk/lua 的 UNCOUNTED_RESPONSE 一致 */
const UNCOUNTED_RESPONSE = new Set(["login.login", "login.resume", "login.ping"]);

interface Pending {
    name: string;
    param?: ProtoArgs;
    resolve: (value: ProtoArgs | null) => void;
}

/** login.login 的请求体。token 可能过期，所以 SessionOptions.loginParam 是函数；
 *  proto_checksum 用 codec.checksum 填（SkyextClient facade 负责组装） */
export type LoginParam = ProtoArgs;

export interface SessionOptions {
    /** 每次重连周期调用（gate 轮换：连不上换下一台）。地址来自 account /gates */
    resolveEndpoints: () => Endpoint[] | Promise<Endpoint[]>;
    /** 默认 wsTransport()；小程序/测试注入自定义实现 */
    transport?: Transport;
    /** loadCodec(spb) 的产物 */
    codec: Codec;
    /** 返回 login.login 请求体；返回 null/抛错视为本次登录失败 */
    loginParam: () => LoginParam | Promise<LoginParam | null> | null;
    /** 心跳间隔，默认 15s（docs/guide/client_protocol.md 第 4 节） */
    pingIntervalMs?: number;
    /** 连续几次 ping 没等到响应判定连接已死，默认 2 */
    pingTolerance?: number;
    /** 重连周期的间隔，默认 1s */
    reconnectDelayMs?: number;
    /** login/resume/ping 的等待上限，默认 5s。业务请求默认不设超时 */
    handshakeTimeoutMs?: number;
    /** 服务端主动推送（计数内的 REQUEST）。回调抛错不会终止会话 */
    onPush?: (name: string, args?: ProtoArgs) => void;
    /** "online" / "offline" / "relogin" 状态变化 */
    onState?: (state: SessionState) => void;
}

/** 握手类响应的公共形状 */
interface HandshakeResp {
    code?: number;
    rid?: unknown;
    nonce?: unknown;
    sent?: number;
}

export class SessionClient {
    private opts: SessionOptions;
    private transport: Transport;
    private pingIntervalMs: number;
    private pingTolerance: number;
    private reconnectDelayMs: number;
    private handshakeTimeoutMs: number;

    private conn: TransportConn | null = null;
    private _online = false;
    private closed = true;
    private loopsStarted = false;
    private _rid: unknown = null;
    private _nonce: unknown = null;
    private _recv = 0; // 已收到的计数内下行包数，必须和服务端的 sent 严格相等
    // 只在这里置 0。重连、续接、完整重登都不重置，见义务 1
    private nextReqId = 0;
    private pending = new Map<number, Pending>();
    private wakers = new Set<() => void>();

    constructor(opts: SessionOptions) {
        this.opts = opts;
        this.transport = opts.transport ?? wsTransport();
        this.pingIntervalMs = opts.pingIntervalMs ?? 15_000;
        this.pingTolerance = opts.pingTolerance ?? 2;
        this.reconnectDelayMs = opts.reconnectDelayMs ?? 1_000;
        this.handshakeTimeoutMs = opts.handshakeTimeoutMs ?? 5_000;
    }

    get online(): boolean {
        return this._online;
    }
    get recv(): number {
        return this._recv;
    }
    /** 当前续接凭据（真实 codec 下是 number[] 字节数组），null = 只能走完整登录 */
    get nonce(): unknown {
        return this._nonce;
    }
    get rid(): unknown {
        return this._rid;
    }

    /** 建连、登录，并拉起重连与心跳循环。返回首次握手是否成功；
     *  失败不抛错——supervisor 会按 reconnectDelayMs 持续重试 */
    async start(): Promise<boolean> {
        this.closed = false;
        const ok = await this.establish();
        if (!this.loopsStarted) {
            this.loopsStarted = true;
            void this.supervisor();
            void this.heartbeat();
        }
        return ok;
    }

    /**
     * 发一个请求并等响应。timeoutMs 缺省时一直等——续接之后请求会按原 id
     * 重发，等待跨越重连正是这套机制的意义所在。只有握手类请求才给超时；
     * 超时返回 null 但 pending 条目**保留**：迟到的回包要靠它分辨算不算计数
     */
    async request<T = ProtoArgs>(name: string, param?: ProtoArgs, timeoutMs?: number): Promise<T | null> {
        const reqId = ++this.nextReqId;
        let p: Pending;
        const promise = new Promise<ProtoArgs | null>((resolve) => {
            p = { name, param, resolve };
        });
        this.pending.set(reqId, p!);
        this.send(reqId, p!);

        if (timeoutMs === undefined) {
            return (await promise) as unknown as T | null;
        }
        let timer: ReturnType<typeof setTimeout>;
        const timeout = new Promise<null>((resolve) => {
            timer = setTimeout(() => resolve(null), timeoutMs);
        });
        try {
            return (await Promise.race([promise, timeout])) as unknown as T | null;
        } finally {
            clearTimeout(timer!);
        }
    }

    /** 业务请求（无超时），与 Lua 的 call 对齐 */
    call<T = ProtoArgs>(name: string, param?: ProtoArgs): Promise<T | null> {
        return this.request<T>(name, param);
    }

    /** 主动丢弃当前连接，让重连循环走一遍续接。用于测试，也用于客户端自己
     *  察觉到网络环境变了（切 WiFi/蜂窝）时不等心跳超时、立刻重连 */
    reconnect(): void {
        this.drop(this.conn);
    }

    /** 丢弃续接凭据，下次重连直接走完整登录（服务端明确告知凭据失效时用） */
    invalidateNonce(): void {
        this._nonce = null;
    }

    close(): void {
        this.closed = true;
        this.failPending(); // 等待中的请求立刻放行
        const conn = this.conn;
        this.conn = null;
        this._online = false;
        if (conn) {
            try {
                conn.close();
            } catch {
                // 已经断了：忽略
            }
        }
        for (const wake of [...this.wakers]) {
            wake(); // 叫醒 supervisor / heartbeat 立刻退出，不留悬挂定时器
        }
        this.loopsStarted = false;
    }

    // ------------------------------------------------------------------ 内部

    private notifyState(state: SessionState): void {
        try {
            this.opts.onState?.(state);
        } catch {
            // 业务回调抛错不能影响会话
        }
    }

    private send(reqId: number, p: Pending): boolean {
        const conn = this.conn;
        if (!conn) {
            return false;
        }
        try {
            conn.send(this.opts.codec.pack(p.name, p.param, reqId));
            return true;
        } catch {
            // 连接刚断：等 onClosed 触发重连，续接成功后按原 id 重发（义务 1）
            return false;
        }
    }

    private handle(bytes: Uint8Array): void {
        const r = this.opts.codec.dispatch(bytes);
        if (r === null) {
            // 解不开码也要计数：服务端发出时计了数，漏数一个 recv 就永久落后
            // sent 一位，而且不报错（义务 2）
            this._recv += 1;
            return;
        }
        if (r.type === "request") {
            // 服务端推送，计数内
            this._recv += 1;
            try {
                this.opts.onPush?.(r.name, r.args);
            } catch {
                // 业务回调抛错不能终止会话（参考实现 reader 的 pcall 教训）
            }
            return;
        }

        const p = this.pending.get(r.session);
        if (!p) {
            // 续接之后同一个请求会有两份响应：重放出来的那份，和按原 id 重发后
            // 命中服务端幂等缓存的那份。认领一份，另一份丢掉——但**必须先计数**：
            // 服务端两份都计了，这里漏数一个，recv 就永久落后 sent 一位。
            // 丢掉的这份一定是计数内的：握手类请求的 pending 条目在 resendPending /
            // failPending 里已经显式清过，而它们的响应从不进重放缓冲，不可能被重放
            this._recv += 1;
            return;
        }
        this.pending.delete(r.session);
        if (!UNCOUNTED_RESPONSE.has(p.name)) {
            this._recv += 1;
        }
        p.resolve(r.args ?? null);
    }

    /** 连接断了（onClosed 或主动丢弃）。只处理当前这条，迟到的断开通知不能
     *  影响新连接（对应 Lua 的 drop(conn) 代际检查） */
    private drop(conn: TransportConn | null): void {
        if (conn === null || this.conn !== conn) {
            return;
        }
        this.conn = null;
        this._online = false;
        try {
            conn.close();
        } catch {
            // 忽略
        }
        this.notifyState("offline");
    }

    /** 续接之后重发在途请求。**必须用原来的 request id**，服务端靠它认出重复
     *  请求、回缓存的响应而不是重新执行一遍（义务 1） */
    private resendPending(): void {
        for (const [reqId, p] of this.pending) {
            if (UNCOUNTED_RESPONSE.has(p.name)) {
                // 握手类请求不会被重放，旧连接上的那次永远不会有响应了
                this.pending.delete(reqId);
                p.resolve(null);
            } else {
                this.send(reqId, p);
            }
        }
    }

    /** 续接失败后退化成完整登录：会话状态已经没了，在途请求全部失败 */
    private failPending(): void {
        for (const p of this.pending.values()) {
            p.resolve(null);
        }
        this.pending.clear();
    }

    private async tryResume(): Promise<boolean> {
        if (this._nonce == null || this._rid == null) {
            return false;
        }
        const resp = await this.request<HandshakeResp>(
            "login.resume",
            { rid: this._rid, nonce: this._nonce, recv: this._recv },
            this.handshakeTimeoutMs,
        );
        if (!resp || resp.code !== ErrCode.OK) {
            // 任何失败（超时/错误码）都清凭据走完整登录，绝不重试 resume
            return false;
        }
        this._nonce = resp.nonce; // 轮换后的新凭据
        this._online = true;
        // resp.sent 是服务端已发出的包数，(recv, sent] 这些包正在重放过来，
        // 收到就自然对上；响应和重放之间没有顺序保证，这里不能等、也不用等（义务 5）
        this.resendPending();
        this.notifyState("online");
        return true;
    }

    private async doLogin(): Promise<boolean> {
        let param: LoginParam | null;
        try {
            param = await this.opts.loginParam();
        } catch {
            param = null;
        }
        if (!param) {
            return false;
        }
        const resp = await this.request<HandshakeResp>("login.login", param, this.handshakeTimeoutMs);
        if (!resp || resp.code !== ErrCode.OK) {
            return false;
        }
        // 全新的会话：计数清零，旧的在途请求在服务端已经不存在了
        this._rid = resp.rid ?? null;
        this._nonce = resp.nonce ?? null;
        this._recv = 0;
        this._online = true;
        this.failPending();
        this.notifyState("online");
        return true;
    }

    /** 建连并让会话重新可用：先试续接，不行再完整登录 */
    private async establish(): Promise<boolean> {
        let endpoints: Endpoint[];
        try {
            endpoints = await this.opts.resolveEndpoints();
        } catch {
            return false;
        }
        let conn: TransportConn | null = null;
        for (const ep of endpoints) {
            try {
                conn = await this.transport.connect(ep);
                break;
            } catch {
                // 连不上，换下一台 gate
            }
        }
        if (!conn) {
            return false;
        }
        if (this.closed) {
            // connect 期间被 close：这条连接不要了
            try {
                conn.close();
            } catch {
                // 忽略
            }
            return false;
        }
        const c = conn;
        this.conn = c;
        c.onMessage((bytes) => {
            // 代际检查：旧连接迟到的消息不进计数
            if (this.conn === c) {
                try {
                    this.handle(bytes);
                } catch {
                    // 收包路径上的任何异常都不能终止会话
                }
            }
        });
        c.onClosed(() => this.drop(c));

        if (await this.tryResume()) {
            return true;
        }
        this.notifyState("relogin");
        if (await this.doLogin()) {
            return true;
        }
        this.drop(c);
        return false;
    }

    /** 重连循环（对应 Lua 的 supervisor 协程） */
    private async supervisor(): Promise<void> {
        while (!this.closed) {
            if (!this.conn) {
                await this.establish();
            }
            await this.sleep(this.reconnectDelayMs);
        }
    }

    /**
     * 心跳（对应 Lua 的 heartbeat 协程）。它存在的理由是客户端要自己发现黑洞
     * 连接，所以必须看**响应**：单向心跳只让服务端知道客户端还活着，客户端
     * 什么也得不到（义务 4）
     */
    private async heartbeat(): Promise<void> {
        let misses = 0;
        while (!this.closed) {
            await this.sleep(this.pingIntervalMs);
            if (this.closed || !this._online) {
                continue;
            }
            const conn = this.conn;
            const resp = await this.request<HandshakeResp>(
                "login.ping",
                { recv: this._recv },
                this.pingIntervalMs,
            );
            if (resp) {
                misses = 0;
                // 隐式计数唯一的对账点。对不上说明两端已经错位，继续跑下去只会把
                // 错位的数据当正常数据用，不如立刻断开重来
                if (resp.sent !== this._recv) {
                    this._nonce = null; // 计数错位后重放对不上，续接没有意义
                    this.drop(conn);
                }
            } else {
                misses += 1;
                if (misses >= this.pingTolerance) {
                    misses = 0;
                    this.drop(conn); // 黑洞连接：丢弃，走重连+续接
                }
            }
        }
    }

    /** 可被 close() 立刻叫醒的 sleep，避免悬挂定时器拖住事件循环 */
    private sleep(ms: number): Promise<void> {
        return new Promise<void>((resolve) => {
            let done = false;
            const finish = () => {
                if (done) {
                    return;
                }
                done = true;
                clearTimeout(timer);
                this.wakers.delete(finish);
                resolve();
            };
            const timer = setTimeout(finish, ms);
            this.wakers.add(finish);
        });
    }
}
