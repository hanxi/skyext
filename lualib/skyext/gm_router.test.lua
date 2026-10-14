local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/gm_router.lua")

local GM_SERVICE = 0x01000002

local function harness()
    local h = { calls = {}, written = {}, gm_service = GM_SERVICE }
    local imports = {
        skynet = {
            localname = function(name)
                t.expect(name).to.equal(".gm")
                return h.gm_service
            end,
            call = function(addr, proto, cmd, ...)
                t.expect(addr).to.equal(GM_SERVICE)
                t.expect(proto).to.equal("lua")
                h.calls[#h.calls + 1] = { cmd = cmd, args = table.pack(...) }
                if h.call_error then
                    error(h.call_error, 0)
                end
                return h.reply
            end,
        },
        ["skyext.config"] = { get = function() end },
        ["skyext.log"] = { error = function() end },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.router = assert(loadfile(source, "t", env))()

    h.res = {
        write_json = function(data)
            h.written[#h.written + 1] = data
            return true
        end,
    }
    return h
end

local function request(opts)
    return {
        addr = opts.addr,
        header = opts.header,
        parse_query = function()
            return opts.query or {}
        end,
        read_json = function()
            return opts.body
        end,
    }
end

t.describe("gm router credentials", function()
    t.it("takes the token from the Authorization header", function()
        local h = harness()
        h.reply = { code = 0 }
        h.router.GET["/gm/execute"](
            request({
                addr = "10.0.0.9:4000",
                header = { authorization = "Bearer s3cret-token" },
                query = { cmd = "gc" },
            }),
            h.res
        )

        local call = h.calls[1]
        t.expect(call.cmd).to.equal("execute_command")
        t.expect(call.args[1]).to.equal({ token = "s3cret-token", peer = "10.0.0.9:4000" })
        t.expect(call.args[2]).to.equal("gc")
        t.expect(h.written[1]).to.equal({ code = 0 })
    end)

    t.it("falls back to the token parameter and to an unknown peer", function()
        local h = harness()
        h.router.GET["/gm/execute"](request({ query = { cmd = "gc", token = "from-query" } }), h.res)
        t.expect(h.calls[1].args[1]).to.equal({ token = "from-query", peer = "unknown" })

        h.router.POST["/gm/execute"](request({ body = { cmd = "gc", token = "from-body" } }), h.res)
        t.expect(h.calls[2].args[1]).to.equal({ token = "from-body", peer = "unknown" })
    end)

    t.it("forwards a request with no token at all and lets the gm service refuse it", function()
        local h = harness()
        h.reply = { code = 11, error = "missing token" }
        h.router.GET["/gm/list"](request({ addr = "10.0.0.9:4000" }), h.res)

        t.expect(h.calls[1].cmd).to.equal("list_commands")
        t.expect(h.calls[1].args[1]).to.equal({ peer = "10.0.0.9:4000" })
        t.expect(h.written[1]).to.equal({ code = 11, error = "missing token" })
    end)
end)

t.describe("gm router parameters", function()
    t.it("strips cmd, services and token out of the forwarded parameters", function()
        local h = harness()
        h.router.GET["/gm/execute"](
            request({
                query = { cmd = "kill", token = "tok", services = ":01000002,:01000003", address = ":01000004" },
            }),
            h.res
        )

        local call = h.calls[1]
        t.expect(call.args[3]).to.equal({ address = ":01000004" })
        t.expect(call.args[4]).to.equal({ ":01000002", ":01000003" })
    end)

    t.it("passes a POST services array through untouched", function()
        local h = harness()
        h.router.POST["/gm/execute"](request({ body = { cmd = "gc", services = { ":01000002" }, timeout = 3 } }), h.res)

        local call = h.calls[1]
        t.expect(call.args[3]).to.equal({ timeout = 3 })
        t.expect(call.args[4]).to.equal({ ":01000002" })
    end)

    t.it("rejects a request without a command before calling the gm service", function()
        local h = harness()
        h.router.GET["/gm/execute"](request({ query = { token = "tok" } }), h.res)
        h.router.POST["/gm/execute"](request({ body = { token = "tok" } }), h.res)

        t.expect(#h.calls).to.equal(0)
        t.expect(h.written[1].code).to.equal(10)
        t.expect(h.written[2].code).to.equal(10)
    end)

    t.it("rejects a POST body that is not json", function()
        local h = harness()
        h.router.POST["/gm/execute"](request({}), h.res)
        t.expect(#h.calls).to.equal(0)
        t.expect(h.written[1].code).to.equal(10)
    end)
end)

t.describe("gm router failures", function()
    t.it("answers with an error when the gm service is missing", function()
        local h = harness()
        h.gm_service = nil
        h.router.GET["/gm/execute"](request({ query = { cmd = "gc" } }), h.res)

        t.expect(#h.calls).to.equal(0)
        t.expect(h.written[1].code).to.equal(1)
        t.expect(h.written[1].error).to.equal("GM service not available")
    end)

    t.it("answers with an error when the gm service call raises", function()
        local h = harness()
        h.call_error = "service crashed"
        h.router.GET["/gm/list"](request({}), h.res)

        t.expect(h.written[1].code).to.equal(1)
        t.expect(h.written[1].error).to.equal("service crashed")
    end)
end)
