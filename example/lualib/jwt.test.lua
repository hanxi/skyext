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

t.describe("jwt.login_key", function()
    -- 一个不在占位符黑名单里、长度也够的密钥
    local STRONG = "8f14e45fceea167a5a36dedd4bea2543"

    t.it("does not read the config at load time", function()
        -- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的是 nil。
        -- 一旦在文件顶层读配置并缓存，登录就会永久拿着 nil 密钥跑。
        local h = load_jwt({ login_jwt_secret = STRONG })
        t.expect(h.reads).to.equal(0)
        t.expect(h.mod.login_key()).to.equal(STRONG)
        t.expect(h.reads).to.be_gt(0)
    end)

    t.it("reads the config once and memoizes the verdict", function()
        local h = load_jwt({ login_jwt_secret = STRONG })
        t.expect(h.mod.login_key()).to.equal(STRONG)
        local reads = h.reads
        t.expect(reads).to.be_gt(0)
        t.expect(h.mod.login_key()).to.equal(STRONG)
        t.expect(h.reads).to.equal(reads)
    end)

    t.it("rejects the placeholder secret shipped in the example config", function()
        local h = load_jwt({ login_jwt_secret = "your_access_secret" })
        local secret, reason = h.mod.login_key()
        t.expect(secret).to.be_nil()
        t.expect(reason).to.equal("still a well-known placeholder value")
        t.expect(#h.errors).to.equal(1)
        -- 判定结果同样要缓存：不能每次登录都重试一遍并刷一条错误日志
        local again = h.mod.login_key()
        t.expect(again).to.be_nil()
        t.expect(#h.errors).to.equal(1)
    end)

    t.it("rejects a secret that is not configured at all", function()
        local h = load_jwt({})
        local secret, reason = h.mod.login_key()
        t.expect(secret).to.be_nil()
        t.expect(reason).to.equal("not configured")
        t.expect(#h.errors).to.equal(1)
    end)

    t.it("rejects a secret that is too short to be random", function()
        local h = load_jwt({ login_jwt_secret = "abc123" })
        local secret, reason = h.mod.login_key()
        t.expect(secret).to.be_nil()
        t.expect(reason).to.equal("shorter than 16 characters")
    end)

    t.it("lets a local development setup opt into an insecure secret", function()
        local h = load_jwt({
            login_jwt_secret = "your_access_secret",
            allow_insecure_secret = true,
        })
        local secret, reason = h.mod.login_key()
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
        local secret, reason = h.mod.login_key()
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
            alg = "HS256",
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
        t.expect(h.mod.login_options()).to.equal({
            alg = "HS256",
            iss = "acme",
            aud = "acme-game",
            ttl = 60,
            leeway = 5,
        })
        local reads = h.reads
        h.mod.login_options()
        t.expect(h.reads).to.equal(reads)
    end)

    t.it("signs and verifies with the configured issuer and audience", function()
        local h = load_jwt({ login_jwt_secret = STRONG, login_jwt_issuer = "acme", login_jwt_audience = "acme-game" })
        local token = h.mod.sign_login({ account = "robot3" })
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

-- ---------- 非对称算法 ----------
--
-- 下面这几把是为这个测试一次性生成的废弃密钥，只用来跑断言，不要在任何环境里复用。

local RSA_PRIV = [[
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCflF5KVKel6fGv
gMEPyee5GjvhegrQ+n1dIuVqLZU+BHmOf1drHG0mLBzV8vDGAijP89WhjUIUgozi
kn8wEsgQ4t+ZrI9UthL/s7ql8qJgVWaCX9lyUi2otXctFjfiGNF92f8uHmBd71iM
kA7aJg+eWerWt4uf/IJ1w77rCH5C46msjBCfsIuRqd16fZ+VJf1XYIWNy6up3rcf
7Kj6YkD+3KqAHp0D1SyVWQjlj5n+pk0xX/pIh/xX/U/nKjue7vLg+t9N6zmd+9/c
TeKUMGU9QUJVEvGzD3UEODlY2rvbeQZZSBVreq4L9jg4PoMbvVGSvHLSA4IEFPEY
ErcmagcPAgMBAAECggEAQ7+6PkVtfX9yV8fKbzkRc2EDXikxkWJfOdzYWDks/Mzq
jIhcpUFGx6d/wIdpGC+PgyXqozE1Bj8csA5xCAhZPu4K7xO3MEgyjbOQwOZfcJWh
NSWbTDE+aDtOcupVZFyUCCG2eC52TDsStW5tl8kD5X8YN/tpwEz0WCn4EpGjBSM1
5Un6+elIaB6GYPUYfjBUVCwKUMQ+sNkhX+6kM4VMUAGuKWUf6uJQi8gLJLeO1BZE
ROC0OR9hdhI+tE7YcSZSkUyRceOfGh7M79v6oTdSna2anPN3R9Ykm2oja+QbBaQx
6pAsr6rjbEtnrrx9tCvYtC3/uDpeDwvvSbE5nM/BaQKBgQDKn11BhTNxJ50+EItD
WTO4Sm8OUiHWFqbcO7pmZBex6HCWPLRb2qrg3Cya/wTitqy/FJXfIw5rw+NLDZ5U
mX5Ki3OoWVpDlWw49BVmNC9xwYj9qiB/afdUoTllUQSAsoj5eTNYDo/T8ycCMkcK
OqzCRrdHe4keJlmytQSPB59dyQKBgQDJnjxH/WqL9oFuo+mPZJVlaPLJQ9sxUg8y
8pYY7JKAgF2RXwwUth2XDfCxhRR3VEs8rv3G8Ra+AOsS2l6YWXECgYaCMO2H7LFR
QBI5ZBgL+wVTyyBWkdwjMBW3hYB63BlvagKcmaRxCjRjcSjfQ8joxA1836qo5Xb9
GeF6qljKFwKBgGlAbRXK1lTyCfkiaOTcIkSZzaR3v4HRFG4UTJhBaBmPL2SrNdj8
9oSFelotHGGUGJnNXKijMiuCfsAO2+8AKJ0aYULS31N5+9R93dvQQdDqgnmZ9PWa
mtKISSM6+YbMtuA4OBaGwemMRfgbG9HRdsoYJ75nCmvx6egtpaeSgxMZAoGAd4cE
y9UUBngUkchBHg6Odzl5vhIpb5rrgdPJYmtWCzKOxjEoE1tIPZY5HLT9xiTGGerQ
btHdHrWip2GodP+JfOfXG3XwTAXptXabl0Sc8PVXWi7xNAFzFbVbGprd6Xh059Vc
SQTZNV7MYivjBEHGaSBZsq9TGKA5I6HlR/iXfO8CgYEAk6zyOzW4X0mALNgFZnoN
eFetl4N1xIakrc+PY9papED0cGVTQn6yGcT5RwpxTfn8U0+g2EZRAYxYrwZrAvjh
9t/nfQPsSOcH9KXDAOIJWO5/kAoUDjKrH1qKaqstFlmbNKTULVryeBnVoAOR8T+D
xtgvw9pzWyQE+JVlj2Dq+UM=
-----END PRIVATE KEY-----
]]

local RSA_PUB = [[
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAn5ReSlSnpenxr4DBD8nn
uRo74XoK0Pp9XSLlai2VPgR5jn9XaxxtJiwc1fLwxgIoz/PVoY1CFIKM4pJ/MBLI
EOLfmayPVLYS/7O6pfKiYFVmgl/ZclItqLV3LRY34hjRfdn/Lh5gXe9YjJAO2iYP
nlnq1reLn/yCdcO+6wh+QuOprIwQn7CLkanden2flSX9V2CFjcurqd63H+yo+mJA
/tyqgB6dA9UslVkI5Y+Z/qZNMV/6SIf8V/1P5yo7nu7y4PrfTes5nfvf3E3ilDBl
PUFCVRLxsw91BDg5WNq723kGWUgVa3quC/Y4OD6DG71Rkrxy0gOCBBTxGBK3JmoH
DwIDAQAB
-----END PUBLIC KEY-----
]]

local EC_PRIV = [[
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgqlTCC+zIsQPf+ijV
SbjigHnkLCbpvuNlJ3hMSLbfjuGhRANCAATE6Phr7cwLrMf9xab+E4UO2yWBlGKg
nNUV+xVOHY3NWrXh9eOsninbmbGfWgtD0B5NZc6Fy2/MmUxVmFFHpq1L
-----END PRIVATE KEY-----
]]

local EC_PUB = [[
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAExOj4a+3MC6zH/cWm/hOFDtslgZRi
oJzVFfsVTh2NzVq14fXjrJ4p25mxn1oLQ9AeTWXOhctvzJlMVZhRR6atSw==
-----END PUBLIC KEY-----
]]

-- 曲线宽度不对：ES256 钉死 P-256，拿 P-384 的公钥来验必须当配置错误挡掉
local EC384_PUB = [[
-----BEGIN PUBLIC KEY-----
MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAEUUuetClwBBl+W0+5kTezkSr5nnX6Hou0
y+0xIzM5dKn4p9uXPBK/k4F7HheCFy/oYBKG8/uj5ecl8UX3kBOhDB9VOh+8KwLs
8CwFRaDPY6dDG6Wyicyt8BoCpezok9xX
-----END PUBLIC KEY-----
]]

-- 强度不足：RS256 要求至少 2048 位
local RSA1024_PUB = [[
-----BEGIN PUBLIC KEY-----
MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQC8pfLRElj4rwp29ZcZFzoLZxBl
6kTZN683BSberAYvYJCq/2y24jsGvD3nbVosQZIvn/TtofSQP2dwo0Cs11wZVbiC
WLk+LUckr8QUc0lhTGVydFrl7VjTzgsPgm5uol1NZLadrCgMNvKft92fzzblOa6n
FMk6oyuX4HcLPaHGTwIDAQAB
-----END PUBLIC KEY-----
]]

local ASYM_OPTS = { iss = "skyext", aud = "skyext-game", leeway = 30, ttl = 3600 }

local function rsa_pair()
    return { alg = "RS256", private = RSA_PRIV }, { alg = "RS256", public = RSA_PUB }
end

local function ec_pair()
    return { alg = "ES256", private = EC_PRIV }, { alg = "ES256", public = EC_PUB }
end

local function segments(token)
    local h, p, s = token:match("^([^.]+)%.([^.]+)%.([^.]+)$")
    return h, p, s
end

t.describe("jwt asymmetric sign/verify", function()
    t.it("round-trips an RS256 token", function()
        local h = load_jwt()
        local priv, pub = rsa_pair()
        local token = h.mod.sign({ sub = "user1" }, priv, ASYM_OPTS)
        t.expect(token).to.exist()
        local header = cjson.decode(crypto.base64urldecode((segments(token))))
        t.expect(header.alg).to.equal("RS256")

        local decoded, err = h.mod.verify(token, pub, ASYM_OPTS)
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user1")
        t.expect(decoded.exp).to.equal(h.now + 3600)
    end)

    t.it("round-trips an ES256 token", function()
        local h = load_jwt()
        local priv, pub = ec_pair()
        local token = h.mod.sign({ sub = "user2" }, priv, ASYM_OPTS)
        local header = cjson.decode(crypto.base64urldecode((segments(token))))
        t.expect(header.alg).to.equal("ES256")

        local decoded, err = h.mod.verify(token, pub, ASYM_OPTS)
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user2")
    end)

    t.it("emits ES256 signatures as fixed-length R||S, not DER", function()
        -- JWS 规定 ES256 的签名是 64 字节裸拼接；DER 是变长的，直接塞进 token
        -- 别家的库一个都验不过。顺手把每次都重新签的随机性也覆盖掉。
        local h = load_jwt()
        local priv = (ec_pair())
        local seen = {}
        for i = 1, 64 do
            local token = h.mod.sign({ sub = "u" .. i }, priv, ASYM_OPTS)
            local _, _, sig_b64 = segments(token)
            local sig = crypto.base64urldecode(sig_b64)
            t.expect(#sig).to.equal(64)
            seen[sig] = (seen[sig] or 0) + 1
            t.expect(seen[sig]).to.equal(1)
        end
    end)

    t.it("rejects a tampered RS256 payload", function()
        local h = load_jwt()
        local priv, pub = rsa_pair()
        local token = h.mod.sign({ sub = "user1", admin = false }, priv, ASYM_OPTS)
        local hdr, body, sig = segments(token)
        local payload = cjson.decode(crypto.base64urldecode(body))
        payload.admin = true
        local forged = hdr .. "." .. crypto.base64urlencode(cjson.encode(payload)) .. "." .. sig

        local decoded, err = h.mod.verify(forged, pub, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("invalid signature")
    end)

    t.it("rejects an ES256 token whose signature was flipped", function()
        local h = load_jwt()
        local priv, pub = ec_pair()
        local token = h.mod.sign({ sub = "user2" }, priv, ASYM_OPTS)
        local hdr, body, sig_b64 = segments(token)
        local sig = crypto.base64urldecode(sig_b64)
        local flipped = string.char(sig:byte(1) ~ 0x01) .. sig:sub(2)
        local forged = hdr .. "." .. body .. "." .. crypto.base64urlencode(flipped)

        local decoded, err = h.mod.verify(forged, pub, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("invalid signature")
    end)

    t.it("rejects an ES256 signature of the wrong length", function()
        -- 少一个字节就是坏 token，不是配置问题：不能让它走到"告警让运维来修"那条路
        local h = load_jwt()
        local priv, pub = ec_pair()
        local token = h.mod.sign({ sub = "user2" }, priv, ASYM_OPTS)
        local hdr, body, sig_b64 = segments(token)
        local sig = crypto.base64urldecode(sig_b64)
        local short = hdr .. "." .. body .. "." .. crypto.base64urlencode(sig:sub(1, 63))

        local decoded, err, kind = h.mod.verify(short, pub, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("invalid signature")
        t.expect(kind).to.be_nil()
    end)

    t.it("reports a key that does not match the algorithm as a config problem", function()
        local h = load_jwt()
        local priv = (rsa_pair())
        local token = h.mod.sign({ sub = "user1" }, priv, ASYM_OPTS)

        local decoded, err, kind = h.mod.verify(token, { alg = "RS256", public = EC_PUB }, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("key type does not match alg")
        t.expect(kind).to.equal("config")
    end)

    t.it("refuses an RS256 key below 2048 bits", function()
        local h = load_jwt()
        local priv = (rsa_pair())
        local token = h.mod.sign({ sub = "user1" }, priv, ASYM_OPTS)

        local decoded, err, kind = h.mod.verify(token, { alg = "RS256", public = RSA1024_PUB }, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("key is too weak for alg")
        t.expect(kind).to.equal("config")
    end)

    t.it("refuses a P-384 key for ES256", function()
        -- 曲线换宽了裸签名就该是 96 字节，继续按 64 字节切会切出一个能验过的垃圾
        local h = load_jwt()
        local priv = (ec_pair())
        local token = h.mod.sign({ sub = "user2" }, priv, ASYM_OPTS)

        local decoded, err, kind = h.mod.verify(token, { alg = "ES256", public = EC384_PUB }, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("key curve does not match alg")
        t.expect(kind).to.equal("config")
    end)

    t.it("reports a malformed PEM as a config problem", function()
        local h = load_jwt()
        local priv = (rsa_pair())
        local token = h.mod.sign({ sub = "user1" }, priv, ASYM_OPTS)

        for _, broken in ipairs({ "", "not a pem at all", RSA_PUB:sub(1, 60) }) do
            local decoded, err, kind = h.mod.verify(token, { alg = "RS256", public = broken }, ASYM_OPTS)
            t.expect(decoded).to.be_nil()
            t.expect(err).to.equal("invalid public key")
            t.expect(kind).to.equal("config")
        end
    end)

    t.it("refuses to sign without a private key", function()
        local h = load_jwt()
        local token, err = h.mod.sign({ sub = "x" }, { alg = "RS256", public = RSA_PUB }, ASYM_OPTS)
        t.expect(token).to.be_nil()
        t.expect(err).to.equal("no private key")
    end)

    t.it("refuses to sign with a public key handed in as the private one", function()
        local h = load_jwt()
        local token, err = h.mod.sign({ sub = "x" }, { alg = "RS256", private = RSA_PUB }, ASYM_OPTS)
        t.expect(token).to.be_nil()
        t.expect(err).to.equal("invalid private key")
    end)
end)

t.describe("jwt algorithm confusion", function()
    t.it("rejects an HS256 token signed with the RSA public key as the secret", function()
        -- 这是 JWT 最经典的伪造手法：RS256 的公钥是公开的，攻击者拿它当 HMAC 密钥
        -- 签一个 HS256 的 token。只要校验方让 token 头里的 alg 决定走哪条路，
        -- 服务端就会拿同一份公钥算 HMAC，算出来和攻击者一模一样，直接放行。
        local h = load_jwt()
        local header = crypto.base64urlencode(cjson.encode({ typ = "JWT", alg = "HS256" }))
        local body = crypto.base64urlencode(cjson.encode({
            sub = "attacker",
            iss = "skyext",
            aud = "skyext-game",
            iat = h.now,
            exp = h.now + 3600,
        }))
        local input = header .. "." .. body
        local forged = input .. "." .. crypto.base64urlencode(crypto.hmac_sha256(RSA_PUB, input))

        local decoded, err = h.mod.verify(forged, { alg = "RS256", public = RSA_PUB }, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("alg does not match key")
    end)

    t.it("rejects an RS256 token when the configured key is a shared secret", function()
        -- 反方向同样要挡：共享密钥只能走 HMAC，不能被当成公钥去验签
        local h = load_jwt()
        local priv = (rsa_pair())
        local token = h.mod.sign({ sub = "user1" }, priv, ASYM_OPTS)
        local decoded, err = h.mod.verify(token, SECRET, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("alg does not match key")
    end)

    t.it("pins the algorithm within the same family", function()
        -- RS256 和 ES256 同属公钥族，族判断拦不住它们互换，得靠 alg 钉死
        local h = load_jwt()
        local priv = (ec_pair())
        local token = h.mod.sign({ sub = "user2" }, priv, ASYM_OPTS)
        local decoded, err = h.mod.verify(token, { alg = "RS256", public = RSA_PUB }, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("unexpected alg")
    end)

    t.it("rejects a key table whose alg is unknown", function()
        local h = load_jwt()
        local token, err = h.mod.sign({ sub = "x" }, { alg = "PS256", private = RSA_PRIV }, ASYM_OPTS)
        t.expect(token).to.be_nil()
        t.expect(err).to.equal("invalid key")
    end)

    t.it("rejects alg none against an asymmetric key", function()
        local h = load_jwt()
        local header = crypto.base64urlencode(cjson.encode({ typ = "JWT", alg = "none" }))
        local body = crypto.base64urlencode(cjson.encode({ sub = "attacker", iss = "skyext", aud = "skyext-game" }))
        local key = { alg = "RS256", public = RSA_PUB }

        -- 空签名段过不了格式检查，连算法都轮不到看
        local decoded, err = h.mod.verify(header .. "." .. body .. ".", key, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("invalid token format")

        -- 补上一段垃圾签名骗过格式检查，这时必须是算法本身被拒
        decoded, err = h.mod.verify(header .. "." .. body .. ".AAAA", key, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("unsupport alg")
    end)
end)

t.describe("jwt key rotation", function()
    t.it("picks the public key named by kid", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "user2" }, { alg = "ES256", private = EC_PRIV, kid = "k2" }, ASYM_OPTS)
        local header = cjson.decode(crypto.base64urldecode((segments(token))))
        t.expect(header.kid).to.equal("k2")

        local key = { alg = "ES256", public = { k1 = EC384_PUB, k2 = EC_PUB } }
        local decoded, err = h.mod.verify(token, key, ASYM_OPTS)
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user2")
    end)

    t.it("reports an unknown kid as a config problem", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "user2" }, { alg = "ES256", private = EC_PRIV, kid = "k9" }, ASYM_OPTS)
        local decoded, err, kind = h.mod.verify(token, { alg = "ES256", public = { k1 = EC_PUB } }, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("unknown kid")
        t.expect(kind).to.equal("config")
    end)

    t.it("refuses to guess when several keys are configured and the token has no kid", function()
        local h = load_jwt()
        local token = h.mod.sign({ sub = "user2" }, { alg = "ES256", private = EC_PRIV }, ASYM_OPTS)
        local key = { alg = "ES256", public = { k1 = EC_PUB, k2 = EC384_PUB } }
        local decoded, err, kind = h.mod.verify(token, key, ASYM_OPTS)
        t.expect(decoded).to.be_nil()
        t.expect(err).to.equal("missing kid")
        t.expect(kind).to.equal("config")
    end)

    t.it("ignores kid when a single public key is configured", function()
        -- 还没开始轮转的常态：签发方已经带上 kid，校验方只配了一把，不该因此失败
        local h = load_jwt()
        local token = h.mod.sign({ sub = "user2" }, { alg = "ES256", private = EC_PRIV, kid = "k2" }, ASYM_OPTS)
        local decoded, err = h.mod.verify(token, { alg = "ES256", public = EC_PUB }, ASYM_OPTS)
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user2")
    end)
end)

t.describe("crypto ECDSA raw/DER conversion", function()
    -- R 或 S 的最高位字节是 0 时，DER 会少编一个字节。用 BN_bn2bin 直接取出来
    -- 就只有 63 字节，拼出来的签名短一截——这是 ECDSA 裸签名最经典的 off-by-one，
    -- 随机签名里大概 1/256 的概率才撞上一次，所以这里钉一个固定向量。
    local ZERO_PREFIX_MSG = "zero-prefix-probe-180"
    local ZERO_PREFIX_SIG = "AIfR7WjIZtRobzqaBcZE0v3IsdjYoZAtVdzzMbQhjU53YoITIdhc55SVk-S6GES5CfVp1GMPB42tH2Nc46T8hg"

    t.it("verifies a signature whose R starts with a zero byte", function()
        local sig = crypto.base64urldecode(ZERO_PREFIX_SIG)
        t.expect(#sig).to.equal(64)
        t.expect(sig:byte(1)).to.equal(0)
        t.expect(crypto.pkey_verify("ES256", EC_PUB, ZERO_PREFIX_MSG, sig)).to.equal(true)
    end)

    t.it("does not accept that signature with the leading zero stripped", function()
        -- 少掉的那个字节正是 BN_bn2bin 会吞掉的那个
        local sig = crypto.base64urldecode(ZERO_PREFIX_SIG)
        t.expect(crypto.pkey_verify("ES256", EC_PUB, ZERO_PREFIX_MSG, sig:sub(2))).to.equal(false)
    end)

    t.it("keeps signatures at 64 bytes even when a coordinate is short", function()
        -- 签名方向的同一个 bug：补零没做的话，这 512 次里会有几次只输出 63 字节
        for i = 1, 512 do
            local sig = assert(crypto.pkey_sign("ES256", EC_PRIV, "len-probe-" .. i))
            t.expect(#sig).to.equal(64)
        end
    end)

    t.it("reports a bad signature instead of raising", function()
        t.expect(crypto.pkey_verify("ES256", EC_PUB, "msg", string.rep("\0", 64))).to.equal(false)
        t.expect(crypto.pkey_verify("ES256", EC_PUB, "msg", "short")).to.equal(false)
    end)

    t.it("never leaks key material into the error string", function()
        local _, err = crypto.pkey_sign("ES256", EC_PRIV:sub(1, 80), "msg")
        t.expect(err).to.equal("invalid private key")
    end)
end)

t.describe("jwt.login_key asymmetric config", function()
    t.it("verifies with an inline public key", function()
        local h = load_jwt({ login_jwt_alg = "ES256", login_jwt_public_key = EC_PUB })
        local token = h.mod.sign({ account = "a1" }, { alg = "ES256", private = EC_PRIV }, h.mod.login_options())
        local payload, err = h.mod.verify_login(token)
        t.expect(err).to.be_nil()
        t.expect(payload.account).to.equal("a1")
    end)

    t.it("reads the public key from a file", function()
        local path = os.tmpname()
        local f = assert(io.open(path, "wb"))
        f:write(EC_PUB)
        f:close()

        local h = load_jwt({ login_jwt_alg = "ES256", login_jwt_public_key_path = path })
        local token = h.mod.sign({ account = "a2" }, { alg = "ES256", private = EC_PRIV }, h.mod.login_options())
        local payload, err = h.mod.verify_login(token)
        os.remove(path)
        t.expect(err).to.be_nil()
        t.expect(payload.account).to.equal("a2")
    end)

    t.it("refuses a config that sets both the inline key and the path", function()
        -- 两个都配上就说不清哪个生效了，与其挑一个不如直接拒
        local h = load_jwt({
            login_jwt_alg = "ES256",
            login_jwt_public_key = EC_PUB,
            login_jwt_public_key_path = "/nonexistent",
        })
        local payload, reason, kind = h.mod.verify_login("whatever")
        t.expect(payload).to.be_nil()
        t.expect(reason).to.equal("login_jwt_public_key and login_jwt_public_key_path are both set")
        t.expect(kind).to.equal("config")
    end)

    t.it("reports an unreadable key file as a config problem", function()
        local h = load_jwt({ login_jwt_alg = "RS256", login_jwt_public_key_path = "/nonexistent/key.pem" })
        local payload, reason, kind = h.mod.verify_login("whatever")
        t.expect(payload).to.be_nil()
        t.expect(reason).to.equal("cannot read login_jwt_public_key_path")
        t.expect(kind).to.equal("config")
    end)

    t.it("rejects login when an asymmetric alg is configured without a key", function()
        local h = load_jwt({ login_jwt_alg = "RS256" })
        local payload, reason, kind = h.mod.verify_login("whatever")
        t.expect(payload).to.be_nil()
        t.expect(reason).to.equal("not configured")
        t.expect(kind).to.equal("config")
    end)

    t.it("rejects an algorithm the module does not implement", function()
        local h = load_jwt({ login_jwt_alg = "PS256", login_jwt_public_key = RSA_PUB })
        local payload, reason, kind = h.mod.verify_login("whatever")
        t.expect(payload).to.be_nil()
        t.expect(reason).to.equal("unsupport alg: PS256")
        t.expect(kind).to.equal("config")
    end)

    t.it("signs and verifies end to end when both keys are configured", function()
        local h = load_jwt({
            login_jwt_alg = "RS256",
            login_jwt_private_key = RSA_PRIV,
            login_jwt_public_key = RSA_PUB,
            login_jwt_kid = "login-2026",
        })
        local token = h.mod.sign_login({ account = "a3" })
        t.expect(token).to.exist()
        local header = cjson.decode(crypto.base64urldecode((segments(token))))
        t.expect(header.alg).to.equal("RS256")
        t.expect(header.kid).to.equal("login-2026")

        local payload, err = h.mod.verify_login(token)
        t.expect(err).to.be_nil()
        t.expect(payload.account).to.equal("a3")
    end)

    t.it("lets a node hold only the public key", function()
        -- 正式部署里私钥只在签发方，游戏节点签不出 token 是预期内的
        local h = load_jwt({ login_jwt_alg = "ES256", login_jwt_public_key = EC_PUB })
        local token, reason = h.mod.sign_login({ account = "a4" })
        t.expect(token).to.be_nil()
        t.expect(reason).to.equal("not configured")

        local minted = h.mod.sign({ account = "a4" }, { alg = "ES256", private = EC_PRIV }, h.mod.login_options())
        t.expect(h.mod.verify_login(minted).account).to.equal("a4")
    end)

    t.it("does not run the public key through the weak-secret guard", function()
        -- 公钥本来就是公开的，secret_guard 查的是"是不是弱口令"，对它没有意义；
        -- 套上去只会把合法配置拦下来，所以这里不该需要 allow_insecure_secret
        local h = load_jwt({ login_jwt_alg = "ES256", login_jwt_public_key = EC_PUB })
        local key, reason = h.mod.login_key()
        t.expect(key).to.exist()
        t.expect(reason).to.be_nil()
        t.expect(#h.errors).to.equal(0)
    end)

    t.it("caches the sign and verify keys separately", function()
        local h = load_jwt({ login_jwt_alg = "ES256", login_jwt_public_key = EC_PUB })
        t.expect(h.mod.login_key("verify")).to.exist()
        t.expect(h.mod.login_key("sign")).to.be_nil()
        -- 再取一次 verify 不该被 sign 那次的失败污染
        t.expect(h.mod.login_key("verify")).to.exist()
    end)
end)
