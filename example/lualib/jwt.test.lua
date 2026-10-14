local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local cjson = require "cjson"
local crypto = require "crypto"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/jwt.lua")

local SECRET = "test_secret_key_12345"
local OPTS = { iss = "skyext", aud = "skyext-game", leeway = 30, ttl = 3600 }

-- 每个用例都加载一份全新的 jwt 模块：密钥判定和签发参数都缓存在模块局部变量里，
-- 复用同一个实例会让上一个用例的配置串到下一个用例。
-- cfg 就是"服务 chunk 加载完之后才被注入"的配置表，用来复现真实的加载顺序。
-- 时间也换成可控的，否则过期、时钟偏差这些分支只能靠 sleep 去碰。
local function load_jwt(cfg)
    local h = { cfg = cfg or {}, reads = 0, errors = {}, now = 1000000 }
    local imports = {
        ["skyext.config"] = {
            get = function(key)
                h.reads = h.reads + 1
                return h.cfg[key]
            end,
            get_boolean = function(key)
                h.reads = h.reads + 1
                return h.cfg[key] == true
            end,
            get_number = function(key)
                h.reads = h.reads + 1
                return h.cfg[key]
            end,
        },
        ["skyext.time"] = {
            now = function()
                return h.now
            end,
        },
        ["skyext.log"] = {
            error = function(msg)
                h.errors[#h.errors + 1] = tostring(msg)
            end,
            warn = function(msg)
                h.errors[#h.errors + 1] = tostring(msg)
            end,
            info = function() end,
            debug = function() end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.mod = assert(loadfile(source, "t", env))()
    return h
end

-- 手搓一个 token：sign 会强制补上 iss/aud/exp，缺这些 claim 的坏 token 造不出来
local function craft(payload, alg)
    alg = alg or "HS256"
    local header = crypto.base64urlencode(cjson.encode({ typ = "JWT", alg = alg }))
    local body = crypto.base64urlencode(cjson.encode(payload))
    local hmac = alg == "HS512" and crypto.hmac_sha512 or crypto.hmac_sha256
    local input = header .. "." .. body
    return input .. "." .. crypto.base64urlencode(hmac(SECRET, input))
end

t.describe("jwt.sign", function()
    t.it("round-trips the caller's claims and fills in the standard ones", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "user1", username = "alice" }, SECRET, OPTS)
        local decoded, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user1")
        t.expect(decoded.username).to.equal("alice")
        t.expect(decoded.iss).to.equal("skyext")
        t.expect(decoded.aud).to.equal("skyext-game")
        t.expect(decoded.iat).to.equal(h.now)
        t.expect(decoded.exp).to.equal(h.now + 3600)
    end)

    t.it("round-trips with HS512", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "user2" }, SECRET, { iss = "a", aud = "b", ttl = 60, alg = "HS512" })
        local decoded, err = h.mod.verify(token, SECRET, { iss = "a", aud = "b" })
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user2")
    end)

    t.it("does not write standard claims into the caller's table", function()
        local h = load_jwt()
        local claims = { sub = "user1" }
        h.mod.sign(claims, SECRET, OPTS)
        t.expect(claims).to.equal({ sub = "user1" })
    end)

    t.it("refuses to sign without iss, aud and ttl", function()
        local h = load_jwt()
        -- 漏传是调用方的 bug，不能当成"不校验"静默签出一个谁都能接受的 token
        t.expect(function()
            h.mod.sign({ sub = "u" }, SECRET, { aud = "b", ttl = 60 })
        end).to
            .throw()
        t.expect(function()
            h.mod.sign({ sub = "u" }, SECRET, { iss = "a", ttl = 60 })
        end).to
            .throw()
        t.expect(function()
            h.mod.sign({ sub = "u" }, SECRET, { iss = "a", aud = "b" })
        end).to
            .throw()
    end)

    t.it("rejects an unsupported algorithm", function()
        local h = load_jwt()
        local token, err = h.mod.sign({ sub = "u" }, SECRET, { iss = "a", aud = "b", ttl = 60, alg = "none" })
        t.expect(token).to.be_nil()
        t.expect(err).to.equal("unsupport alg")
    end)

    t.it("rejects a ttl that would not expire", function()
        local h = load_jwt()
        local token, err = h.mod.sign({ sub = "u" }, SECRET, { iss = "a", aud = "b", ttl = 0 })
        t.expect(token).to.be_nil()
        t.expect(err).to.equal("invalid ttl")
    end)
end)

