local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local source = fs.join(root, "service/gm.lua")

local TOKEN = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

local SERVICE_A = 0x01000002
local SERVICE_B = 0x01000003

-- 把结构化日志摊平成 { msg, k = v, ... }，断言时按字段取
local function flatten(msg, ...)
    local entry = { msg = msg }
    local args = table.pack(...)
    for i = 1, args.n - 1, 2 do
        entry[args[i]] = args[i + 1]
    end
    return entry
end

-- token 为 nil 表示没配，走"GM 接口整体禁用"那条路
local function harness(token)
    local h = { calls = {}, replies = {}, logs = {} }
    local noop = function() end
    local function record(msg, ...)
        h.logs[#h.logs + 1] = flatten(msg, ...)
    end

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
            get = function(key)
                return key == "gm_auth_token" and token or nil
            end,
            get_number = function() end,
        },
        -- 真的 secret：token 强度规则在 secret.test.lua 里覆盖，
        -- 这里要验的是 gm 服务有没有照它的结论放行
        ["skyext.secret"] = require "skyext.secret",
        ["skyext.log"] = { info = record, warn = record, error = record },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()

    h.register = function(address, cmd_name)
        return h.CMD.register_commands(address, {
            { cmd_name = cmd_name, handler_name = "GM_" .. cmd_name:upper(), desc = cmd_name },
        })
    end
    -- 执行结果现在只留在日志里，捞出那一行
    h.find = function(msg)
        for i = #h.logs, 1, -1 do
            if h.logs[i].msg == msg then
                return h.logs[i]
            end
        end
    end
    h.executed = function()
        return h.find("GM command executed")
    end
    return h
end

local function cred(token)
    return { token = token, peer = "10.0.0.9:4000" }
end

