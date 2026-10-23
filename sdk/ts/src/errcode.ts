// 错误码常量，与 lualib/skyext/errcode.lua 逐项对应（那份是唯一权威，改这里前先改那里）。
// 注意：游戏业务自己的错误码（example/lualib/errcode.lua，如 TOKEN_ERROR、NAME_TAKEN）
// 是示例项目扩展，不属于引擎 SDK 的一部分，接入方按自己项目的定义补充。

export const ErrCode = {
    OK: 0,
    IN_OTHER_NODE: 2,
    LOCK_FAILED: 4,
    DB_ERROR: 6,
    PARAM_ERROR: 10,
    AUTH_FAILED: 11,

    // Entity 系统
    ENTITY_NOT_FOUND: 20,
    ENTITY_LOCK_FAILED: 21,
    ENTITY_LOAD_FAILED: 22,
    SESSION_CLOSED: 23,
    /** 这条会话续接不了（重放缓冲溢出 / 计数越界 / 实体未启用会话层）。
     *  客户端收到后清 nonce 走完整登录，绝不重试 resume */
    RESUME_UNAVAILABLE: 24,
    /** 这个 request id 的响应已被服务端幂等缓存淘汰，客户端需重走业务流程 */
    REQUEST_EXPIRED: 25,
    /** 这个 request id 上一次是另一条协议——客户端把请求计数器重置了。
     *  续接不重建会话，计数器绝不能清零（docs/guide/client_protocol.md 义务 1） */
    REQUEST_CONFLICT: 26,
} as const;

export type ErrCodeValue = (typeof ErrCode)[keyof typeof ErrCode];
