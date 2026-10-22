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
local const_equals = crypto.const_equals

local M = {}

-- 支持的算法，以及每个算法属于哪一族。
-- hmac 族用一个共享密钥签发和校验；pkey 族用私钥签发、公钥校验。
local ALGORITHMS = {
    HS256 = { family = "hmac", hmac = crypto.hmac_sha256 },
    HS512 = { family = "hmac", hmac = crypto.hmac_sha512 },
    RS256 = { family = "pkey" },
    ES256 = { family = "pkey" },
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
local DEFAULT_ALG = "HS256"

-- 密钥的算法族绑定在密钥本身上，不由 token 头里的 alg 决定。
--
-- 这不是形式上的分类，而是挡算法混淆攻击的那道门：RS256 的公钥是公开的，
-- 攻击者拿它当作 HS256 的共享密钥去签一个 token，校验方如果让 token 头里的
-- alg 决定"这次用 HMAC 还是用公钥验签"，就会拿同一份公钥去算 HMAC —— 算出来
-- 的结果和攻击者算的一模一样，伪造的 token 直接通过。
--
-- 所以密钥有两种写法，各自只能走一条路：
--   字符串                                     -> hmac 族的共享密钥
--   { alg = "RS256", public = pem }            -> pkey 族，只能验签
--   { alg = "RS256", private = pem }           -> pkey 族，只能签发
-- public 也可以是 { [kid] = pem } 的表，用于密钥轮转期同时信任新旧两把；
-- 这个形状和 JWKS 一致，将来接远程拉取不用再改这里的接口。
local function key_family(key)
    if type(key) == "string" then
        return "hmac"
    end
    if type(key) == "table" then
        local spec = ALGORITHMS[key.alg]
        if spec then
            return spec.family
        end
    end
    return nil
end

-- 从密钥描述里取出要用的公钥 PEM。kid 只在配了多把公钥时才需要。
local function resolve_public_pem(key, kid)
    local entry = key.public
    if type(entry) == "string" then
        return entry
    end
    if type(entry) ~= "table" then
        return nil, "no public key"
    end
    if type(kid) ~= "string" then
        return nil, "missing kid"
    end
    local pem = entry[kid]
    if type(pem) ~= "string" then
        return nil, "unknown kid"
    end
    return pem
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

-- 校验签名。
-- @return true | false, reason, kind
--   kind 为 "config" 表示密钥本身有问题（服务端配置错了），不是 token 的错
local function check_signature(spec, alg, key, header, signing_input, signature)
    if spec.family == "hmac" then
        return const_equals(signature, spec.hmac(key, signing_input))
    end
    local pem, pem_err = resolve_public_pem(key, header.kid)
    if not pem then
        return false, pem_err, "config"
    end
    local valid, err = crypto.pkey_verify(alg, pem, signing_input, signature)
    if valid == nil then
        -- 公钥解析不了、和 alg 对不上：这是配置问题，不该当成坏 token
        return false, err, "config"
    end
    return valid
end

-- 验证 JWT token
-- @param key 共享密钥字符串，或 { alg, public = pem | { [kid] = pem } }
-- @param opts { iss, aud, alg, leeway }  iss/aud 必填，漏传是调用方的 bug，直接报错，
--             不能当成"不校验"静默放行。alg 选填，填了就把算法钉死。
-- @return payload 或 nil, reason, kind
function M.verify(token, key, opts)
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
    -- alg 只认白名单里的，"none" 落不到这里
    local spec = ALGORITHMS[header.alg]
    if not spec then
        return nil, "unsupport alg"
    end
    -- 算法族由密钥说了算；token 头里的 alg 只能用来比对，不能用来挑算法
    local family = key_family(key)
    if not family then
        return nil, "invalid key", "config"
    end
    if spec.family ~= family then
        return nil, "alg does not match key"
    end
    -- 钉死到具体算法：配置说了用 RS256，就不接受同族的其它算法
    local expected = opts.alg or (type(key) == "table" and key.alg or nil)
    if expected and header.alg ~= expected then
        return nil, "unexpected alg"
    end

    local payload = decode_segment(segments[2])
    if not payload then
        return nil, "invalid payload"
    end

    -- 先验签名：签名不过的 token，里面的 claim 全都不可信，不值得再看
    local signing_input = segments[1] .. "." .. segments[2]
    local ok, signature = pcall(base64urldecode, segments[3])
    if not ok or not signature then
        return nil, "invalid signature"
    end
    local valid, sig_err, kind = check_signature(spec, header.alg, key, header, signing_input, signature)
    if not valid then
        return nil, sig_err or "invalid signature", kind
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
-- @param key 共享密钥字符串，或 { alg, private = pem, kid }
-- @param opts { alg, ttl, iss, aud }  iss/aud/ttl 必填，理由同 verify
-- @return token 或 nil, reason
function M.sign(claims, key, opts)
    assert(
        type(opts) == "table" and opts.iss and opts.aud and opts.ttl,
        "jwt.sign requires opts.iss, opts.aud and opts.ttl"
    )
    local family = key_family(key)
    if not family then
        return nil, "invalid key"
    end
    local alg = opts.alg or (type(key) == "table" and key.alg) or DEFAULT_ALG
    local spec = ALGORITHMS[alg]
    if not spec then
        return nil, "unsupport alg"
    end
    if spec.family ~= family then
        return nil, "alg does not match key"
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

    local header = { typ = "JWT", alg = alg }
    if type(key) == "table" and key.kid then
        header.kid = key.kid
    end
    local header_b64 = base64urlencode(cjson_encode(header))
    local payload_b64 = base64urlencode(cjson_encode(payload))
    local signing_input = header_b64 .. "." .. payload_b64

    local signature
    if spec.family == "hmac" then
        signature = spec.hmac(key, signing_input)
    else
        if type(key.private) ~= "string" then
            return nil, "no private key"
        end
        local err
        signature, err = crypto.pkey_sign(alg, key.private, signing_input)
        if not signature then
            return nil, err
        end
    end
    return signing_input .. "." .. base64urlencode(signature)
end

-- ---------- 登录 token 的密钥与参数 ----------
--
-- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的永远是 nil，
-- 所以下面这些都惰性读取并缓存。

local function read_pem_config(inline_key, path_key)
    local inline = config.get(inline_key)
    local path = config.get(path_key)
    if inline ~= nil and path ~= nil then
        return nil, string.format("%s and %s are both set", inline_key, path_key)
    end
    if inline ~= nil then
        -- 字符串是单把公钥，表是 kid -> pem（轮转期同时信任多把）
        if type(inline) ~= "string" and type(inline) ~= "table" then
            return nil, inline_key .. " must be a PEM string or a kid table"
        end
        return inline
    end
    if path == nil then
        return nil, "not configured"
    end
    local f = io.open(path, "rb")
    if not f then
        return nil, "cannot read " .. path_key
    end
    local pem = f:read("a")
    f:close()
    if type(pem) ~= "string" or pem == "" then
        return nil, "cannot read " .. path_key
    end
    return pem
end

local g_login_options
function M.login_options()
    if not g_login_options then
        local alg = config.get("login_jwt_alg") or DEFAULT_ALG
        g_login_options = {
            alg = alg,
            iss = config.get("login_jwt_issuer") or DEFAULT_ISSUER,
            aud = config.get("login_jwt_audience") or DEFAULT_AUDIENCE,
            ttl = config.get_number("login_jwt_ttl") or DEFAULT_TTL,
            leeway = config.get_number("login_jwt_leeway") or DEFAULT_LEEWAY,
        }
    end
    return g_login_options
end

-- 按配置解析登录密钥。校验方只需要公钥，签发方才需要私钥，所以分开缓存：
-- 正式部署里游戏节点只拿得到公钥，sign 路径拿不到私钥是预期内的。
-- nil 表示还没解析，false 表示已判定不可用。
local g_login_key = {}
local g_login_reason = {}

local function resolve_login_key(usage)
    local opts = M.login_options()
    local spec = ALGORITHMS[opts.alg]
    if not spec then
        return nil, "unsupport alg: " .. tostring(opts.alg)
    end

    if spec.family == "hmac" then
        -- 示例配置里的默认值是公开的，拿它签名/验签等于谁都能伪造登录态
        local value = config.get("login_jwt_secret")
        -- allow_insecure_secret 只用于本地开发：显式打开时放行弱密钥，但会告警
        local allow_insecure = config.get_boolean("allow_insecure_secret")
        local ok, reason = secret_guard.check(value, { allow_insecure = allow_insecure })
        if not ok then
            return nil, reason
        end
        return value, reason
    end

    if usage == "sign" then
        -- 私钥是签发方的东西。游戏节点没有它才是正常状态。
        local pem, err = read_pem_config("login_jwt_private_key", "login_jwt_private_key_path")
        if not pem then
            return nil, err
        end
        if type(pem) ~= "string" then
            return nil, "login_jwt_private_key must be a PEM string"
        end
        return { alg = opts.alg, private = pem, kid = config.get("login_jwt_kid") }
    end

    -- 公钥是公开的，不走 secret_guard：它查的是"这串东西是不是弱口令"，
    -- 对公钥没有意义，套上去只会把合法配置拦下来。
    local pem, err = read_pem_config("login_jwt_public_key", "login_jwt_public_key_path")
    if not pem then
        return nil, err
    end
    return { alg = opts.alg, public = pem }
end

-- 取登录密钥。
-- @param usage "verify"（默认）或 "sign"
-- @return key|nil, reason
--   reason 在返回 key 时表示"可用但不安全"的告警
function M.login_key(usage)
    usage = usage == "sign" and "sign" or "verify"
    if g_login_key[usage] == nil then
        local key, reason = resolve_login_key(usage)
        g_login_reason[usage] = reason
        if key then
            g_login_key[usage] = key
            if reason then
                log.error("login jwt key is insecure, for local development only", "reason", reason)
            end
        else
            g_login_key[usage] = false
            log.error("login jwt key is unusable, login is rejected", "usage", usage, "reason", reason)
        end
    end
    if g_login_key[usage] == false then
        return nil, g_login_reason[usage]
    end
    -- 放行弱密钥时同样要把原因返回给调用方，否则"可用但不安全"这件事只有日志知道
    return g_login_key[usage], g_login_reason[usage]
end

-- 签发登录 token。密钥和 iss/aud/ttl/alg 都从配置来，调用方只管业务 claim。
-- @return token 或 nil, reason
function M.sign_login(claims)
    local key, reason = M.login_key("sign")
    if not key then
        return nil, reason
    end
    local opts = M.login_options()
    return M.sign(claims, key, { alg = opts.alg, iss = opts.iss, aud = opts.aud, ttl = opts.ttl })
end

-- 校验登录 token。
-- @return payload 或 nil, reason, kind
--   kind 为 "config" 表示是服务端配置问题（密钥不可用），该告警而不是当成坏 token；
--   为 "token" 表示调用方给的 token 不合法
function M.verify_login(token)
    local key, reason = M.login_key("verify")
    if not key then
        return nil, reason, "config"
    end
    local payload, err, kind = M.verify(token, key, M.login_options())
    if not payload then
        return nil, err, kind or "token"
    end
    return payload
end

return M
