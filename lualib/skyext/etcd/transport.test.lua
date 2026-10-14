local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local cjson = require "cjson.safe"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd/transport.lua")

-- opts.respond(host, uri, body) 返回 status, body；返回 nil 表示这次请求直接抛错（连不上）
local function harness(opts)
    opts = opts or {}
    local h = { requests = {}, logs = {}, now = 0, timeouts = {} }

    local httpc = { timeout = 1000 }
    function httpc.request(_, host, uri, _, headers, body)
        h.requests[#h.requests + 1] = {
            host = host,
            uri = uri,
            headers = headers,
            body = body and cjson.decode(body) or nil,
        }
        h.timeouts[#h.timeouts + 1] = httpc.timeout
        if opts.respond then
            local status, res = opts.respond(host, uri, body)
            if not status then
                error(res or "connect failed")
            end
            return status, res
        end
        return 200, cjson.encode({ header = { revision = 1 } })
    end
    function httpc.request_stream(_, host, uri, _, _, body)
        h.requests[#h.requests + 1] =
            { host = host, uri = uri, body = body and cjson.decode(body) or nil, stream = true }
        h.timeouts[#h.timeouts + 1] = httpc.timeout
        if opts.stream_error then
            error(opts.stream_error)
        end
        return { status = 200 }
    end
    h.httpc = httpc

    local function record(...)
        h.logs[#h.logs + 1] = table.concat({ ... }, " ")
    end

    local modules = {
        ["http.httpc"] = httpc,
        ["skyext.time"] = {
            now = function()
                return h.now
            end,
        },
        ["skyext.log"] = {
            debug = function() end,
            info = function() end,
            warn = record,
            error = record,
            xpcall_msgh = function(err)
                return err
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    h.transport = assert(loadfile(source, "t", env))()
    return h
end

local function client(h, hosts, extra)
    local endpoints = assert(h.transport.parse_endpoints(hosts))
    local cli = {
        endpoints = endpoints,
        fail_expired_time = {},
        timeout = 5,
    }
    for k, v in pairs(extra or {}) do
        cli[k] = v
    end
    return cli
end

t.describe("etcd.transport", function()
    t.describe("parse_endpoints", function()
        t.it("接受单个字符串", function()
            local h = harness()
            local eps = assert(h.transport.parse_endpoints("http://127.0.0.1:2379"))
            t.expect(#eps).to.equal(1)
            t.expect(eps[1].http_host).to.equal("http://127.0.0.1:2379")
            t.expect(eps[1].scheme).to.equal("http")
            t.expect(eps[1].host).to.equal("127.0.0.1")
            t.expect(eps[1].port).to.equal("2379")
        end)

        t.it("接受字符串数组", function()
            local h = harness()
            local eps = assert(h.transport.parse_endpoints({ "http://a:2379", "https://b:2380" }))
            t.expect(#eps).to.equal(2)
            t.expect(eps[2].scheme).to.equal("https")
            t.expect(eps[2].port).to.equal("2380")
        end)

        t.it("省略端口时按 scheme 取默认值", function()
            local h = harness()
            local eps = assert(h.transport.parse_endpoints({ "http://a", "https://b" }))
            t.expect(eps[1].port).to.equal("2379")
            t.expect(eps[2].port).to.equal("443")
        end)

        -- 配置写错时必须在 new() 就报出来，而不是等到第一次请求才连不上
        t.it("缺少 scheme 直接报错", function()
            local h = harness()
            local eps, err = h.transport.parse_endpoints({ "127.0.0.1:2379" })
            t.expect(eps).to.be_nil()
            t.expect(err).to.match("invalid http_host")
        end)

        t.it("空配置直接报错", function()
            local h = harness()
            t.expect(select(2, h.transport.parse_endpoints({}))).to.match("required")
            t.expect(select(2, h.transport.parse_endpoints(nil))).to.match("required")
        end)
    end)

    t.describe("post", function()
        t.it("把 body 编成 JSON 发到选中的端点", function()
            local h = harness()
            local cli = client(h, "http://127.0.0.1:2379")
            local res = assert(h.transport.post(cli, "/v3/kv/put", { key = "a" }, 5))
            t.expect(res.status).to.equal(200)
            t.expect(h.requests[1].host).to.equal("http://127.0.0.1:2379")
            t.expect(h.requests[1].uri).to.equal("/v3/kv/put")
            t.expect(h.requests[1].body.key).to.equal("a")
        end)

        t.it("空 body 不发请求体", function()
            local h = harness()
            local cli = client(h, "http://127.0.0.1:2379")
            h.transport.post(cli, "/v3/lease/leases", nil, 5)
            t.expect(h.requests[1].body).to.be_nil()
        end)

        -- httpc 的超时是模块级变量，发完要还原，否则会影响进程里其它 http 调用
        t.it("按本次请求的超时设置 httpc.timeout 并还原", function()
            local h = harness()
            local cli = client(h, "http://127.0.0.1:2379")
            h.transport.post(cli, "/v3/kv/put", { key = "a" }, 3)
            t.expect(h.timeouts[1]).to.equal(300)
            t.expect(h.httpc.timeout).to.equal(1000)
        end)

        t.it("请求抛错时也还原 httpc.timeout", function()
            local h = harness({
                respond = function()
                    return nil, "connect failed"
                end,
            })
            local cli = client(h, "http://127.0.0.1:2379")
            local res, err = h.transport.post(cli, "/v3/kv/put", { key = "a" }, 3)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("connect failed")
            t.expect(h.httpc.timeout).to.equal(1000)
        end)

        t.it("5xx 当作失败返回错误", function()
            local h = harness({
                respond = function()
                    return 503, "unavailable"
                end,
            })
            local cli = client(h, "http://127.0.0.1:2379")
            local res, err = h.transport.post(cli, "/v3/kv/put", { key = "a" }, 5)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("invalid response code: 503")
        end)

        t.it("401 当作凭据失效返回错误", function()
            local h = harness({
                respond = function()
                    return 401, "unauthorized"
                end,
            })
            local cli = client(h, "http://127.0.0.1:2379")
            local res, err = h.transport.post(cli, "/v3/kv/put", { key = "a" }, 5)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("insufficient credentials")
        end)

        t.it("其它非 200 原样返回，由调用方判断", function()
            local h = harness({
                respond = function()
                    return 400, cjson.encode({ error = "bad" })
                end,
            })
            local cli = client(h, "http://127.0.0.1:2379")
            local res = assert(h.transport.post(cli, "/v3/kv/put", { key = "a" }, 5))
            t.expect(res.status).to.equal(400)
            t.expect(res.body.error).to.equal("bad")
        end)
    end)

    t.describe("鉴权", function()
        t.it("开启鉴权时带上 Authorization 头", function()
            local h = harness()
            local cli = client(h, "http://127.0.0.1:2379", {
                is_auth = true,
                jwt_token = "token-1",
                authorize = function()
                    return true
                end,
            })
            h.transport.post(cli, "/v3/kv/put", { key = "a" }, 5)
            t.expect(h.requests[1].headers.Authorization).to.equal("token-1")
        end)

        t.it("ignore_auth 的请求不触发鉴权", function()
            local h = harness()
            local authorized = false
            local cli = client(h, "http://127.0.0.1:2379", {
                is_auth = true,
                authorize = function()
                    authorized = true
                    return true
                end,
            })
            h.transport.post(cli, "/v3/auth/authenticate", { name = "root" }, 5, true)
            t.expect(authorized).to.equal(false)
            t.expect(h.requests[1].headers.Authorization).to.be_nil()
        end)

        -- 拿不到 token 就不该把请求发出去：没有凭据的请求必然 401
        t.it("鉴权失败时不发请求", function()
            local h = harness()
            local cli = client(h, "http://127.0.0.1:2379", {
                is_auth = true,
                authorize = function()
                    return nil, "auth failed"
                end,
            })
            local res, err = h.transport.post(cli, "/v3/kv/put", { key = "a" }, 5)
            t.expect(res).to.be_nil()
            t.expect(err).to.equal("auth failed")
            t.expect(#h.requests).to.equal(0)
        end)
    end)

    t.describe("端点选择与故障摘除", function()
        t.it("单端点时固定用它", function()
            local h = harness()
            local cli = client(h, "http://a:2379")
            h.transport.post(cli, "/v3/kv/put", {}, 5)
            h.transport.post(cli, "/v3/kv/put", {}, 5)
            t.expect(h.requests[1].host).to.equal("http://a:2379")
            t.expect(h.requests[2].host).to.equal("http://a:2379")
        end)

        t.it("选中的端点会被粘住，不是每次都换", function()
            local h = harness()
            local cli = client(h, { "http://a:2379", "http://b:2379" })
            h.transport.post(cli, "/v3/kv/put", {}, 5)
            h.transport.post(cli, "/v3/kv/put", {}, 5)
            t.expect(h.requests[2].host).to.equal(h.requests[1].host)
        end)

        t.it("请求抛错后摘除该端点并换到另一个", function()
            local failing = {}
            local h
            h = harness({
                respond = function(host)
                    if failing[host] then
                        return nil, "connect failed"
                    end
                    return 200, cjson.encode({})
                end,
            })
            local cli = client(h, { "http://a:2379", "http://b:2379" })
            h.transport.post(cli, "/v3/kv/put", {}, 5)
            local first = h.requests[1].host
            failing[first] = true

            h.transport.post(cli, "/v3/kv/put", {}, 5)
            t.expect(h.requests[2].host).to.equal(first)
            t.expect(cli.working_endpoint).to.be_nil()

            h.transport.post(cli, "/v3/kv/put", {}, 5)
            t.expect(h.requests[3].host).to_not.equal(first)
        end)

        t.it("摘除有有效期，过期后重新参与选择", function()
            local h = harness()
            local cli = client(h, { "http://a:2379", "http://b:2379" })
            h.transport.report_failure(cli, "http://a:2379")
            t.expect(cli.fail_expired_time["http://a:2379"]).to.equal(10)

            for _ = 1, 4 do
                h.transport.post(cli, "/v3/kv/put", {}, 5)
                cli.working_endpoint = nil
            end
            for _, req in ipairs(h.requests) do
                t.expect(req.host).to.equal("http://b:2379")
            end

            h.now = 11
            local seen = {}
            for _ = 1, 20 do
                h.transport.post(cli, "/v3/kv/put", {}, 5)
                cli.working_endpoint = nil
            end
            for _, req in ipairs(h.requests) do
                seen[req.host] = true
            end
            t.expect(seen["http://a:2379"]).to.equal(true)
        end)

        -- 全摘除时宁可试一个也不要直接放弃：etcd 可能已经恢复
        t.it("所有端点都在摘除期内仍然发出请求", function()
            local h = harness()
            local cli = client(h, { "http://a:2379", "http://b:2379" })
            h.transport.report_failure(cli, "http://a:2379")
            h.transport.report_failure(cli, "http://b:2379")
            local res = h.transport.post(cli, "/v3/kv/put", {}, 5)
            t.expect(res).to.exist()
            t.expect(#h.requests).to.equal(1)
        end)
    end)

    t.describe("post_stream", function()
        t.it("成功时带上客户端与端点，供 watch 关闭与报错使用", function()
            local h = harness()
            local cli = client(h, "http://127.0.0.1:2379")
            local ret = assert(h.transport.post_stream(cli, "/v3/watch", { create_request = {} }, 5))
            t.expect(ret.cli).to.equal(cli)
            t.expect(ret.endpoint.http_host).to.equal("http://127.0.0.1:2379")
            t.expect(ret.stream.status).to.equal(200)
            t.expect(h.requests[1].stream).to.equal(true)
        end)

        t.it("建流失败时摘除端点并返回错误", function()
            local h = harness({ stream_error = "connect failed" })
            local cli = client(h, "http://127.0.0.1:2379")
            local ret, err = h.transport.post_stream(cli, "/v3/watch", {}, 5)
            t.expect(ret).to.be_nil()
            t.expect(err).to.match("connect failed")
            t.expect(cli.fail_expired_time["http://127.0.0.1:2379"]).to.exist()
        end)
    end)
end)
