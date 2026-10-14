local t = require "skytest"
local cjson = require "cjson.safe"
local crypt = require "skynet.crypt"
local util_table = require "skyext.util.table"
local redact = require "skyext.log.redact"

-- 这里要的是"整条链路"：init 聚合出来的客户端 → kv/lease → transport → httpc。
-- 各层自己的 require 在加载时就固定了，用 loadfile 注入只能换掉一层，
-- 因此在 require "skyext.etcd" 之前替换 package.loaded（每个测试文件是独立的 lua 虚拟机）。
local state = { logs = {}, requests = {}, now = 0 }

local fake_httpc = { timeout = 1000 }
function fake_httpc.request(_, host, uri, _, headers, body)
    state.requests[#state.requests + 1] = {
        host = host,
        uri = uri,
        headers = headers,
        body = body and cjson.decode(body) or nil,
    }
    if state.respond then
        return state.respond(uri, body)
    end
    return 200, cjson.encode({ header = { revision = 5 } })
end

local function record(...)
    state.logs[#state.logs + 1] = { ... }
end

package.loaded["http.httpc"] = fake_httpc
package.loaded["skyext.time"] = {
    now = function()
        return state.now
    end,
}
package.loaded["skyext.log"] = {
    debug = record,
    info = record,
    warn = record,
    error = record,
    xpcall_msgh = debug.traceback,
}

local etcd = require "skyext.etcd"

local function reset()
    state.logs = {}
    state.requests = {}
    state.respond = nil
    state.now = 0
end

local function client(opts)
    opts = opts or {}
    opts.http_host = opts.http_host or "http://127.0.0.1:2379"
    opts.key_prefix = opts.key_prefix or "/tenant/"
    return assert(etcd.new(opts))
end

local function last_request()
    return state.requests[#state.requests]
end

-- 按真实 logger 的方式渲染捕获到的日志参数：表走带脱敏的序列化，其它走 tostring。
-- 这样断言的是"最终落到日志里的文本"，而不是 etcd 自己拼出来的中间值。
local function dump_logs()
    local out = {}
    for _, entry in ipairs(state.logs) do
        for _, v in ipairs(entry) do
            out[#out + 1] = type(v) == "table" and util_table.tostring(v, redact) or tostring(v)
        end
    end
    return table.concat(out, "\n")
end

t.describe("skyext.etcd", function()
    t.describe("new", function()
        t.before_each(reset)

        t.it("聚合出 kv、lease、watch、auth 四类方法", function()
            local cli = client()
            for _, name in ipairs({
                "get",
                "set",
                "setnx",
                "setx",
                "mod",
                "txn",
                "delete",
                "readdir",
                "rmdir",
                "grant",
                "revoke",
                "keepalive",
                "timetolive",
                "leases",
                "watch",
                "watchdir",
                "authorize",
            }) do
                t.expect(cli[name]).to.be_type("function")
            end
        end)

        t.it("默认不开鉴权，配了用户名密码才开", function()
            t.expect(client().is_auth).to.equal(false)
            t.expect(client({ user = "root", password = "x" }).is_auth).to.equal(true)
        end)

        -- 配置写错要在启动时就报出来，而不是等到第一次请求
        t.it("http_host 不合法时返回错误而不是抛异常", function()
            local cli, err = etcd.new({ http_host = "127.0.0.1:2379" })
            t.expect(cli).to.be_nil()
            t.expect(err).to.match("invalid http_host")
        end)

        t.it("每个客户端的故障摘除记录互相独立", function()
            local a = client()
            local b = client()
            a.fail_expired_time["http://127.0.0.1:2379"] = 999
            t.expect(next(b.fail_expired_time)).to.be_nil()
        end)
    end)

    t.describe("端到端", function()
        t.before_each(reset)

        t.it("写入的 key 带前缀，读出来的 value 是原来的 Lua 值", function()
            local cli = client()
            cli:set("node/a", { host = "1.1.1.1" })
            local put = last_request()
            t.expect(put.uri).to.equal("/v3/kv/put")
            t.expect(crypt.base64decode(put.body.key)).to.equal("/tenant/node/a")

            state.respond = function()
                return 200,
                    cjson.encode({
                        kvs = {
                            {
                                key = crypt.base64encode("/tenant/node/a"),
                                value = crypt.base64encode(cjson.encode({ host = "1.1.1.1" })),
                            },
                        },
                    })
            end
            local res = assert(cli:get("node/a"))
            t.expect(res.body.kvs[1].value.host).to.equal("1.1.1.1")
        end)

        t.it("租约接口打到对应的 etcd 端点", function()
            local cli = client()
            t.expect(assert(cli:revoke("12345")).status).to.equal(200)
            t.expect(last_request().uri).to.equal("/v3/lease/revoke")
            t.expect(last_request().body.ID).to.equal("12345")

            assert(cli:timetolive("12345"))
            t.expect(last_request().uri).to.equal("/v3/lease/timetolive")
        end)

        t.it("事务里的 key 统一加前缀后编码", function()
            local cli = client()
            local ret = assert(cli:txn({
                { target = "CREATE", key = "lock/a", create_revision = 0 },
            }, {
                { requestPut = { key = "lock/a", value = "node-a", lease = 1 } },
            }, nil))
            t.expect(ret.status).to.equal(200)
            local body = last_request().body
            t.expect(crypt.base64decode(body.compare[1].key)).to.equal("/tenant/lock/a")
            t.expect(cjson.decode(crypt.base64decode(body.success[1].requestPut.value))).to.equal("node-a")
        end)
    end)

    t.describe("凭据不进日志", function()
        local TOKEN = "eyJhbGciOiJIUzUxMiJ9.eyJ1c2VyIjoicm9vdCJ9.signature-part"
        local PASSWORD = "super-secret-password"
        local AUTH_URI = "/v3/auth/authenticate"

        t.before_each(reset)

        t.it("既不记 etcd 密码，也不记签发的 jwt token", function()
            state.respond = function(uri)
                if uri == AUTH_URI then
                    return 200, cjson.encode({ token = TOKEN, expire = 3600 })
                end
                return 200, cjson.encode({ succeeded = true })
            end

            local cli = client({ user = "root", password = PASSWORD })
            t.expect(assert(cli:revoke("12345")).status).to.equal(200)
            -- 认证确实发生过，否则这个用例是空的
            t.expect(cli.jwt_token).to.equal(TOKEN)

            local dumped = dump_logs()
            t.expect(dumped:find(TOKEN, 1, true)).to.be_nil()
            t.expect(dumped:find(PASSWORD, 1, true)).to.be_nil()
            -- 非敏感信息还是要留着，否则 etcd 的问题没法查
            t.expect(dumped:find("etcd request begin", 1, true)).to.be_type("number")
            t.expect(dumped:find("/v3/lease/revoke", 1, true)).to.be_type("number")
        end)

        t.it("认证失败的日志里同样没有凭据", function()
            -- 认证失败时响应体照样可能带 token，而这条是 WARN，默认级别下就会打印
            state.respond = function(uri)
                if uri == AUTH_URI then
                    return 401, cjson.encode({ error = "etcdserver: invalid auth", token = TOKEN })
                end
                return 200, cjson.encode({ succeeded = true })
            end

            local cli = client({ user = "root", password = PASSWORD })
            local res, err = cli:revoke("12345")
            t.expect(res).to.be_nil()
            t.expect(err).to.match("insufficient credentials")
            t.expect(cli.jwt_token).to.be_nil()

            local dumped = dump_logs()
            t.expect(dumped:find(TOKEN, 1, true)).to.be_nil()
            t.expect(dumped:find(PASSWORD, 1, true)).to.be_nil()
        end)

        t.it("没开鉴权时不会凭空发认证请求", function()
            local cli = client()
            t.expect(assert(cli:revoke("12345")).status).to.equal(200)
            t.expect(cli.jwt_token).to.be_nil()
            t.expect(#state.requests).to.equal(1)
            t.expect(dump_logs():find("etcd request end", 1, true)).to.be_type("number")
        end)
    end)
end)
