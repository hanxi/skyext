local t = require "skytest"
local skynet = require "skynet"
local sproto = require "sproto"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local errcode = require "skyext.errcode"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/sproto_api.lua")

-- sprotoparser 不允许协议名里带 "."，而 register_module 生成的名字一定是 "模块.命令"，
-- 所以协议用下划线命名，再由 schema 代理做一次 "role.ping" -> "role_ping" 的映射。
local SCHEMA = [[
.base {
    .package {
        type 0 : integer
        session 1 : integer
        ud 2 : integer
    }
}

# response 带 errcode，拒绝时可以把错误码回给客户端
role_login_info 200 {
    request {
        rid 0 : integer
    }
    response {
        errcode 0 : integer
        name 1 : string
    }
}

# response 没有任何错误码字段
role_ping 201 {
    request {}
    response {
        name 0 : string
    }
}

# 没有 response
role_note 202 {
    request {
        text 0 : string
    }
}

# 老协议用 code 承载错误码
role_legacy 203 {
    request {}
    response {
        code 0 : integer
        name 1 : string
    }
}

# 不走 with_request 的模块
plain_echo 204 {
    request {}
    response {
        errcode 0 : integer
        name 1 : string
    }
}
]]

local function wire_name(request_name)
    return (request_name:gsub("%.", "_"))
end

