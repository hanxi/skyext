// 公共类型。字段形状与服务端实现一一对应，改动前先对账：
//   GateInfo    GET /gates        （skyext.realm 的网关注册项）
//   ServerInfo  GET /servers      （example/nodes/account/lualib/account_router.lua）
//   RoleInfo    GET /roles、POST /create_role（mongo 投影 {rid, server, name}）
//
// int64 约定：JSON 与 sproto 里超出 2^53 的整数（rid 是 17 位 int64）一律以
// bigint 表示，安全范围内保持 number。见 json.ts 与 sproto 补丁 2。

/** 在线网关。地址不写死在客户端配置里：列表来自 account 的 /gates，
 *  客户端自己挑一台直连，连不上换下一台（docs/guide/client_protocol.md 第 1 节） */
export interface GateInfo {
    /** 网关所在节点名 */
    node: string;
    /** "host:port"，裸 TCP 接入（2 字节大端长度前缀分帧） */
    tcp_addr: string;
    /** "ws://host:port" 或 "wss://…"，WebSocket 接入；该网关未开 ws 时缺省 */
    ws_url?: string;
    /** 负载权重，当前恒为 1，客户端可用于挑选 */
    weight: number;
}

/** 区服信息。角色只记出生服，login.login 报的 server 必须是出生服 */
export interface ServerInfo {
    /** 区服 ID */
    server: string;
    name: string;
    /** 区服目录里的标签 */
    tag?: string;
    /** "open" 等；建角只能选 status = "open" 的服 */
    status: string;
    open_time?: number;
    /** 最新开放的服。整个列表里最多一个 */
    recommended?: boolean;
}

/** 角色信息（/roles、/create_role 返回） */
export interface RoleInfo {
    rid: bigint | number;
    server: string;
    name: string;
}

/** 会话层状态机。relogin = 续接失败、正在走完整登录 */
export type SessionState = "online" | "offline" | "relogin";

/** sproto 协议字段值的 JS 表示（与 vendored sproto 的 SprotoValue 对齐） */
export type ProtoValue = string | number | bigint | boolean | Uint8Array | number[] | Record<string, unknown> | null;

/** 上行请求参数 / 下行消息体 */
export type ProtoArgs = Record<string, unknown>;
