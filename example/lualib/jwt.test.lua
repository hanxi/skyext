local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local jwt = require "jwt"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/jwt.lua")

-- 每个用例都加载一份全新的 jwt 模块：login_secret 的判定结果缓存在模块局部变量里，
-- 复用同一个实例会让上一个用例的配置串到下一个用例。
-- cfg 就是"服务 chunk 加载完之后才被注入"的配置表，用来复现真实的加载顺序。
local function load_jwt(cfg)
    local h = { cfg = cfg or {}, reads = 0, errors = {} }
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

t.describe("jwt", function()
    local secret = "test_secret_key_12345"

    t.describe("sign and verify round-trip", function()
        t.it("HS256 round-trip", function()
            local payload = { sub = "user1", username = "alice" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            t.expect(token).to.be_type("string")
            t.expect(token).to.contain(".")

            local decoded, err = jwt.verify(token, secret)
            t.expect(err).to.be_nil()
            t.expect(decoded).to.exist()
            t.expect(decoded.sub).to.equal("user1")
            t.expect(decoded.username).to.equal("alice")
        end)

        t.it("HS512 round-trip", function()
            local payload = { sub = "user2", role = "admin" }
            local token = jwt.sign(payload, secret, "HS512", 3600)
            t.expect(token).to.be_type("string")

            local decoded, err = jwt.verify(token, secret)
            t.expect(err).to.be_nil()
            t.expect(decoded).to.exist()
            t.expect(decoded.sub).to.equal("user2")
            t.expect(decoded.role).to.equal("admin")
        end)
    end)

    t.describe("verify failures", function()
        t.it("rejects invalid format", function()
            local result, err = jwt.verify("not.a.valid.token.format", secret)
            t.expect(result).to.be_nil()
            t.expect(err).to.equal("invalid token format")
        end)

        t.it("rejects wrong secret", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            local result, err = jwt.verify(token, "wrong_secret")
            t.expect(result).to.be_nil()
            t.expect(err).to.contain("signature")
        end)

        t.it("rejects tampered payload", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            -- Tamper with the middle segment
            local parts = {}
            for part in token:gmatch("[^%.]+") do
                parts[#parts + 1] = part
            end
            parts[2] = parts[2] .. "x"
            local tampered = table.concat(parts, ".")
            local result, err = jwt.verify(tampered, secret)
            t.expect(result).to.be_nil()
            t.expect(err).to.exist()
        end)
    end)

    t.describe("token fields", function()
        t.it("sets iat automatically", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            local decoded = jwt.verify(token, secret)
            t.expect(decoded.iat).to.be_type("number")
            t.expect(decoded.iat).to.be_gt(0)
        end)

        t.it("sets exp when exp_secs provided", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 7200)
            local decoded = jwt.verify(token, secret)
            t.expect(decoded.exp).to.be_type("number")
            t.expect(decoded.exp).to.be_gt(decoded.iat)
        end)
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

    t.it("returns a secret that can sign and verify a token", function()
        local h = load_jwt({ login_jwt_secret = STRONG })
        local secret = h.mod.login_secret()
        local token = h.mod.sign({ sub = "user1" }, secret, "HS256", 60)
        local decoded, err = h.mod.verify(token, secret)
        t.expect(err).to.be_nil()
        t.expect(decoded.sub).to.equal("user1")
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
