// Account HTTP 层：sdk/lua/skyext/client/account.lua 的 TypeScript 对等实现，
// 语义一一对应（hosts 轮换、Bearer 头、失败返回 null）。服务器列表、角色管理、
// 网关发现与开发登录，接口语义见 docs/guide/login.md。
// 会话层（连网关、login/resume/ping）在 session.ts，两者互不依赖。
//
// 两条铁律：
//   - 登录 token 只走 Authorization 头。放进 URL query 会被访问日志、代理日志、
//     Referer 和浏览器历史一路抄送
//   - 所有响应经 json.ts 的 parseJson：rid 是 17 位 int64，裸 JSON.parse 会
//     静默丢精度，服务端按精确值匹配角色，错一位就是「角色不存在」

import { parseJson } from "./json.js";
import { ErrCode } from "./errcode.js";
import type { GateInfo, RoleInfo, ServerInfo } from "./types.js";

export interface AccountOptions {
    /** Account 服务地址列表，如 ["http://127.0.0.1:8080"]。随机挑起点，
     *  传输失败换下一台；单地址传一个即可 */
    hosts: string[];
    /** fetch 实现可注入（测试 / 特殊运行时）。默认 globalThis.fetch */
    fetchImpl?: typeof fetch;
}

interface DevLoginResponse {
    code: number;
    token?: string;
}
interface ServersResponse {
    code: number;
    servers?: ServerInfo[];
}
interface RolesResponse {
    code: number;
    roles?: RoleInfo[];
}
interface CreateRoleResponse {
    code: number;
    role?: RoleInfo;
}
interface GatesResponse {
    code: number;
    gates?: GateInfo[];
}

/** 服务端是 cjson：空 Lua 表编码成 {} 而不是 []。空列表要认成 []，
 *  否则「没有角色」会被误判成「请求失败」 */
function asArray<T>(v: unknown): T[] | null {
    if (Array.isArray(v)) {
        return v as T[];
    }
    if (v !== null && typeof v === "object" && Object.keys(v as object).length === 0) {
        return [];
    }
    return null;
}

export class AccountClient {
    private hosts: string[];
    private fetchImpl: typeof fetch;
    private cursor: number;

    constructor(opts: AccountOptions) {
        if (!opts.hosts || opts.hosts.length === 0) {
            throw new Error("AccountClient 需要非空的 hosts 列表");
        }
        this.hosts = [...opts.hosts];
        this.fetchImpl = opts.fetchImpl ?? globalThis.fetch.bind(globalThis);
        this.cursor = Math.floor(Math.random() * this.hosts.length);
    }

    /**
     * 从随机偏移开始逐台尝试，直到拿到有效响应。只在传输失败/非 200 时轮换；
     * code ≠ OK 的业务错误是有效应答，原样返回给调用方判断。
     * 成功返回解码后的响应，全部 host 都失败返回 null
     */
    private async request<T>(method: string, path: string, token?: string, body?: unknown): Promise<T | null> {
        const n = this.hosts.length;
        const start = this.cursor;
        this.cursor = (this.cursor + 1) % n;
        for (let i = 0; i < n; i++) {
            const host = this.hosts[(start + i) % n];
            const headers: Record<string, string> = {};
            if (token) {
                headers.authorization = `Bearer ${token}`;
            }
            if (body !== undefined) {
                headers["content-type"] = "application/json";
            }
            try {
                const resp = await this.fetchImpl(`${host}${path}`, {
                    method,
                    headers,
                    body: body === undefined ? undefined : JSON.stringify(body),
                });
                if (resp.status === 200) {
                    const text = await resp.text();
                    try {
                        return parseJson(text) as T;
                    } catch {
                        // 200 但不是 JSON：原样交给调用方（与 Lua 的 decode or res 对齐）
                        return text as unknown as T;
                    }
                }
            } catch {
                // 传输失败：换下一台
            }
        }
        return null;
    }

    /**
     * 开发登录：POST /dev_login 按账号名直接签发 token，不校验任何身份，
     * 只供本地开发和机器人使用，正式环境必须关掉（见 docs/guide/login.md）。
     * 正式客户端的 token 由平台登录服务签发，拿到后直接用下面的接口即可。
     * 失败返回 null。token 是登录凭据，任何日志都只能记长度这类非敏感信息
     */
    async devLogin(account: string): Promise<string | null> {
        const res = await this.request<DevLoginResponse>("POST", "/dev_login", undefined, { account });
        if (!res || res.code !== ErrCode.OK || !res.token) {
            return null;
        }
        return res.token;
    }

    /** 服务器列表（免登录）。最新开放的服带 recommended = true。失败返回 null */
    async servers(): Promise<ServerInfo[] | null> {
        const res = await this.request<ServersResponse>("GET", "/servers");
        if (!res || res.code !== ErrCode.OK) {
            return null;
        }
        return asArray<ServerInfo>(res.servers);
    }

    /**
     * 挑一个服：recommended 优先，没有则取列表第一个。
     * 建角只能选 status = "open" 的服；角色只记出生服，登录时报的 server 必须是出生服
     */
    async pickRecommendedServer(): Promise<string | null> {
        const servers = await this.servers();
        if (!servers) {
            return null;
        }
        for (const entry of servers) {
            if (entry.recommended) {
                return entry.server;
            }
        }
        return servers[0]?.server ?? null;
    }

    /** 角色列表（带 Bearer token）。rid 超 2^53 时是 bigint。失败返回 null */
    async roles(token: string, server?: string): Promise<RoleInfo[] | null> {
        const path = server ? `/roles?server=${encodeURIComponent(server)}` : "/roles";
        const res = await this.request<RolesResponse>("GET", path, token);
        if (!res || res.code !== ErrCode.OK) {
            return null;
        }
        return asArray<RoleInfo>(res.roles);
    }

    /** 建角。成功返回角色，失败返回 null */
    async createRole(token: string, server: string, name: string): Promise<RoleInfo | null> {
        const res = await this.request<CreateRoleResponse>("POST", "/create_role", token, { server, name });
        if (!res || res.code !== ErrCode.OK || !res.role) {
            return null;
        }
        return res.role;
    }

    /** 有角色取第一个，没有则在指定服建一个。失败返回 null */
    async ensureRole(token: string, name: string, server: string): Promise<RoleInfo | null> {
        const roles = await this.roles(token);
        if (!roles) {
            return null;
        }
        if (roles[0]) {
            return roles[0];
        }
        return this.createRole(token, server, name);
    }

    /**
     * 在线网关列表（免登录）。网关地址不写死在客户端配置里：网关键挂在节点
     * 租约上，列表里只会有真的在线的网关，客户端自己挑一台连，连不上换下一台
     * （见 docs/guide/client_protocol.md 第 1 节）。失败返回 null
     */
    async gates(): Promise<GateInfo[] | null> {
        const res = await this.request<GatesResponse>("GET", "/gates");
        if (!res || res.code !== ErrCode.OK) {
            return null;
        }
        return asArray<GateInfo>(res.gates);
    }
}