t.describe("jwt.verify", function()
    t.it("requires the expected issuer and audience to be given", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "u" }, SECRET, OPTS)
        t.expect(function()
            h.mod.verify(token, SECRET)
        end).to
            .throw()
        t.expect(function()
            h.mod.verify(token, SECRET, { iss = "skyext" })
        end).to
            .throw()
    end)

    t.it("rejects a missing token", function()
        local h = load_jwt()
        t.expect(select(2, h.mod.verify(nil, SECRET, OPTS))).to.equal("missing token")
        t.expect(select(2, h.mod.verify("", SECRET, OPTS))).to.equal("missing token")
    end)

    t.it("rejects a malformed token", function()
        local h = load_jwt()
        local result, err = h.mod.verify("not.a.valid.token.format", SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("invalid token format")
    end)

    t.it("rejects segments that are not base64 json", function()
        local h = load_jwt()
        local result, err = h.mod.verify("!!!.!!!.!!!", SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("invalid header")
    end)

    t.it("rejects the wrong secret", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "u" }, SECRET, OPTS)
        local result, err = h.mod.verify(token, "wrong_secret", OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("invalid signature")
    end)

    t.it("rejects a tampered payload", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "u" }, SECRET, OPTS)
        local parts = {}
        for part in token:gmatch("[^%.]+") do
            parts[#parts + 1] = part
        end
        parts[2] = parts[2] .. "x"
        local result, err = h.mod.verify(table.concat(parts, "."), SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.exist()
    end)

    t.it("rejects an algorithm outside the whitelist", function()
        local h = load_jwt()
        -- alg=none 这类"把签名关掉"的 token 不能落到签名比较那一步
        local header = crypto.base64urlencode(cjson.encode({ typ = "JWT", alg = "none" }))
        local body = crypto.base64urlencode(cjson.encode({ sub = "u", exp = h.now + 60 }))
        local result, err = h.mod.verify(header .. "." .. body .. ".AAAA", SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("unsupport alg")

        -- 签名段整个省掉的写法连三段都凑不齐
        local _, empty_err = h.mod.verify(header .. "." .. body .. ".", SECRET, OPTS)
        t.expect(empty_err).to.equal("invalid token format")
    end)

    t.it("rejects a token without exp", function()
        local h = load_jwt()
        -- 没有过期时间的登录 token 等于永久有效，一旦泄漏就收不回来
        local token = craft({ sub = "u", iss = "skyext", aud = "skyext-game" })
        local result, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("missing exp")
    end)

    t.it("rejects an expired token", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "u" }, SECRET, { iss = "skyext", aud = "skyext-game", ttl = 60 })
        h.now = h.now + 60 + 30
        local result, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("token expired")
    end)

    t.it("tolerates a clock skew within the leeway", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "u" }, SECRET, { iss = "skyext", aud = "skyext-game", ttl = 60 })
        h.now = h.now + 60 + 29
        t.expect(h.mod.verify(token, SECRET, OPTS).sub).to.equal("u")
    end)

    t.it("rejects a token that is not valid yet", function()
        local h = load_jwt()
        local token = craft({ sub = "u", iss = "skyext", aud = "skyext-game", exp = h.now + 600, nbf = h.now + 31 })
        local result, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("token not yet valid")
        -- 偏差在 leeway 以内的 nbf 要放行，否则刚签出来的 token 在下游会被判成未生效
        local soon = craft({ sub = "u", iss = "skyext", aud = "skyext-game", exp = h.now + 600, nbf = h.now + 29 })
        t.expect(h.mod.verify(soon, SECRET, OPTS).sub).to.equal("u")
    end)

    t.it("rejects a token issued in the future", function()
        local h = load_jwt()
        local token = craft({ sub = "u", iss = "skyext", aud = "skyext-game", exp = h.now + 600, iat = h.now + 31 })
        local result, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("invalid issued time")
    end)

    t.it("rejects a token from another issuer", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "u" }, SECRET, { iss = "other", aud = "skyext-game", ttl = 60 })
        local result, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("invalid issuer")
    end)

    t.it("rejects a token signed for another audience", function()
        local h = load_jwt()
        -- 同一个密钥被别的用途复用时，aud 是唯一拦得住"拿后台 token 登游戏"的一道
        local token = h.mod.sign({ sub = "u" }, SECRET, { iss = "skyext", aud = "skyext-admin", ttl = 60 })
        local result, err = h.mod.verify(token, SECRET, OPTS)
        t.expect(result).to.be_nil()
        t.expect(err).to.equal("invalid audience")
    end)

    t.it("accepts an audience list that contains the expected one", function()
        local h = load_jwt()
        local token = craft({
            sub = "u",
            iss = "skyext",
            aud = { "skyext-admin", "skyext-game" },
            exp = h.now + 600,
        })
        t.expect(h.mod.verify(token, SECRET, OPTS).sub).to.equal("u")
    end)
end)

