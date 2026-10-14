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

-- 验证 JWT token
function M.verify(token, secret)
    -- 1. 分割 token
    local segments = {}
    for segment in string.gmatch(token, "[^%.]+") do
        table.insert(segments, segment)
    end

    if #segments ~= 3 then
        return nil, "invalid token format"
    end

    -- 2. 解码 header 和 payload
    local ok, header = pcall(cjson_decode, base64urldecode(segments[1]))
    if not ok or type(header) ~= "table" then
        return nil, "invalid header"
    end
    if header.typ ~= "JWT" then
        return nil, "invalid type"
    end
    local hmac_func = supported_alg[header.alg]
    if not hmac_func then
        return nil, "unsupport alg"
    end
    local ok, payload = pcall(cjson_decode, base64urldecode(segments[2]))
    if not ok or type(payload) ~= "table" then
        return nil, "invalid payload"
    end

    -- 3. 验证签名
    local signing_input = segments[1] .. "." .. segments[2]
    local signature = base64urldecode(segments[3])
    local expected_sig = hmac_func(secret, signing_input)

    if signature ~= expected_sig then
        return nil, "invalid signature"
    end

    -- 4. 验证时间
    local now = time.now()
    if payload.nbf and now < payload.nbf then
        return nil, "token not yet valid"
    end
    if payload.iat and payload.iat > now then
        return nil, "invalid issued time"
    end
    if payload.exp and now >= payload.exp then
        return nil, "token expired"
    end
    return payload
end

-- 生成 JWT token
function M.sign(payload, secret, alg, exp_secs)
    alg = alg or "HS256"
    local hmac_func = supported_alg[alg]
    if not hmac_func then
        return nil, "unsupport alg"
    end

    -- header 固定结构
    local header = {
        typ = "JWT",
        alg = alg,
    }

    -- 加入 iat 和 exp
    local now = time.now()
    payload.iat = payload.iat or now
    if exp_secs then
        payload.exp = payload.iat + exp_secs
    end

    -- 编码
    local header_b64 = base64urlencode(cjson_encode(header))
    local payload_b64 = base64urlencode(cjson_encode(payload))

    -- 签名
    local signing_input = header_b64 .. "." .. payload_b64
    local signature = hmac_func(secret, signing_input)
    local sig_b64 = base64urlencode(signature)

    return signing_input .. "." .. sig_b64
end

return M
