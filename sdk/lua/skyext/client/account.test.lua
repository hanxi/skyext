-- skyext.client.account 的单测。用假 httpc 钉住三件事：
--   1. 每个接口打的 URL、方法、请求体和 Bearer 头（token 绝不进 URL）
--   2. 业务错误（code ≠ OK）原样透传给调用方，不当成传输失败
--   3. 多 host 时传输失败/抛错换下一台，业务失败不换
local t = require "skytest"
local skynet = require "skynet" -- luacheck: ignore 211 (skytest 需要 skynet 环境)
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "sdk/lua/skyext/client/account.lua")

local function harness(opts)
    opts = opts or {}
    local h = { requests = {}, script = opts.script or {}, logs = {} }

    local fake_httpc = {
        request = function(method, host, url, _, header, body)
            h.requests[#h.requests + 1] = { method = method, host = host, url = url, header = header, body = body }
            local step = h.script[#h.requests]
            if not step then
                error("unexpected request: " .. method .. " " .. url)
            end
            if step.err then
                error(step.err)
            end
            return step.status, step.body
        end,
    }

    local fake_log = {}
    for _, level in ipairs({ "info", "warn", "error", "debug" }) do
        fake_log[level] = function(...)
            h.logs[#h.logs + 1] = { level = level, ... }
        end
    end

    local imports = {
        ["skyext.httpc"] = fake_httpc,
        ["skyext.log"] = fake_log,
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    local M = assert(loadfile(source, "t", env))()

    h.account = M.new({ hosts = opts.hosts or { "http://account1" } })
    return h
end

local function json(v)
    return require("cjson.safe").encode(v)
end

t.describe("client.account 开发登录", function()
    t.it("dev_login 成功返回 token，请求体带账号名", function()
        local h = harness({ script = { { status = 200, body = json({ code = 0, token = "tok" }) } } })
        local token = h.account:dev_login("robot1")
        t.expect(token).to.equal("tok")
        t.expect(#h.requests).to.equal(1)
        t.expect(h.requests[1].method).to.equal("POST")
        t.expect(h.requests[1].url).to.equal("/dev_login")
        t.expect(h.requests[1].body).to.equal(json({ account = "robot1" }))
    end)

    t.it("dev_login 业务失败返回 nil，不换 host", function()
        local h = harness({
            hosts = { "http://a1", "http://a2" },
            script = { { status = 200, body = json({ code = 102 }) } },
        })
        t.expect(h.account:dev_login("robot1")).to.be_nil()
        -- code ≠ OK 是有效应答，再换一台问一遍不会变出 token 来
        t.expect(#h.requests).to.equal(1)
    end)

    t.it("dev_login 非 200 换下一台", function()
        local h = harness({
            hosts = { "http://a1", "http://a2" },
            script = {
                { status = 502, body = "bad gateway" },
                { status = 200, body = json({ code = 0, token = "tok2" }) },
            },
        })
        t.expect(h.account:dev_login("robot1")).to.equal("tok2")
        t.expect(#h.requests).to.equal(2)
        t.expect(h.requests[1].host ~= h.requests[2].host).to.be_truthy()
    end)

    t.it("连接抛错也换下一台，全失败返回 nil", function()
        local h = harness({
            hosts = { "http://a1", "http://a2" },
            script = { { err = "connection refused" }, { status = 500 } },
        })
        t.expect(h.account:dev_login("robot1")).to.be_nil()
        t.expect(#h.requests).to.equal(2)
    end)
end)

t.describe("client.account 鉴权头", function()
    t.it("roles 带 Bearer 头，token 不进 URL", function()
        local h = harness({
            script = { { status = 200, body = json({ code = 0, roles = { { rid = 7 } } }) } },
        })
        local roles = h.account:roles("tok")
        t.expect(roles[1].rid).to.equal(7)
        t.expect(h.requests[1].url).to.equal("/roles")
        t.expect(h.requests[1].header.authorization).to.equal("Bearer tok")
    end)

    t.it("create_role 同时带 Bearer 头和 JSON 体", function()
        local h = harness({
            script = { { status = 200, body = json({ code = 0, role = { rid = 9 } }) } },
        })
        local role = h.account:create_role("tok", "s1", "robot1")
        t.expect(role.rid).to.equal(9)
        t.expect(h.requests[1].method).to.equal("POST")
        t.expect(h.requests[1].header.authorization).to.equal("Bearer tok")
        t.expect(h.requests[1].header["content-type"]).to.equal("application/json")
        t.expect(h.requests[1].body).to.equal(json({ server = "s1", name = "robot1" }))
    end)
end)

t.describe("client.account 选服与角色", function()
    t.it("pick_recommended_server 优先取 recommended", function()
        local h = harness({
            script = {
                {
                    status = 200,
                    body = json({
                        code = 0,
                        servers = { { server = "s1" }, { server = "s2", recommended = true } },
                    }),
                },
            },
        })
        t.expect(h.account:pick_recommended_server()).to.equal("s2")
    end)

    t.it("没有 recommended 时取第一个", function()
        local h = harness({
            script = { { status = 200, body = json({ code = 0, servers = { { server = "s3" }, { server = "s4" } } }) } },
        })
        t.expect(h.account:pick_recommended_server()).to.equal("s3")
    end)

    t.it("ensure_role 有角色取第一个，只打一次接口", function()
        local h = harness({
            script = { { status = 200, body = json({ code = 0, roles = { { rid = 1 }, { rid = 2 } } }) } },
        })
        t.expect(h.account:ensure_role("tok", "robot1", "s1").rid).to.equal(1)
        t.expect(#h.requests).to.equal(1)
    end)

    t.it("ensure_role 没角色时在指定服建角", function()
        local h = harness({
            script = {
                { status = 200, body = json({ code = 0, roles = {} }) },
                { status = 200, body = json({ code = 0, role = { rid = 8, server = "s1" } }) },
            },
        })
        local role = h.account:ensure_role("tok", "robot1", "s1")
        t.expect(role.rid).to.equal(8)
        t.expect(#h.requests).to.equal(2)
        t.expect(h.requests[2].url).to.equal("/create_role")
    end)
end)

t.describe("client.account 网关发现", function()
    t.it("gates 返回在线网关列表", function()
        local h = harness({
            script = {
                {
                    status = 200,
                    body = json({
                        code = 0,
                        gates = { { node = "gate1", tcp_addr = "127.0.0.1:7052", ws_url = "ws://127.0.0.1:7053" } },
                    }),
                },
            },
        })
        local gates = h.account:gates()
        t.expect(#gates).to.equal(1)
        t.expect(gates[1].node).to.equal("gate1")
        t.expect(h.requests[1].header).to.be_nil() -- 免登录接口不带鉴权头
    end)

    t.it("接口失败返回 nil", function()
        local h = harness({ script = { { status = 404, body = "not found" } } })
        t.expect(h.account:gates()).to.be_nil()
    end)
end)
