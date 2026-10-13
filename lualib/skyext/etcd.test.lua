local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local cjson = require "cjson.safe"
local crypt = require "skynet.crypt"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd.lua")

local function harness()
    local h = {}
    local httpc = {
        request = function(_, _, uri, _, _, body)
            h.uri = uri
            h.body = assert(cjson.decode(body))
            return 200, cjson.encode({ succeeded = true, header = { revision = 5 } })
        end,
    }
    local modules = {
        ["http.httpc"] = httpc,
        ["skyext.time"] = {
            now = function()
                return 0
            end,
        },
        ["skyext.log"] = {
            debug = function() end,
            warn = function() end,
            error = function() end,
            xpcall_msgh = debug.traceback,
        },
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    h.client = assert(loadfile(source, "t", env))().new({
        http_host = "http://127.0.0.1:2379",
        key_prefix = "/tenant/",
    })
    return h
end

t.describe("etcd transaction encoding", function()
    t.it("uses the lease revoke endpoint", function()
        local h = harness()
        local ret = h.client:revoke("12345")
        t.expect(ret.status).to.equal(200)
        t.expect(h.uri).to.equal("/v3/lease/revoke")
        t.expect(h.body.ID).to.equal("12345")
    end)

    t.it("uses the lease time-to-live endpoint", function()
        local h = harness()
        local ret = h.client:timetolive("12345")
        t.expect(ret.status).to.equal(200)
        t.expect(h.uri).to.equal("/v3/lease/timetolive")
        t.expect(h.body.ID).to.equal("12345")
    end)

    t.it("encodes compare, put, range and delete keys with the configured prefix", function()
        local h = harness()
        local ret = h.client:txn({
            { target = "CREATE", key = "lock/a", create_revision = 0 },
        }, {
            { requestDeleteRange = { key = "lock/a" } },
        }, {
            { requestPut = { key = "lock/a", value = "node-a", lease = 1 } },
            { requestRange = { key = "lock/a" } },
        })
        t.expect(ret.body.succeeded).to.equal(true)
        t.expect(h.uri).to.equal("/v3/kv/txn")
        local key = "/tenant/lock/a"
        t.expect(crypt.base64decode(h.body.compare[1].key)).to.equal(key)
        t.expect(h.body.compare[1].create_revision).to.equal(0)
        t.expect(crypt.base64decode(h.body.success[1].requestDeleteRange.key)).to.equal(key)
        t.expect(crypt.base64decode(h.body.failure[1].requestPut.key)).to.equal(key)
        t.expect(cjson.decode(crypt.base64decode(h.body.failure[1].requestPut.value))).to.equal("node-a")
        t.expect(crypt.base64decode(h.body.failure[2].requestRange.key)).to.equal(key)
    end)
end)
