local cjson = require "cjson"
local crypto = require "crypto"
local time = require "skyext.time"
local config = require "skyext.config"
local log = require "skyext.log"
local secret_guard = require "skyext.secret"

local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local base64urldecode = crypto.base64urldecode
local base64urlencode = crypto.base64urlencode

local M = {}

local supported_alg = {
    HS256 = crypto.hmac_sha256,
    HS512 = crypto.hmac_sha512,
}

-- 登录 token 的签发方与接收方。签名密钥只能保证"这个 token 是我们签的"，
-- iss/aud 进一步保证"是这套服务签的、是签给这套服务的"：
-- 同一个密钥被别的系统（或同一系统的别的用途）复用时，不校验这两项就会互相串。
local DEFAULT_ISSUER = "skyext"
local DEFAULT_AUDIENCE = "skyext-game"
-- 登录 token 拿到之后马上就用，不需要长有效期
local DEFAULT_TTL = 300
-- 各节点之间的时钟差。给得太大等于延长了 token 寿命，30 秒足够 NTP 环境下的抖动。
local DEFAULT_LEEWAY = 30

-- 登录 JWT 密钥。
-- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的永远是 nil，
-- 所以这里惰性读取并缓存；同时校验强度：示例配置里的默认值是公开的，
-- 拿它签名/验签等于谁都能伪造登录态。
-- @return secret|nil, reason  不可用时返回 nil，调用方必须拒绝登录
local g_login_secret -- nil 表示还没读取，false 表示已判定不可用
local g_login_secret_reason

function M.login_secret()
    if g_login_secret == nil then
        local value = config.get("login_jwt_secret")
        -- allow_insecure_secret 只用于本地开发：显式打开时放行弱密钥，但会告警
        local allow_insecure = config.get_boolean("allow_insecure_secret")
        local ok, reason = secret_guard.check(value, { allow_insecure = allow_insecure })
        g_login_secret_reason = reason
        if ok then
            g_login_secret = value
            if reason then
                log.error("login_jwt_secret is insecure, for local development only", "reason", reason)
            end
        else
            g_login_secret = false
            log.error("login_jwt_secret is unusable, login is rejected", "reason", reason)
        end
    end
    if g_login_secret == false then
        return nil, g_login_secret_reason
    end
    -- 放行弱密钥时同样要把原因返回给调用方，否则"可用但不安全"这件事只有日志知道
    return g_login_secret, g_login_secret_reason
end

-- 签发方和校验方读的是同一份配置，所以两边不会配歪
local g_login_options
function M.login_options()
    if not g_login_options then
        g_login_options = {
            iss = config.get("login_jwt_issuer") or DEFAULT_ISSUER,
            aud = config.get("login_jwt_audience") or DEFAULT_AUDIENCE,
            ttl = config.get_number("login_jwt_ttl") or DEFAULT_TTL,
            leeway = config.get_number("login_jwt_leeway") or DEFAULT_LEEWAY,
        }
    end
    return g_login_options
end

-- 定长比较：逐字节比完再判等，不让对方从"第几个字节开始不一样"里试出签名
local function secure_equal(a, b)
    if #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = diff | (string.byte(a, i) ~ string.byte(b, i))
    end
    return diff == 0
end

local function decode_segment(segment)
    local ok, raw = pcall(base64urldecode, segment)
    if not ok or not raw then
        return nil
    end
    local decoded
    ok, decoded = pcall(cjson_decode, raw)
    if not ok or type(decoded) ~= "table" then
        return nil
    end
    return decoded
end

-- aud 允许是字符串或字符串数组（一个 token 签给多个接收方）
local function audience_matches(aud, expected)
    if type(aud) == "string" then
        return aud == expected
    end
    if type(aud) ~= "table" then
        return false
    end
    for _, item in ipairs(aud) do
        if item == expected then
            return true
        end
    end
    return false
end

