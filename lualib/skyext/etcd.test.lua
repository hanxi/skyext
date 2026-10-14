local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local cjson = require "cjson.safe"
local crypt = require "skynet.crypt"
local util_table = require "skyext.util.table"
local redact = require "skyext.log.redact"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd.lua")

-- opts.respond(uri, body) 可以自定义 http 响应；opts.client 会并进 new() 的参数
local function harness(opts)
    opts = opts or {}
    local h = { logs = {} }
    local httpc = {
        request = function(_, _, uri, _, _, body)
            h.uri = uri
            h.body = body and cjson.decode(body) or nil
            if opts.respond then
                return opts.respond(uri, body)
            end
            return 200, cjson.encode({ succeeded = true, header = { revision = 5 } })
        end,
    }

    local function record(...)
        h.logs[#h.logs + 1] = { ... }
    end

    local modules = {
        ["http.httpc"] = httpc,
        ["skyext.time"] = {
            now = function()
                return 0
            end,
        },
        ["skyext.log"] = {
            debug = record,
            info = record,
            warn = record,
            error = record,
            xpcall_msgh = debug.traceback,
        },
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })

    local client_opts = {
        http_host = "http://127.0.0.1:2379",
        key_prefix = "/tenant/",
    }
    for k, v in pairs(opts.client or {}) do
        client_opts[k] = v
    end
    h.client = assert(loadfile(source, "t", env))().new(client_opts)
    return h
end

-- 按真实 logger 的方式渲染捕获到的日志参数：表走带脱敏的序列化，其它走 tostring。
-- 这样断言的是"最终落到日志里的文本"，而不是 etcd 自己拼出来的中间值。
local function dump_logs(h)
    local out = {}
    for _, entry in ipairs(h.logs) do
        for _, v in ipairs(entry) do
            out[#out + 1] = type(v) == "table" and util_table.tostring(v, redact) or tostring(v)
        end
    end
    return table.concat(out, "\n")
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

t.describe("etcd credential logging", function()
    local TOKEN = "eyJhbGciOiJIUzUxMiJ9.eyJ1c2VyIjoicm9vdCJ9.signature-part"
    local PASSWORD = "super-secret-password"
    local AUTH_URI = "/v3/auth/authenticate"

    -- 假的 now() 恒为 0，而 client 初始化时 last_auth_time = now()，
    -- 不把它推到过去就永远走"无需刷新"分支，用例会变成空跑。
    local function force_auth(h)
        h.client.last_auth_time = -100000
        return h
    end

    t.it("never logs the etcd password or the issued jwt token", function()
        local h = force_auth(harness({
            respond = function(uri)
                if uri == AUTH_URI then
                    return 200, cjson.encode({ token = TOKEN, expire = 3600 })
                end
                return 200, cjson.encode({ succeeded = true, header = { revision = 5 } })
            end,
            client = { user = "root", password = PASSWORD },
        }))

        local ret = h.client:revoke("12345")
        t.expect(ret.status).to.equal(200)
        -- 认证确实发生过，否则这个用例是空的
        t.expect(h.client.jwt_token).to.equal(TOKEN)

        local dumped = dump_logs(h)
        t.expect(dumped:find(TOKEN, 1, true)).to.be_nil()
        t.expect(dumped:find(PASSWORD, 1, true)).to.be_nil()
        -- 非敏感信息还是要留着，否则 etcd 的问题没法查
        t.expect(dumped:find("request_uri begin", 1, true)).to.be_type("number")
        t.expect(dumped:find("/v3/lease/revoke", 1, true)).to.be_type("number")
    end)

    t.it("keeps credentials out of the failure logs too", function()
        -- 认证失败时响应体照样可能带 token，而这条是 WARN，默认级别下就会打印
        local h = force_auth(harness({
            respond = function(uri)
                if uri == AUTH_URI then
                    return 401, cjson.encode({ error = "etcdserver: invalid auth", token = TOKEN })
                end
                return 200, cjson.encode({ succeeded = true })
            end,
            client = { user = "root", password = PASSWORD },
        }))

        local ret, err = h.client:revoke("12345")
        t.expect(ret).to.be_nil()
        t.expect(err).to.equal("insufficient credentials code: 401")
        t.expect(h.client.jwt_token).to.be_nil()

        local dumped = dump_logs(h)
        t.expect(dumped:find(TOKEN, 1, true)).to.be_nil()
        t.expect(dumped:find(PASSWORD, 1, true)).to.be_nil()
    end)

    t.it("does not log credentials when auth is disabled", function()
        local h = harness()
        local ret = h.client:revoke("12345")
        t.expect(ret.status).to.equal(200)
        t.expect(h.client.jwt_token).to.be_nil()
        local dumped = dump_logs(h)
        t.expect(dumped:find("request_uri end", 1, true)).to.be_type("number")
    end)
end)
