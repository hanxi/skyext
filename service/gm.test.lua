local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local source = fs.join(root, "service/gm.lua")
local auth_source = fs.join(root, "lualib/skyext/gm_auth.lua")

local VIEWER_TOKEN = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
local OPS_TOKEN = "0f9e8d7c6b5a40312817f6e5d4c3b2a1"
local ROOT_TOKEN = "11223344556677889900aabbccddeeff"

local SERVICE_A = 0x01000002
local SERVICE_B = 0x01000003

-- 真的 gm_auth，配置用假的：鉴权规则本身在 gm_auth.test.lua 里覆盖，
-- 这里要验的是 gm 服务有没有正确地用它
local function load_auth(conf)
    local imports = {
        ["skyext.config"] = {
            get_table = function(key)
                return conf[key]
            end,
        },
        ["skyext.secret"] = require "skyext.secret",
        ["skyext.log"] = { info = function() end, error = function() end },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    return assert(loadfile(auth_source, "t", env))()
end

local function harness(conf)
    local h = { records = {}, calls = {}, replies = {} }
    local noop = function() end

    local imports = {
        skynet = {
            start = function(fn)
                h.boot = fn
            end,
            register = noop,
            uniqueservice = noop,
            localname = function()
                return nil
            end,
            address = function(addr)
                return string.format(":%08x", addr)
            end,
            call = function(addr, _, handler_name, params)
                h.calls[#h.calls + 1] = { addr = addr, handler = handler_name, params = params }
                local reply = h.replies[addr]
                if type(reply) == "function" then
                    return reply(params)
                end
                return true, reply
            end,
        },
        ["skyext.http_server"] = {
            new = function()
                return { start = noop, register_router = noop }
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(CMD)
                h.CMD = CMD
            end,
        },
        ["skyext.config"] = {
            get = function() end,
            get_number = function() end,
        },
        ["skyext.gm_auth"] = load_auth(conf or {}),
        ["skyext.gm_audit"] = {
            record = function(entry)
                h.records[#h.records + 1] = entry
            end,
            recent = function(limit)
                h.recent_limit = limit
                return { "recent" }
            end,
        },
        ["skyext.log"] = {
            info = noop,
            warn = noop,
            error = noop,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()

    h.register = function(address, cmd_name, level)
        return h.CMD.register_commands(address, {
            { cmd_name = cmd_name, handler_name = "GM_" .. cmd_name:upper(), desc = cmd_name, level = level },
        })
    end
    return h
end

local function accounts()
    return {
        gm_accounts = {
            { name = "viewer", role = "readonly", token = VIEWER_TOKEN },
            { name = "ops", role = "operator", token = OPS_TOKEN },
            { name = "root", role = "admin", token = ROOT_TOKEN },
        },
    }
end

local function cred(token)
    return { token = token, peer = "10.0.0.9:4000" }
end

t.describe("gm service authorization", function()
    t.it("runs a command the role is allowed to run", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "gc", "write")
        h.replies[SERVICE_A] = "collected"

        local result = h.CMD.execute_command(cred(OPS_TOKEN), "gc", { timeout = "3" })
        t.expect(result.code).to.equal(0)
        t.expect(result.results[1].success).to.equal(true)
        t.expect(result.results[1].data).to.equal("collected")
        t.expect(h.calls[1].handler).to.equal("GM_GC")

        local audit = h.records[1]
        t.expect(audit.account).to.equal("ops")
        t.expect(audit.role).to.equal("operator")
        t.expect(audit.peer).to.equal("10.0.0.9:4000")
        t.expect(audit.cmd).to.equal("gc")
        t.expect(audit.params).to.equal({ timeout = "3" })
        t.expect(audit.result).to.equal("ok")
    end)

    t.it("refuses a command above the role level without calling the service", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "kill", "admin")

        local result = h.CMD.execute_command(cred(OPS_TOKEN), "kill", { address = ":01000002" })
        t.expect(result.code).to.equal(11)
        t.expect(result.error).to.match("operator")
        t.expect(#h.calls).to.equal(0)
        t.expect(h.records[1].result).to.equal("denied")
        t.expect(h.records[1].account).to.equal("ops")
    end)

    t.it("refuses an unknown token and records the attempt", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "list", "read")

        local result = h.CMD.execute_command(cred("deadbeefdeadbeefdeadbeef"), "list")
        t.expect(result.code).to.equal(11)
        t.expect(result.error).to.equal("invalid token")
        t.expect(#h.calls).to.equal(0)
        t.expect(h.records[1].result).to.equal("auth_failed")
        t.expect(h.records[1].account).to.equal("-")
        t.expect(h.records[1].cmd).to.equal("list")
        t.expect(h.records[1].peer).to.equal("10.0.0.9:4000")
    end)

    t.it("records an unknown command against the account that asked for it", function()
        local h = harness(accounts())
        local result = h.CMD.execute_command(cred(ROOT_TOKEN), "nope")
        t.expect(result.code).to.equal(1)
        t.expect(result.error).to.equal("command not found")
        t.expect(h.records[1].result).to.equal("unknown_command")
        t.expect(h.records[1].account).to.equal("root")
    end)

    t.it("runs internal calls as the system account", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "clearcache", "write")

        local result = h.CMD.execute_command(nil, "clearcache")
        t.expect(result.code).to.equal(0)
        t.expect(h.records[1].account).to.equal("system")
        t.expect(h.records[1].peer).to.equal("internal")
        t.expect(h.records[1].result).to.equal("ok")
    end)

    t.it("rejects everything when no account is configured", function()
        local h = harness({})
        h.register(SERVICE_A, "list", "read")

        local result = h.CMD.execute_command(cred(OPS_TOKEN), "list")
        t.expect(result.code).to.equal(11)
        t.expect(#h.calls).to.equal(0)
    end)
end)

t.describe("gm service command registry", function()
    t.it("defaults a command with no declared level to admin", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "mystery", nil)

        t.expect(h.CMD.execute_command(cred(OPS_TOKEN), "mystery").code).to.equal(11)
        t.expect(h.CMD.execute_command(cred(ROOT_TOKEN), "mystery").code).to.equal(0)
    end)

    t.it("keeps the stricter level when two services disagree", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "reload", "read")
        h.register(SERVICE_B, "reload", "admin")

        t.expect(h.CMD.execute_command(cred(VIEWER_TOKEN), "reload").code).to.equal(11)
        -- 反过来注册也一样严
        local other = harness(accounts())
        other.register(SERVICE_A, "reload", "admin")
        other.register(SERVICE_B, "reload", "read")
        t.expect(other.CMD.execute_command(cred(VIEWER_TOKEN), "reload").code).to.equal(11)
    end)

    t.it("lists only the commands the caller may run", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "list", "read")
        h.register(SERVICE_A, "gc", "write")
        h.register(SERVICE_A, "kill", "admin")

        local viewer = h.CMD.list_commands(cred(VIEWER_TOKEN))
        t.expect(viewer.code).to.equal(0)
        t.expect(viewer.account).to.equal("viewer")
        t.expect(viewer.role).to.equal("readonly")
        t.expect(#viewer.commands).to.equal(1)
        t.expect(viewer.commands[1].cmd).to.equal("list")
        t.expect(viewer.commands[1].level).to.equal("read")

        t.expect(#h.CMD.list_commands(cred(OPS_TOKEN)).commands).to.equal(2)
        t.expect(#h.CMD.list_commands(cred(ROOT_TOKEN)).commands).to.equal(3)
    end)

    t.it("refuses to list anything without a valid token", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "list", "read")

        local result = h.CMD.list_commands(cred("nope"))
        t.expect(result.code).to.equal(11)
        t.expect(result.commands).to.be_nil()
        t.expect(h.records[1].result).to.equal("auth_failed")
        t.expect(h.records[1].cmd).to.equal("list_commands")
    end)
end)

t.describe("gm service execution outcome", function()
    t.it("reports a partial result when only some services succeed", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "gc", "write")
        h.register(SERVICE_B, "gc", "write")
        h.replies[SERVICE_A] = "ok"
        h.replies[SERVICE_B] = function()
            return false, "boom"
        end

        local result = h.CMD.execute_command(cred(OPS_TOKEN), "gc")
        t.expect(result.code).to.equal(0)
        t.expect(#result.results).to.equal(2)
        t.expect(h.records[1].result).to.equal("partial")
        t.expect(h.records[1].detail).to.equal("boom")
    end)

    t.it("counts an unknown target service as a failure", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "gc", "write")
        h.replies[SERVICE_A] = "ok"

        -- 指定的服务没注册过这条指令：一个服务都没执行到，审计不能记成 ok
        local result = h.CMD.execute_command(cred(OPS_TOKEN), "gc", nil, { SERVICE_B })
        t.expect(#result.results).to.equal(1)
        t.expect(result.results[1].success).to.equal(false)
        t.expect(h.calls[1]).to.be_nil()
        t.expect(h.records[1].result).to.equal("failed")
        t.expect(h.records[1].detail).to.equal("service not registered for this command")
    end)

    t.it("reports a partial result when one target is valid and one is not", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "gc", "write")
        h.replies[SERVICE_A] = "ok"

        local result = h.CMD.execute_command(cred(OPS_TOKEN), "gc", nil, { SERVICE_A, SERVICE_B })
        t.expect(#result.results).to.equal(2)
        t.expect(h.records[1].result).to.equal("partial")
    end)

    t.it("reports a failure when every service fails", function()
        local h = harness(accounts())
        h.register(SERVICE_A, "gc", "write")
        h.replies[SERVICE_A] = function()
            error("handler exploded", 0)
        end

        local result = h.CMD.execute_command(cred(OPS_TOKEN), "gc")
        t.expect(result.results[1].success).to.equal(false)
        t.expect(h.records[1].result).to.equal("failed")
        t.expect(h.records[1].detail).to.equal("handler exploded")
    end)
end)

t.describe("gm service audit query", function()
    t.it("passes the limit through to the audit log", function()
        local h = harness(accounts())
        t.expect(h.CMD.recent_audit(5)).to.equal({ "recent" })
        t.expect(h.recent_limit).to.equal(5)
    end)
end)
