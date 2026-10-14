local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/metrics_router.lua")

local METRICS_SERVICE = 0x01000002

local function harness()
    local h = { calls = {}, written = {}, errors = {}, service = METRICS_SERVICE, body = "# HELP a a\n" }
    local imports = {
        skynet = {
            localname = function(name)
                t.expect(name).to.equal(".metrics")
                return h.service
            end,
            call = function(addr, proto, cmd)
                t.expect(addr).to.equal(METRICS_SERVICE)
                t.expect(proto).to.equal("lua")
                h.calls[#h.calls + 1] = cmd
                if h.call_error then
                    error(h.call_error, 0)
                end
                return h.body
            end,
        },
        ["skyext.log"] = {
            error = function(...)
                h.errors[#h.errors + 1] = table.concat({ ... }, " ")
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.router = assert(loadfile(source, "t", env))()

    h.res = {
        write = function(code, body, headers)
            h.written[#h.written + 1] = { code = code, body = body, headers = headers }
            return true
        end,
    }
    return h
end

t.describe("metrics router", function()
    t.it("把渲染结果按 Prometheus 的 content-type 返回", function()
        local h = harness()
        h.router.GET["/metrics"]({}, h.res)

        t.expect(h.calls).to.equal({ "render" })
        local written = h.written[1]
        t.expect(written.code).to.equal(200)
        t.expect(written.body).to.equal("# HELP a a\n")
        t.expect(written.headers["content-type"]).to.equal(require("skyext.metrics_text").CONTENT_TYPE)
    end)

    t.it("每次都重新查地址：缓存住一个重启过的 .metrics 会让端点一直 500", function()
        local h = harness()
        h.router.GET["/metrics"]({}, h.res)
        h.service = nil
        h.router.GET["/metrics"]({}, h.res)

        t.expect(#h.calls).to.equal(1)
        t.expect(h.written[2].code).to.equal(503)
    end)

    t.it("metrics 服务没起来时回 503", function()
        local h = harness()
        h.service = nil
        h.router.GET["/metrics"]({}, h.res)

        t.expect(#h.calls).to.equal(0)
        t.expect(h.written[1].code).to.equal(503)
        t.expect(#h.errors).to.equal(1)
    end)

    t.it("渲染抛错时回 500，而不是把异常丢给 HTTP agent", function()
        local h = harness()
        h.call_error = "scrape timeout"
        t.expect(function()
            h.router.GET["/metrics"]({}, h.res)
        end).to_not
            .throw()

        t.expect(h.written[1].code).to.equal(500)
        t.expect(h.errors[1]).to.contain("scrape timeout")
    end)
end)
