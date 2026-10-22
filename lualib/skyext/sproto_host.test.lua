local t = require "skytest"
local sproto = require "sproto"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/sproto_host.lua")
local sproto_host = assert(loadfile(source))()

local SCHEMA = [[
.base {
    .package {
        type 0 : integer
        session 1 : integer
    }
}

echo 100 {
    request {
        text 0 : string
    }
    response {
        text 0 : string
    }
}

# 没有 response：host 要把 pending 登记成 true
note 101 {
    request {
        text 0 : string
    }
}
]]

-- 两端各一个 host，共用同一份 schema：发出去的包直接喂给对端的 dispatch
local function pair()
    local sp = sproto.parse(SCHEMA)
    local a, b = sproto_host.new(sp, "base.package"), sproto_host.new(sp, "base.package")
    return a, a:attach(), b, b:attach()
end

t.describe("sproto_host", function()
    t.it("把客户端的 request id 当第 5 个返回值交出来", function()
        local client, send, server = pair()
        local msg_type, name, request, response_cb, req_id = server:dispatch(send("echo", { text = "hi" }, 7))
        t.expect(msg_type).to.equal("REQUEST")
        t.expect(name).to.equal("echo")
        t.expect(request.text).to.equal("hi")
        t.expect(req_id).to.equal(7)

        local kind, id, body = client:dispatch(response_cb({ text = "ho" }))
        t.expect(kind).to.equal("RESPONSE")
        t.expect(id).to.equal(7)
        t.expect(body.text).to.equal("ho")
    end)

    t.it("对端没带 request id 时不生成回包函数", function()
        local _, send, server = pair()
        local msg_type, name, request, response_cb, req_id = server:dispatch(send("echo", { text = "hi" }))
        t.expect(msg_type).to.equal("REQUEST")
        t.expect(name).to.equal("echo")
        t.expect(request.text).to.equal("hi")
        t.expect(response_cb).to.be_nil()
        t.expect(req_id).to.be_nil()
    end)

    t.it("没有 response 的协议回一个空包，仍然认得出 id", function()
        local client, send, server = pair()
        local _, _, _, response_cb = server:dispatch(send("note", { text = "hi" }, 3))
        local kind, id, body = client:dispatch(response_cb())
        t.expect(kind).to.equal("RESPONSE")
        t.expect(id).to.equal(3)
        t.expect(body).to.be_nil()
    end)

    -- 续接之后同一个请求会有两份响应：重放出来的那份，和按原 id 重发后命中服务端幂等
    -- 缓存的那份。第二份到达时 pending 已经清了，这里要是抛错，调用方连「收到过一个包」
    -- 都不知道，下行计数当场失同步
    t.it("认不出的 request id 不抛错，交出 id 让调用方计数后丢弃", function()
        local client, send, server = pair()
        local _, _, _, response_cb = server:dispatch(send("echo", { text = "hi" }, 9))
        local pack = response_cb({ text = "ho" })
        client:dispatch(pack)

        local ok, kind, id, body = pcall(client.dispatch, client, pack)
        t.expect(ok).to.be_truthy()
        t.expect(kind).to.equal("RESPONSE")
        t.expect(id).to.equal(9)
        t.expect(body).to.be_nil()
    end)
end)