local function harness(opts)
    opts = opts or {}
    local h = { written = {}, disconnects = {}, handlers = {}, fd = 9 }
    local noop = function() end
    local schema = sproto.parse(SCHEMA)
    h.schema = schema
    h.server_host = schema:host("base.package")
    h.client_host = schema:host("base.package")
    h.client_send = h.client_host:attach(schema)

    local proxy = {}
    function proxy:host(packagename)
        return schema:host(packagename)
    end
    function proxy:default(name, kind)
        return schema:default(wire_name(name), kind)
    end

    local fake_skynet = setmetatable({
        init = function(fn)
            h.boot = fn
        end,
        uniqueservice = function()
            return 101
        end,
        call = function(_, _, cmd)
            t.expect(cmd).to.equal("load_proto")
            return true, { checksum = "deadbeef" }
        end,
        register_protocol = function(p)
            h.protocol = p
        end,
    }, { __index = skynet })

    local imports = {
        skynet = fake_skynet,
        ["skynet.socket"] = {
            write = function(fd, data)
                h.written[#h.written + 1] = { fd = fd, data = data }
            end,
        },
        ["skynet.netpack"] = {
            pack = function(pack)
                return pack, #pack
            end,
        },
        ["skyext.event_channel_api"] = { subscribe = noop },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("sproto_schema_path")
                return "test.sproto"
            end,
            get_number = function()
                return 1
            end,
        },
        ["skyext.log"] = { debug = noop, info = noop, warn = noop, error = noop },
        ["skyext.errcode"] = errcode,
        sprotoloader = {
            load = function()
                return proxy
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.api = assert(loadfile(source, "t", env))()
    h.boot()

    local function handler(request, fd, obj)
        h.last = { request = request, fd = fd, obj = obj }
        local f = h.handlers[h.current] or function()
            return { name = "ok" }
        end
        return f(request, fd, obj)
    end

    h.module = {
        get_obj = function()
            return h.obj
        end,
        with_request = opts.with_request or function(_, f)
            if h.reject then
                return false, h.reject
            end
            local result = table.pack(f())
            return true, table.unpack(result, 1, result.n)
        end,
        reject_client = function(fd, reason)
            h.disconnects[#h.disconnects + 1] = { fd = fd, reason = reason }
        end,
        middleware_cbs = {},
    }
    h.api.register_module("role", h.module, {
        login_info = handler,
        ping = handler,
        note = handler,
        legacy = handler,
    })
    -- 没有 with_request / reject_client 的普通模块
    h.api.register_module("plain", { get_obj = h.module.get_obj }, { echo = handler })

    -- 发一个客户端请求，返回解析后的回包（没有回包时返回 nil）
    function h:request(cmd, params, session)
        self.current = cmd
        local msg = self.client_send(wire_name(cmd), params or {}, session)
        local kind, _, request, response_cb = self.server_host:dispatch(msg)
        t.expect(kind).to.equal("REQUEST")
        self.api.raw_dispatch(self.fd, "REQUEST", cmd, request, response_cb)
        local written = table.remove(self.written, 1)
        if not written then
            return nil
        end
        t.expect(written.fd).to.equal(self.fd)
        local rkind, rsession, response = self.client_host:dispatch(written.data)
        t.expect(rkind).to.equal("RESPONSE")
        t.expect(rsession).to.equal(session)
        return response or {}
    end

    return h
end

t.describe("sproto_api request dispatch", function()
    t.it("answers a normal request with the handler result", function()
        local h = harness()
        h.obj = { entity = "role-7" }
        h.handlers["role.login_info"] = function(request, fd, obj)
            t.expect(request.rid).to.equal(7)
            t.expect(fd).to.equal(9)
            t.expect(obj).to.equal(h.obj)
            return { name = "alice" }
        end
        local response = h:request("role.login_info", { rid = 7 }, 11)
        t.expect(response.name).to.equal("alice")
        -- 没写的字段不会被编码，客户端解出来就是 nil
        t.expect(response.errcode).to.be_nil()
        t.expect(h.disconnects).to.equal({})
    end)
end)

t.describe("sproto_api rejected entity request", function()
    t.it("answers the pending session with an errcode instead of letting it time out", function()
        local h = harness()
        h.reject = "client binding revoked"
        local ran = false
        h.handlers["role.login_info"] = function()
            ran = true
            return { name = "alice" }
        end
        local response = h:request("role.login_info", { rid = 7 }, 12)
        t.expect(ran).to.equal(false)
        t.expect(response.errcode).to.equal(errcode.ENTITY_NOT_FOUND)
        t.expect(response.name).to.be_nil()
        -- 错误码已经回给客户端，连接保留
        t.expect(h.disconnects).to.equal({})
    end)

    t.it("falls back to a code field when the protocol has no errcode", function()
        local h = harness()
        h.reject = "entity not loaded or lease expired"
        local response = h:request("role.legacy", {}, 13)
        t.expect(response.code).to.equal(errcode.ENTITY_NOT_FOUND)
        t.expect(h.disconnects).to.equal({})
    end)

    t.it("disconnects when the response carries no place for an errcode", function()
        local h = harness()
        h.reject = "client not bound"
        -- 不能伪造一个空回包：response 里没有错误码字段，空包在客户端看起来就是成功
        t.expect(h:request("role.ping", {}, 14)).to.be_nil()
        t.expect(#h.written).to.equal(0)
        t.expect(#h.disconnects).to.equal(1)
        t.expect(h.disconnects[1].fd).to.equal(9)
        t.expect(h.disconnects[1].reason).to.equal("client not bound")
    end)

    t.it("disconnects when the protocol has no response at all but the client waits", function()
        local h = harness()
        h.reject = "client binding revoked"
        t.expect(h:request("role.note", { text = "hi" }, 15)).to.be_nil()
        t.expect(#h.written).to.equal(0)
        t.expect(#h.disconnects).to.equal(1)
        t.expect(h.disconnects[1].reason).to.equal("client binding revoked")
    end)

    t.it("keeps a session-less client connected because nothing is waiting for a reply", function()
        local h = harness()
        h.reject = "client binding revoked"
        t.expect(h:request("role.note", { text = "hi" }, nil)).to.be_nil()
        t.expect(#h.written).to.equal(0)
        t.expect(h.disconnects).to.equal({})
    end)

    t.it("answers an errcode when a middleware rejects the request", function()
        local h = harness()
        local ran = false
        h.handlers["role.login_info"] = function()
            ran = true
        end
        h.module.middleware_cbs[1] = function()
            return nil, "banned"
        end
        local response = h:request("role.login_info", { rid = 7 }, 16)
        t.expect(ran).to.equal(false)
        t.expect(response.errcode).to.equal(errcode.ENTITY_NOT_FOUND)
    end)

    t.it("lets a middleware pick the errcode it answers with", function()
        local h = harness()
        h.module.middleware_cbs[1] = function()
            return nil, errcode.AUTH_FAILED
        end
        local response = h:request("role.login_info", { rid = 7 }, 22)
        t.expect(response.errcode).to.equal(errcode.AUTH_FAILED)
    end)
end)

t.describe("sproto_api failing handlers", function()
    t.it("answers an errcode when the handler raises", function()
        local h = harness()
        h.handlers["role.login_info"] = function()
            error("boom")
        end
        local response = h:request("role.login_info", { rid = 7 }, 17)
        t.expect(response.errcode).to.equal(errcode.ENTITY_LOAD_FAILED)
        t.expect(h.disconnects).to.equal({})
    end)

    t.it("answers an errcode when the handler returns nothing for a response protocol", function()
        local h = harness()
        h.handlers["role.login_info"] = function() end
        local response = h:request("role.login_info", { rid = 7 }, 18)
        t.expect(response.errcode).to.equal(errcode.ENTITY_LOAD_FAILED)
    end)

    t.it("answers an errcode for modules without with_request too", function()
        local h = harness()
        h.handlers["plain.echo"] = function()
            error("boom")
        end
        local response = h:request("plain.echo", {}, 19)
        t.expect(response.errcode).to.equal(errcode.ENTITY_LOAD_FAILED)
    end)

    t.it("keeps supporting modules whose with_request returns the package itself", function()
        local h = harness({
            with_request = function(_, f)
                return f()
            end,
        })
        local response = h:request("role.login_info", { rid = 7 }, 20)
        t.expect(response.name).to.equal("ok")
    end)

    t.it("answers an errcode when such a module drops the request", function()
        local h = harness({
            with_request = function()
                return nil
            end,
        })
        local response = h:request("role.login_info", { rid = 7 }, 21)
        t.expect(response.errcode).to.equal(errcode.ENTITY_LOAD_FAILED)
    end)
end)