-- 验证 JWT token
-- @param opts { iss, aud, leeway }  iss/aud 必填，漏传是调用方的 bug，直接报错，
--             不能当成"不校验"静默放行
-- @return payload 或 nil, reason
function M.verify(token, secret, opts)
    assert(type(opts) == "table" and opts.iss and opts.aud, "jwt.verify requires opts.iss and opts.aud")
    if type(token) ~= "string" or token == "" then
        return nil, "missing token"
    end

    local segments = {}
    for segment in string.gmatch(token, "[^%.]+") do
        table.insert(segments, segment)
    end
    if #segments ~= 3 then
        return nil, "invalid token format"
    end

    local header = decode_segment(segments[1])
    if not header then
        return nil, "invalid header"
    end
    if header.typ ~= "JWT" then
        return nil, "invalid type"
    end
    -- alg 只认白名单里的，"none" 和非对称算法都落不到这里
    local hmac_func = supported_alg[header.alg]
    if not hmac_func then
        return nil, "unsupport alg"
    end
    local payload = decode_segment(segments[2])
    if not payload then
        return nil, "invalid payload"
    end

    -- 先验签名：签名不过的 token，里面的 claim 全都不可信，不值得再看
    local signing_input = segments[1] .. "." .. segments[2]
    local ok, signature = pcall(base64urldecode, segments[3])
    if not ok or not signature or not secure_equal(signature, hmac_func(secret, signing_input)) then
        return nil, "invalid signature"
    end

    if payload.iss ~= opts.iss then
        return nil, "invalid issuer"
    end
    if not audience_matches(payload.aud, opts.aud) then
        return nil, "invalid audience"
    end

    -- 时间相关的 claim 都放宽 leeway：节点之间差几秒是常态，
    -- 不放宽的话刚签出来的 token 会在下游被判成"还没生效"
    local leeway = opts.leeway or DEFAULT_LEEWAY
    local now = time.now()
    -- exp 必填：没有过期时间的登录 token 等于永久有效，一旦泄漏就收不回来
    if type(payload.exp) ~= "number" then
        return nil, "missing exp"
    end
    if now >= payload.exp + leeway then
        return nil, "token expired"
    end
    if payload.nbf and now + leeway < payload.nbf then
        return nil, "token not yet valid"
    end
    if payload.iat and payload.iat > now + leeway then
        return nil, "invalid issued time"
    end
    return payload
end

-- 生成 JWT token
-- @param opts { alg, ttl, iss, aud }  iss/aud/ttl 必填，理由同 verify
-- @return token 或 nil, reason
function M.sign(claims, secret, opts)
    assert(
        type(opts) == "table" and opts.iss and opts.aud and opts.ttl,
        "jwt.sign requires opts.iss, opts.aud and opts.ttl"
    )
    local alg = opts.alg or "HS256"
    local hmac_func = supported_alg[alg]
    if not hmac_func then
        return nil, "unsupport alg"
    end
    local ttl = tonumber(opts.ttl)
    if not ttl or ttl <= 0 then
        return nil, "invalid ttl"
    end

    -- 复制一份再塞标准 claim：签名不该顺手改调用方的表
    local now = time.now()
    local payload = {}
    for k, v in pairs(claims) do
        payload[k] = v
    end
    payload.iss = opts.iss
    payload.aud = opts.aud
    payload.iat = now
    payload.exp = now + ttl

    local header_b64 = base64urlencode(cjson_encode({ typ = "JWT", alg = alg }))
    local payload_b64 = base64urlencode(cjson_encode(payload))
    local signing_input = header_b64 .. "." .. payload_b64
    return signing_input .. "." .. base64urlencode(hmac_func(secret, signing_input))
end

-- 签发登录 token。密钥和 iss/aud/ttl 都从配置来，调用方只管业务 claim。
-- @return token 或 nil, reason
function M.sign_login(claims, alg)
    local secret, reason = M.login_secret()
    if not secret then
        return nil, reason
    end
    local opts = M.login_options()
    return M.sign(claims, secret, { alg = alg, iss = opts.iss, aud = opts.aud, ttl = opts.ttl })
end

-- 校验登录 token。
-- @return payload 或 nil, reason, kind
--   kind 为 "config" 表示是服务端配置问题（密钥不可用），该告警而不是当成坏 token；
--   为 "token" 表示调用方给的 token 不合法
function M.verify_login(token)
    local secret, reason = M.login_secret()
    if not secret then
        return nil, reason, "config"
    end
    local payload, err = M.verify(token, secret, M.login_options())
    if not payload then
        return nil, err, "token"
    end
    return payload
end

return M
