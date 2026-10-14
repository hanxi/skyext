local t = require "skytest"
local secret = require "skyext.secret"

-- 一个"看起来是随机生成"的可用密钥
local STRONG = "8f14e45fceea167a5a36dedd4bea2543"

t.describe("secret.check", function()
    t.it("rejects a value that is not configured", function()
        local ok, reason = secret.check(nil)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("not configured")

        ok, reason = secret.check("")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("not configured")

        -- 类型不对等同于没配：不能拿一个数字当密钥用
        t.expect(secret.check(123456789012345678)).to.equal(false)
        t.expect(secret.check(true)).to.equal(false)
    end)

    t.it("rejects the placeholders shipped in the example config and docs", function()
        -- gm_auth_token 的示例值
        local ok, reason = secret.check("CHANGE_ME_TO_RANDOM_TOKEN")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("still a well-known placeholder value")

        -- login_jwt_secret 的示例值
        ok, reason = secret.check("your_access_secret")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("still a well-known placeholder value")
    end)

    t.it("rejects a secret that is too short to be random", function()
        local ok, reason = secret.check("abc123")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("shorter than 16 characters")
        t.expect(secret.check(string.rep("a", secret.MIN_LENGTH - 1))).to.equal(false)
        t.expect(secret.check(string.rep("a", secret.MIN_LENGTH))).to.equal(true)
    end)

    t.it("accepts a long non-placeholder secret", function()
        local ok, reason = secret.check(STRONG)
        t.expect(ok).to.equal(true)
        t.expect(reason).to.be_nil()
    end)

    t.it("honours a custom minimum length", function()
        t.expect(secret.check("abcdefgh", { min_length = 8 })).to.equal(true)
        t.expect(secret.check("abcdefg", { min_length = 8 })).to.equal(false)
        -- 长度放宽也不会放过公开占位符
        t.expect(secret.check("your_access_secret", { min_length = 1 })).to.equal(false)
    end)

    t.it("lets a local development setup opt into an insecure secret", function()
        local ok, reason = secret.check("your_access_secret", { allow_insecure = true })
        t.expect(ok).to.equal(true)
        t.expect(reason).to.equal("still a well-known placeholder value")

        ok, reason = secret.check("abc123", { allow_insecure = true })
        t.expect(ok).to.equal(true)
        t.expect(reason).to.equal("shorter than 16 characters")

        -- 没配就是没配，allow_insecure 也不会凭空造出一个密钥
        t.expect(secret.check(nil, { allow_insecure = true })).to.equal(false)
        -- 可用密钥不会带告警
        ok, reason = secret.check(STRONG, { allow_insecure = true })
        t.expect(ok).to.equal(true)
        t.expect(reason).to.be_nil()
    end)
end)

t.describe("secret.is_placeholder", function()
    t.it("ignores case and surrounding whitespace", function()
        t.expect(secret.is_placeholder("CHANGE_ME_TO_RANDOM_TOKEN")).to.equal(true)
        t.expect(secret.is_placeholder("change_me_to_random_token")).to.equal(true)
        t.expect(secret.is_placeholder("  your_access_secret\n")).to.equal(true)
        t.expect(secret.is_placeholder(STRONG)).to.equal(false)
        t.expect(secret.is_placeholder(nil)).to.equal(false)
        t.expect(secret.is_placeholder(1)).to.equal(false)
    end)
end)

t.describe("secret.assert_valid", function()
    t.it("returns the secret when it is usable", function()
        t.expect(secret.assert_valid(STRONG, "login_jwt_secret")).to.equal(STRONG)
    end)

    t.it("raises with the config name in the message", function()
        -- throw 用 string.find 做模式匹配，"-" 是模式元字符，要转义
        t.expect(function()
            secret.assert_valid("your_access_secret", "login_jwt_secret")
        end).to
            .throw("login_jwt_secret is unusable: still a well%-known placeholder value")
        t.expect(function()
            secret.assert_valid(nil)
        end).to
            .throw("secret is unusable: not configured")
    end)
end)
