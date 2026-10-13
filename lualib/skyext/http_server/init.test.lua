local t = require "skytest"
local http_server = require "skyext.http_server"

local PUBLIC_ROUTER = "skyext.http_server.fixtures.public_router"
local ADMIN_ROUTER = "skyext.http_server.fixtures.admin_router"

t.describe("http_server 命名实例", function()
    local public_host, admin_host

    t.before_all(function()
        local public_server = http_server.new("test_public")
        local public_info = public_server:start({ host = "127.0.0.1", port = 0, agent_count = 2 })
        public_server:register_router(PUBLIC_ROUTER)
        public_host = "127.0.0.1:" .. public_info.port

        local admin_server = http_server.new("test_admin")
        local admin_info = admin_server:start({ host = "127.0.0.1", port = 0, agent_count = 1 })
        admin_server:register_router(ADMIN_ROUTER)
        admin_host = "127.0.0.1:" .. admin_info.port

        assert(public_info.port ~= admin_info.port, "two instances must listen on different ports")
    end)

    t.it("同名实例复用同一个对象", function()
        t.expect(http_server.new("test_public")).to.equal(http_server.new("test_public"))
        t.expect(http_server.new("test_public")).to_not.equal(http_server.new("test_admin"))
    end)

    t.it("非法实例名直接报错", function()
        t.expect(function()
            http_server.new("bad name")
        end).to
            .throw("invalid http server name")
        t.expect(function()
            http_server.new(nil)
        end).to
            .throw("invalid http server name")
    end)

    t.it("各实例提供自己的路由", function()
        local status, body = t.http.get_json(public_host, "/public/ping")
        t.expect(status).to.equal(200)
        t.expect(body).to.equal({ scope = "public", path = "/public/ping" })

        status, body = t.http.get_json(admin_host, "/admin/ping")
        t.expect(status).to.equal(200)
        t.expect(body).to.equal({ scope = "admin", path = "/admin/ping" })
    end)

    t.it("路由不会泄漏到其它实例的端口", function()
        local status = t.http.get(public_host, "/admin/ping")
        t.expect(status).to.equal(404)

        status = t.http.get(admin_host, "/public/ping")
        t.expect(status).to.equal(404)

        -- admin 实例没有注册任何 POST 路由
        status = t.http.post(admin_host, "/public/echo", "{}", "application/json")
        t.expect(status).to.equal(405)
    end)

    t.it("register_router 对实例内所有 agent 生效", function()
        -- agent_count = 2，轮询派发，连续请求应全部命中
        for _ = 1, 6 do
            local status, body = t.http.get_json(public_host, "/public/ping")
            t.expect(status).to.equal(200)
            t.expect(body.scope).to.equal("public")
        end
    end)

    t.it("POST 路由可用", function()
        local status, body = t.http.post_json(public_host, "/public/echo", { msg = "hello" })
        t.expect(status).to.equal(200)
        t.expect(body).to.equal({ scope = "public", echo = "hello" })
    end)

    t.it("重复 start 同一实例会报错", function()
        t.expect(function()
            http_server.new("test_public"):start({ host = "127.0.0.1", port = 0 })
        end).to
            .throw("already started")
    end)

    t.it("未启动的实例不能注册路由", function()
        t.expect(function()
            http_server.new("test_never_started"):register_router(PUBLIC_ROUTER)
        end).to
            .throw("not started")
    end)
end)
