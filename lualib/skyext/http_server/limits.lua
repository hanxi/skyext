local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local tointeger = math.tointeger
local sformat = string.format

-- HTTP 服务端的资源上限。
-- 这些值要回答的问题是「单个客户端能不能让节点不可用」，不是「吞吐能跑多高」，
-- 所以默认值取保守侧：宁可拒绝连接，也不让慢连接把 agent 协程全部占住。
local M = {}

local DEFAULTS = {
    -- 单实例同时在处理的连接数上限，超出的新连接直接关闭
    max_connections = 1024,
    -- 读完一个完整请求（请求行 + 头 + body）的总时限，秒。
    -- 是绝对时限而不是每次 read 续期的空闲时限，否则 slowloris 逐字节发送就能无限续命。
    read_timeout = 10,
    -- 写出一个响应的时限，秒。客户端不收包时 write 会一直阻塞。
    write_timeout = 10,
    -- keep-alive 连接两次请求之间的空闲时限，秒。0 表示不启用 keep-alive。
    keepalive_timeout = 60,
    -- 单条 keep-alive 连接最多服务多少个请求，到达后主动关闭以回收内存与 fd
    keepalive_requests = 100,
    -- 请求 body 字节上限，超过返回 413
    request_body_size = 1024 * 1024,
}

local MIN = {
    max_connections = 1,
    read_timeout = 1,
    write_timeout = 1,
    keepalive_timeout = 0,
    keepalive_requests = 1,
    request_body_size = 1,
}

--- 解析资源上限
-- @param conf 单个 server 实例的配置，优先级最高
-- @param defaults 节点级默认值（通常来自 skyext.config），次之
-- 两者都没给的字段取内置默认值。任何字段非法都直接报错，不静默回退，
-- 否则一个拼错的配置名就会让上限悄悄变回默认值。
function M.parse(conf, defaults)
    conf = conf or {}
    defaults = defaults or {}
    local out = {}
    for field, min in pairs(MIN) do
        local v = conf[field]
        if v == nil then
            v = defaults[field]
        end
        if v == nil then
            v = DEFAULTS[field]
        end
        local n = tointeger(tonumber(v))
        if not n or n < min then
            error(sformat("invalid http %s: %s", field, tostring(v)))
        end
        out[field] = n
    end
    return out
end

--- 内置默认值的只读副本，供调用方展示或做诊断
function M.defaults()
    local out = {}
    for k, v in pairs(DEFAULTS) do
        out[k] = v
    end
    return out
end

return M
