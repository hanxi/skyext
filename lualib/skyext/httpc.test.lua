local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/httpc.lua")

-- 只替身 http.httpc，cjson 用真的：编码结果本身就是这个模块的契约
local function harness(opts)
    opts = opts or {}
    local h = { requests = {} }

    local fake = { marker = "upstream-httpc" }
    function fake.request(method, host, url, recvheader, header, body)
        h.requests[#h.requests + 1] = {
            method = method,
            host = host,
            url = url,
            recvheader = recvheader,
            header = header,
            body = body,
        }
        return opts.status or 200, opts.body or "{}"
    end

    local imports = { ["http.httpc"] = fake }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.httpc = assert(loadfile(source, "t", env))()
    return h
end

t.describe("httpc post_json", function()
    t.it("post_json 是挂在 http.httpc 本体上的，普通请求照样能发", function()
        -- 模块返回的不是新表而是被加过料的 http.httpc，
        -- 调用方 require "skyext.httpc" 之后 get/request 都还在
        local h = harness()
        t.expect(h.httpc.marker).to.equal("upstream-httpc")
        t.expect(h.httpc.request).to.be_type("function")
        t.expect(h.httpc.post_json).to.be_type("function")
    end)

    t.it("以 POST + application/json 发出去，body 是编码后的 JSON", function()
        local h = harness()
        h.httpc.post_json("127.0.0.1:8080", "/api/notify", { a = 1 })

        local r = h.requests[1]
        t.expect(r.method).to.equal("POST")
        t.expect(r.host).to.equal("127.0.0.1:8080")
        t.expect(r.url).to.equal("/api/notify")
        t.expect(r.header["content-type"]).to.equal("application/json")
        t.expect(r.body).to.equal('{"a":1}')
    end)

    t.it("空表编码成 JSON 对象而不是数组", function()
        -- 对端按对象解的话，收到 [] 会直接报结构错
        local h = harness()
        h.httpc.post_json("h", "/u", {})
        t.expect(h.requests[1].body).to.equal("{}")
    end)

    t.it("200 时把响应体解成 Lua 表", function()
        local h = harness({ body = '{"code":0,"msg":"ok","list":[1,2]}' })
        local status, data = h.httpc.post_json("h", "/u", {})
        t.expect(status).to.equal(200)
        t.expect(data).to.equal({ code = 0, msg = "ok", list = { 1, 2 } })
    end)

    t.it("非 200 时原样返回状态码和没解析的响应体", function()
        -- 错误响应经常不是 JSON，硬解一道只会把现场信息抹掉
        local h = harness({ status = 500, body = "internal error" })
        local status, data = h.httpc.post_json("h", "/u", {})
        t.expect(status).to.equal(500)
        t.expect(data).to.equal("internal error")
    end)

    t.it("recvheader 原样透传给底层，调用方能拿到响应头", function()
        local h = harness()
        local recv = { probe = "mine" }
        h.httpc.post_json("h", "/u", {}, recv)
        t.expect(h.requests[1].recvheader.probe).to.equal("mine")
    end)

    t.it("200 但响应体不是合法 JSON 时第二个返回值是 nil", function()
        -- 已知毛刺：status 仍然是 200，调用方只看状态码会以为拿到了数据
        local h = harness({ body = "<html>not json</html>" })
        local status, data = h.httpc.post_json("h", "/u", {})
        t.expect(status).to.equal(200)
        t.expect(data).to.be_nil()
    end)
end)
