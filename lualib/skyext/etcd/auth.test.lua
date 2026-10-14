local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd/auth.lua")

local function harness(opts)
    opts = opts or {}
    local h = { posts = {}, now = 1000, sleeps = {} }

    local fake_transport = {}
    function fake_transport.post(_, uri, body, timeout, ignore_auth)
        h.posts[#h.posts + 1] = { uri = uri, body = body, timeout = timeout, ignore_auth = ignore_auth }
        if opts.on_post then
            return opts.on_post(h)
        end
        return { status = 200, body = { token = "token-1" } }
    end

    local modules = {
        skynet = {
            sleep = function(ticks)
                h.sleeps[#h.sleeps + 1] = ticks
                if opts.on_sleep then
                    opts.on_sleep(h)
                end
            end,
        },
        ["skyext.time"] = {
            now = function()
                return h.now
            end,
        },
        ["skyext.log"] = {
            info = function() end,
            warn = function() end,
        },
        ["skyext.etcd.transport"] = fake_transport,
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    h.authorize = assert(loadfile(source, "t", env))().methods.authorize

    h.cli = {
        timeout = 5,
        user = "root",
        password = "secret",
        is_auth = true,
        jwt_token = nil,
        last_auth_time = h.now,
        requesting_token = false,
    }
    return h
end

t.describe("etcd.auth", function()
    t.it("没有 token 时去认证并存下 token", function()
        local h = harness()
        t.expect(h.authorize(h.cli)).to.equal(true)
        t.expect(h.cli.jwt_token).to.equal("token-1")
        t.expect(h.cli.last_auth_time).to.equal(h.now)
        t.expect(#h.posts).to.equal(1)
        t.expect(h.posts[1].uri).to.equal("/v3/auth/authenticate")
        t.expect(h.posts[1].body.name).to.equal("root")
        t.expect(h.posts[1].body.password).to.equal("secret")
        -- 认证请求自己不能再去鉴权，否则会无限递归
        t.expect(h.posts[1].ignore_auth).to.equal(true)
    end)

    t.it("token 还新鲜时不发请求", function()
        local h = harness()
        h.cli.jwt_token = "token-0"
        t.expect(h.authorize(h.cli)).to.equal(true)
        t.expect(#h.posts).to.equal(0)
    end)

    -- etcd 默认签发 5 分钟，这里提前到 3 分钟刷新，3 分钟内一定不刷
    t.it("超过刷新窗口后重新认证", function()
        local h = harness()
        h.cli.jwt_token = "token-0"
        h.now = h.now + 60 * 4
        t.expect(h.authorize(h.cli)).to.equal(true)
        t.expect(#h.posts).to.equal(1)
        t.expect(h.cli.jwt_token).to.equal("token-1")
    end)

    t.it("认证失败时返回错误并记下来", function()
        local h = harness({
            on_post = function()
                return nil, "connect failed"
            end,
        })
        local ok, err = h.authorize(h.cli)
        t.expect(ok).to.be_nil()
        t.expect(err).to.equal("connect failed")
        t.expect(h.cli.last_refresh_jwt_err).to.equal("connect failed")
        t.expect(h.cli.requesting_token).to.equal(false)
    end)

    t.it("响应里没有 token 也算失败", function()
        local h = harness({
            on_post = function()
                return { status = 200, body = {} }
            end,
        })
        local ok, err = h.authorize(h.cli)
        t.expect(ok).to.be_nil()
        t.expect(err).to.match("authenticate")
        t.expect(h.cli.jwt_token).to.be_nil()
    end)

    t.describe("并发认证", function()
        -- 多个协程同时发现 token 过期时只能有一个去换，其余等结果，
        -- 否则一次过期会把 etcd 打成一串认证请求
        t.it("已有协程在认证时等待它的结果", function()
            local h = harness({
                on_sleep = function(hh)
                    hh.cli.jwt_token = "token-by-other"
                    hh.cli.last_auth_time = hh.now
                end,
            })
            h.cli.requesting_token = true
            t.expect(h.authorize(h.cli)).to.equal(true)
            t.expect(h.cli.jwt_token).to.equal("token-by-other")
            t.expect(#h.posts).to.equal(0)
            t.expect(h.sleeps[1]).to.equal(500)
        end)

        t.it("等到的是别人的失败就直接返回这个失败", function()
            local h = harness({
                on_sleep = function(hh)
                    hh.cli.last_refresh_jwt_err = "etcd down"
                end,
            })
            h.cli.requesting_token = true
            local ok, err = h.authorize(h.cli)
            t.expect(ok).to.be_nil()
            t.expect(err).to.equal("etcd down")
            t.expect(#h.posts).to.equal(0)
        end)

        -- 等完既没 token 也没错误说明状态不对，这时候宁可自己再认证一次
        t.it("等完什么都没有就自己认证", function()
            local h = harness()
            h.cli.requesting_token = true
            t.expect(h.authorize(h.cli)).to.equal(true)
            t.expect(#h.posts).to.equal(1)
        end)
    end)
end)