t.describe("gm service authentication", function()
    t.it("runs a command for a caller with the right token", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "gc")
        h.replies[SERVICE_A] = "collected"

        local result = h.CMD.execute_command(cred(TOKEN), "gc", { timeout = "3" })
        t.expect(result.code).to.equal(0)
        t.expect(result.results[1].success).to.equal(true)
        t.expect(result.results[1].data).to.equal("collected")
        t.expect(h.calls[1].handler).to.equal("GM_GC")

        local logged = h.executed()
        t.expect(logged.peer).to.equal("10.0.0.9:4000")
        t.expect(logged.cmd).to.equal("gc")
        t.expect(logged.result).to.equal("ok")
    end)

    t.it("refuses a wrong token without calling the service", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "list")

        local result = h.CMD.execute_command(cred("deadbeefdeadbeefdeadbeef"), "list")
        t.expect(result.code).to.equal(11)
        t.expect(result.error).to.equal("invalid token")
        t.expect(#h.calls).to.equal(0)
        t.expect(h.logs[#h.logs]).to.equal({
            msg = "GM auth failed",
            peer = "10.0.0.9:4000",
            error = "invalid token",
        })
    end)

    t.it("refuses a token of the same length that differs in one byte", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "list")

        local near = TOKEN:sub(1, #TOKEN - 1) .. (TOKEN:sub(-1) == "0" and "1" or "0")
        t.expect(h.CMD.execute_command(cred(near), "list").code).to.equal(11)
        t.expect(#h.calls).to.equal(0)
    end)

    t.it("refuses a missing token", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "list")

        t.expect(h.CMD.execute_command({ peer = "1.2.3.4" }, "list").code).to.equal(11)
        t.expect(#h.calls).to.equal(0)
    end)

    t.it("says so at boot when no token is configured", function()
        local h = harness(nil)
        t.expect(h.find("GM token is unusable, GM interface is disabled")).to.equal({
            msg = "GM token is unusable, GM interface is disabled",
            reason = "not configured",
        })
    end)

    t.it("rejects everything when no token is configured", function()
        local h = harness(nil)
        h.register(SERVICE_A, "list")

        local result = h.CMD.execute_command(cred(TOKEN), "list")
        t.expect(result.code).to.equal(11)
        t.expect(result.error).to.equal("no usable GM token configured")
        t.expect(#h.calls).to.equal(0)
    end)

    t.it("rejects everything when the configured token is a known placeholder", function()
        local h = harness("CHANGE_ME_TO_RANDOM_TOKEN")
        h.register(SERVICE_A, "list")

        t.expect(h.CMD.execute_command(cred("CHANGE_ME_TO_RANDOM_TOKEN"), "list").code).to.equal(11)
        t.expect(#h.calls).to.equal(0)
    end)

    t.it("runs internal calls with no credential at all", function()
        local h = harness(nil)
        h.register(SERVICE_A, "clearcache")

        local result = h.CMD.execute_command(nil, "clearcache")
        t.expect(result.code).to.equal(0)
        t.expect(h.executed().peer).to.equal("internal")
    end)

    t.it("answers an unknown command after the token checks out", function()
        local h = harness(TOKEN)
        local result = h.CMD.execute_command(cred(TOKEN), "nope")
        t.expect(result.code).to.equal(1)
        t.expect(result.error).to.equal("command not found")
        t.expect(h.executed()).to.be_nil()
    end)
end)

t.describe("gm service command registry", function()
    t.it("lists every registered command to a caller with the token", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "list")
        h.register(SERVICE_A, "gc")
        h.register(SERVICE_B, "gc")

        local listed = h.CMD.list_commands(cred(TOKEN))
        t.expect(listed.code).to.equal(0)
        t.expect(#listed.commands).to.equal(2)
        local counts = {}
        for _, cmd in ipairs(listed.commands) do
            counts[cmd.cmd] = cmd.service_count
        end
        t.expect(counts).to.equal({ list = 1, gc = 2 })
    end)

    t.it("refuses to list anything without a valid token", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "list")

        local result = h.CMD.list_commands(cred("nope"))
        t.expect(result.code).to.equal(11)
        t.expect(result.commands).to.be_nil()
    end)
end)

t.describe("gm service execution outcome", function()
    t.it("reports a partial result when only some services succeed", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "gc")
        h.register(SERVICE_B, "gc")
        h.replies[SERVICE_A] = "ok"
        h.replies[SERVICE_B] = function()
            return false, "boom"
        end

        local result = h.CMD.execute_command(cred(TOKEN), "gc")
        t.expect(result.code).to.equal(0)
        t.expect(#result.results).to.equal(2)
        t.expect(h.executed().result).to.equal("partial")
        t.expect(h.executed().error).to.equal("boom")
    end)

    t.it("counts an unknown target service as a failure", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "gc")
        h.replies[SERVICE_A] = "ok"

        -- 指定的服务没注册过这条指令：一个服务都没执行到，不能记成 ok
        local result = h.CMD.execute_command(cred(TOKEN), "gc", nil, { SERVICE_B })
        t.expect(#result.results).to.equal(1)
        t.expect(result.results[1].success).to.equal(false)
        t.expect(h.calls[1]).to.be_nil()
        t.expect(h.executed().result).to.equal("failed")
        t.expect(h.executed().error).to.equal("service not registered for this command")
    end)

    t.it("reports a partial result when one target is valid and one is not", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "gc")
        h.replies[SERVICE_A] = "ok"

        local result = h.CMD.execute_command(cred(TOKEN), "gc", nil, { SERVICE_A, SERVICE_B })
        t.expect(#result.results).to.equal(2)
        t.expect(h.executed().result).to.equal("partial")
    end)

    t.it("reports a failure when every service fails", function()
        local h = harness(TOKEN)
        h.register(SERVICE_A, "gc")
        h.replies[SERVICE_A] = function()
            error("handler exploded", 0)
        end

        local result = h.CMD.execute_command(cred(TOKEN), "gc")
        t.expect(result.results[1].success).to.equal(false)
        t.expect(h.executed().result).to.equal("failed")
        t.expect(h.executed().error).to.equal("handler exploded")
    end)
end)
