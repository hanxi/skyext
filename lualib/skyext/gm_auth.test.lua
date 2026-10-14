local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/gm_auth.lua")

local TOKEN_A = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
local TOKEN_B = "0f9e8d7c6b5a40312817f6e5d4c3b2a1"

local function harness(conf)
    local h = { errors = {}, conf = conf or {} }
    local imports = {
        ["skyext.config"] = {
            get_table = function(key)
                return h.conf[key]
            end,
        },
        ["skyext.secret"] = require "skyext.secret",
        ["skyext.log"] = {
            info = function() end,
            error = function(...)
                h.errors[#h.errors + 1] = { ... }
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.auth = assert(loadfile(source, "t", env))()
    return h
end

local function account(name, role, token)
    return { name = name, role = role, token = token }
end

t.describe("gm auth account loading", function()
    t.it("accepts a configured account and rejects an unknown token", function()
        local h = harness({ gm_accounts = { account("ops", "operator", TOKEN_A) } })
        local acc = assert(h.auth.authenticate(TOKEN_A))
        t.expect(acc.name).to.equal("ops")
        t.expect(acc.role).to.equal("operator")
        t.expect(acc.level).to.equal(h.auth.LEVELS.write)

        local nobody, reason = h.auth.authenticate(TOKEN_B)
        t.expect(nobody).to.be_nil()
        t.expect(reason).to.equal("invalid token")
    end)

    t.it("rejects everything when no account is configured", function()
        local h = harness({})
        local nobody, reason = h.auth.authenticate(TOKEN_A)
        t.expect(nobody).to.be_nil()
        t.expect(reason).to.equal("no usable GM account configured")
        t.expect(#h.errors).to.be_gte(1)
    end)

    t.it("rejects a missing or empty token without touching the account list", function()
        local h = harness({ gm_accounts = { account("ops", "operator", TOKEN_A) } })
        t.expect(select(2, h.auth.authenticate(nil))).to.equal("missing token")
        t.expect(select(2, h.auth.authenticate(""))).to.equal("missing token")
    end)

    t.it("drops accounts whose token is a placeholder or too short", function()
        local h = harness({
            gm_accounts = {
                account("weak", "admin", "CHANGE_ME_TO_RANDOM_TOKEN"),
                account("short", "admin", "abc123"),
                account("ops", "operator", TOKEN_A),
            },
        })
        t.expect(h.auth.authenticate("CHANGE_ME_TO_RANDOM_TOKEN")).to.be_nil()
        t.expect(h.auth.authenticate("abc123")).to.be_nil()
        t.expect(h.auth.authenticate(TOKEN_A).name).to.equal("ops")
        t.expect(#h.errors).to.equal(2)
    end)

    t.it("drops accounts with an unknown role, no name, a duplicated name or a shared token", function()
        local h = harness({
            gm_accounts = {
                account("ghost", "wizard", TOKEN_A),
                { role = "admin", token = TOKEN_A },
                account("ops", "operator", TOKEN_A),
                account("ops", "admin", TOKEN_B),
                account("other", "admin", TOKEN_A),
            },
        })
        -- 只有第三条活下来，token 继续是 operator 的而不是后面那条 admin 的
        local acc = assert(h.auth.authenticate(TOKEN_A))
        t.expect(acc.name).to.equal("ops")
        t.expect(acc.role).to.equal("operator")
        t.expect(h.auth.authenticate(TOKEN_B)).to.be_nil()
        t.expect(#h.errors).to.equal(4)
    end)

    t.it("disables the interface when every configured account is unusable", function()
        local h = harness({ gm_accounts = { account("weak", "admin", "secret") } })
        local nobody, reason = h.auth.authenticate("secret")
        t.expect(nobody).to.be_nil()
        t.expect(reason).to.equal("no usable GM account configured")
    end)

    t.it("rereads the config after reload", function()
        local h = harness({ gm_accounts = { account("ops", "operator", TOKEN_A) } })
        t.expect(h.auth.authenticate(TOKEN_A)).to.exist()
        h.conf.gm_accounts = { account("root", "admin", TOKEN_B) }
        t.expect(h.auth.authenticate(TOKEN_A)).to.exist()
        h.auth.reload()
        t.expect(h.auth.authenticate(TOKEN_A)).to.be_nil()
        t.expect(h.auth.authenticate(TOKEN_B).name).to.equal("root")
    end)
end)

t.describe("gm auth authorization", function()
    t.it("lets a role run everything up to its own level", function()
        local h = harness({
            gm_accounts = {
                account("viewer", "readonly", TOKEN_A),
                account("root", "admin", TOKEN_B),
            },
        })
        local viewer = assert(h.auth.authenticate(TOKEN_A))
        t.expect(h.auth.authorize(viewer, "list", "read")).to.equal(true)
        t.expect(h.auth.authorize(viewer, "gc", "write")).to.equal(false)
        t.expect(h.auth.authorize(viewer, "kill", "admin")).to.equal(false)

        local root = assert(h.auth.authenticate(TOKEN_B))
        t.expect(h.auth.authorize(root, "kill", "admin")).to.equal(true)
    end)

    t.it("treats an unknown or missing level as admin", function()
        local h = harness({ gm_accounts = { account("ops", "operator", TOKEN_A) } })
        local ops = assert(h.auth.authenticate(TOKEN_A))
        t.expect(h.auth.authorize(ops, "mystery", nil)).to.equal(false)
        t.expect(h.auth.authorize(ops, "mystery", "whatever")).to.equal(false)
        t.expect(h.auth.normalize_level(nil, "mystery")).to.equal("admin")
        t.expect(h.auth.normalize_level("nonsense", "mystery")).to.equal("admin")
        t.expect(h.auth.normalize_level("read", "list")).to.equal("read")
    end)

    t.it("explains who was refused what", function()
        local h = harness({ gm_accounts = { account("viewer", "readonly", TOKEN_A) } })
        local viewer = assert(h.auth.authenticate(TOKEN_A))
        local allowed, reason = h.auth.authorize(viewer, "kill", "admin")
        t.expect(allowed).to.equal(false)
        t.expect(reason).to.match("readonly")
        t.expect(reason).to.match("kill")
    end)

    t.it("grants extra commands above the role level", function()
        local h = harness({
            gm_roles = { release = { level = "read", extra = { "hotfix", "hotfix_history" } } },
            gm_accounts = { account("deployer", "release", TOKEN_A) },
        })
        local deployer = assert(h.auth.authenticate(TOKEN_A))
        t.expect(h.auth.authorize(deployer, "list", "read")).to.equal(true)
        t.expect(h.auth.authorize(deployer, "hotfix", "admin")).to.equal(true)
        t.expect(h.auth.authorize(deployer, "inject", "admin")).to.equal(false)
        t.expect(h.auth.authorize(deployer, "gc", "write")).to.equal(false)
    end)

    t.it("ignores a custom role with no valid level instead of granting it", function()
        local h = harness({
            gm_roles = { broken = { extra = { "kill" } } },
            gm_accounts = { account("nobody", "broken", TOKEN_A) },
        })
        t.expect(h.auth.authenticate(TOKEN_A)).to.be_nil()
        t.expect(#h.errors).to.be_gte(2) -- 角色被丢弃，挂在它下面的账号也被丢弃
    end)

    t.it("lets a custom role redefine a builtin one", function()
        local h = harness({
            gm_roles = { operator = { level = "read" } },
            gm_accounts = { account("ops", "operator", TOKEN_A) },
        })
        local ops = assert(h.auth.authenticate(TOKEN_A))
        t.expect(h.auth.authorize(ops, "gc", "write")).to.equal(false)
    end)

    t.it("runs internal calls as a system account with full rights", function()
        local h = harness({})
        t.expect(h.auth.SYSTEM.name).to.equal("system")
        t.expect(h.auth.authorize(h.auth.SYSTEM, "inject", "admin")).to.equal(true)
    end)
end)