t.describe("jwt.login_secret", function()
    -- 一个不在占位符黑名单里、长度也够的密钥
    local STRONG = "8f14e45fceea167a5a36dedd4bea2543"

    t.it("does not read the config at load time", function()
        -- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的是 nil。
        -- 一旦在文件顶层读配置并缓存，登录就会永久拿着 nil 密钥跑。
        local h = load_jwt({ login_jwt_secret = STRONG })
        t.expect(h.reads).to.equal(0)
        t.expect(h.mod.login_secret()).to.equal(STRONG)
        t.expect(h.reads).to.be_gt(0)
    end)

    t.it("reads the config once and memoizes the verdict", function()
        local h = load_jwt({ login_jwt_secret = STRONG })
        t.expect(h.mod.login_secret()).to.equal(STRONG)
        local reads = h.reads
        t.expect(reads).to.be_gt(0)
        t.expect(h.mod.login_secret()).to.equal(STRONG)
        t.expect(h.reads).to.equal(reads)
    end)

    t.it("rejects the placeholder secret shipped in the example config", function()
        local h = load_jwt({ login_jwt_secret = "your_access_secret" })
        local secret, reason = h.mod.login_secret()
        t.expect(secret).to.be_nil()
        t.expect(reason).to.equal("still a well-known placeholder value")
        t.expect(#h.errors).to.equal(1)
        -- 判定结果同样要缓存：不能每次登录都重试一遍并刷一条错误日志
        local again = h.mod.login_secret()
        t.expect(again).to.be_nil()
        t.expect(#h.errors).to.equal(1)
    end)

    t.it("rejects a secret that is not configured at all", function()
        local h = load_jwt({})
        local secret, reason = h.mod.login_secret()
        t.expect(secret).to.be_nil()
        t.expect(reason).to.equal("not configured")
        t.expect(#h.errors).to.equal(1)
    end)

    t.it("rejects a secret that is too short to be random", function()
        local h = load_jwt({ login_jwt_secret = "abc123" })
        local secret, reason = h.mod.login_secret()
        t.expect(secret).to.be_nil()
        t.expect(reason).to.equal("shorter than 16 characters")
    end)

    t.it("lets a local development setup opt into an insecure secret", function()
        local h = load_jwt({
            login_jwt_secret = "your_access_secret",
            allow_insecure_secret = true,
        })
        local secret, reason = h.mod.login_secret()
        -- 放行但仍然告警：文档里的快速上手流程不能因为这次加固就跑不起来
        t.expect(secret).to.equal("your_access_secret")
        t.expect(reason).to.equal("still a well-known placeholder value")
        t.expect(#h.errors).to.equal(1)
    end)

    t.it("accepts a strong secret even when allow_insecure_secret is on", function()
        local h = load_jwt({
            login_jwt_secret = STRONG,
            allow_insecure_secret = true,
        })
        local secret, reason = h.mod.login_secret()
        t.expect(secret).to.equal(STRONG)
        t.expect(reason).to.be_nil()
        t.expect(#h.errors).to.equal(0)
    end)
end)

t.describe("jwt login token", function()
    local STRONG = "8f14e45fceea167a5a36dedd4bea2543"

    t.it("falls back to built-in issuer, audience and ttl", function()
        local h = load_jwt({ login_jwt_secret = STRONG })
        t.expect(h.mod.login_options()).to.equal({
            iss = "skyext",
            aud = "skyext-game",
            ttl = 300,
            leeway = 30,
        })
    end)

    t.it("takes issuer, audience, ttl and leeway from the config", function()
        local h = load_jwt({
            login_jwt_issuer = "acme",
            login_jwt_audience = "acme-game",
            login_jwt_ttl = 60,
            login_jwt_leeway = 5,
        })
        t.expect(h.mod.login_options()).to.equal({ iss = "acme", aud = "acme-game", ttl = 60, leeway = 5 })
        local reads = h.reads
        h.mod.login_options()
        t.expect(h.reads).to.equal(reads)
    end)

    t.it("signs and verifies with the configured issuer and audience", function()
        local h = load_jwt({ login_jwt_secret = STRONG, login_jwt_issuer = "acme", login_jwt_audience = "acme-game" })
        local token = h.mod.sign_login({ account = "robot3" }, "HS512")
        local decoded, err = h.mod.verify_login(token)
        t.expect(err).to.be_nil()
        t.expect(decoded.account).to.equal("robot3")
        t.expect(decoded.iss).to.equal("acme")
        t.expect(decoded.exp).to.equal(h.now + 300)
    end)

    t.it("refuses to sign when the secret is unusable", function()
        local h = load_jwt({})
        local token, reason = h.mod.sign_login({ account = "robot3" })
        t.expect(token).to.be_nil()
        t.expect(reason).to.equal("not configured")
    end)

    t.it("tells a broken config apart from a bad token", function()
        -- 两者都拒绝登录，但一个该告警让运维来修，一个只是调用方给错了 token
        local broken = load_jwt({})
        local _, reason, kind = broken.mod.verify_login("whatever")
        t.expect(kind).to.equal("config")
        t.expect(reason).to.equal("not configured")

        local h = load_jwt({ login_jwt_secret = STRONG })
        local _, err, bad_kind = h.mod.verify_login("whatever")
        t.expect(bad_kind).to.equal("token")
        t.expect(err).to.equal("invalid token format")
    end)

    t.it("rejects a login token minted for another audience", function()
        local h = load_jwt({ login_jwt_secret = STRONG })
        local token = h.mod.sign({ account = "a" }, STRONG, { iss = "skyext", aud = "skyext-admin", ttl = 60 })
        local decoded, err, kind = h.mod.verify_login(token)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("invalid audience")
        t.expect(kind).to.equal("token")
    end)
end)
