local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local codec = require "skyext.etcd.codec"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd/lease.lua")

local function harness(opts)
    opts = opts or {}
    local h = { posts = {} }

    local fake_transport = {}
    function fake_transport.post(_, uri, body, timeout)
        h.posts[#h.posts + 1] = { uri = uri, body = body, timeout = timeout }
        if opts.on_post then
            return opts.on_post(h)
        end
        return { status = 200, body = { ID = "7587848", TTL = "10" } }
    end

    local modules = { ["skyext.etcd.transport"] = fake_transport }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    h.lease = assert(loadfile(source, "t", env))().methods
    h.cli = { timeout = 5 }
    return h
end

local function last(h)
    return h.posts[#h.posts]
end

t.describe("etcd.lease", function()
    t.describe("grant", function()
        t.it("申请租约带上 TTL，ID 默认 0 让 etcd 分配", function()
            local h = harness()
            local res = assert(h.lease.grant(h.cli, 10))
            t.expect(last(h).uri).to.equal("/v3/lease/grant")
            t.expect(last(h).body.TTL).to.equal(10)
            t.expect(last(h).body.ID).to.equal(0)
            t.expect(res.body.ID).to.equal("7587848")
        end)

        t.it("可以指定租约 ID", function()
            local h = harness()
            h.lease.grant(h.cli, 10, "42")
            t.expect(last(h).body.ID).to.equal("42")
        end)

        t.it("TTL 不是数字时报错且不发请求", function()
            local h = harness()
            local res, err = h.lease.grant(h.cli, "10")
            t.expect(res).to.be_nil()
            t.expect(err).to.match("TTL")
            t.expect(#h.posts).to.equal(0)

            t.expect(select(2, h.lease.grant(h.cli, nil))).to.match("TTL")
            t.expect(#h.posts).to.equal(0)
        end)
    end)

    t.describe("revoke / keepalive", function()
        t.it("revoke 带上租约 ID", function()
            local h = harness()
            h.lease.revoke(h.cli, "7587848")
            t.expect(last(h).uri).to.equal("/v3/lease/revoke")
            t.expect(last(h).body.ID).to.equal("7587848")
        end)

        t.it("keepalive 带上租约 ID", function()
            local h = harness()
            h.lease.keepalive(h.cli, "7587848")
            t.expect(last(h).uri).to.equal("/v3/lease/keepalive")
            t.expect(last(h).body.ID).to.equal("7587848")
        end)

        -- 租约 ID 是 int64，etcd 用字符串返回，续约时必须原样带回去，
        -- 中途转成 number 会在超过 2^53 时丢精度，续到别的租约上
        t.it("租约 ID 原样透传，不做数字转换", function()
            local h = harness()
            h.lease.keepalive(h.cli, "9007199254740993")
            t.expect(last(h).body.ID).to.equal("9007199254740993")
            t.expect(type(last(h).body.ID)).to.equal("string")
        end)

        t.it("缺少 ID 时报错且不发请求", function()
            local h = harness()
            t.expect(select(2, h.lease.revoke(h.cli, nil))).to.match("ID")
            t.expect(select(2, h.lease.keepalive(h.cli, nil))).to.match("ID")
            t.expect(#h.posts).to.equal(0)
        end)
    end)

    t.describe("timetolive", function()
        t.it("默认不要 key 列表", function()
            local h = harness()
            h.lease.timetolive(h.cli, "7587848")
            t.expect(last(h).uri).to.equal("/v3/lease/timetolive")
            t.expect(last(h).body.keys).to.equal(false)
        end)

        t.it("要 key 列表时解码返回的 key", function()
            local h = harness({
                on_post = function()
                    return {
                        status = 200,
                        body = {
                            ID = "7587848",
                            keys = { codec.encode_base64("/node/a"), codec.encode_base64("/node/b") },
                        },
                    }
                end,
            })
            local res = assert(h.lease.timetolive(h.cli, "7587848", true))
            t.expect(last(h).body.keys).to.equal(true)
            t.expect(res.body.keys[1]).to.equal("/node/a")
            t.expect(res.body.keys[2]).to.equal("/node/b")
        end)

        t.it("租约已过期时返回体没有 keys 也不报错", function()
            local h = harness({
                on_post = function()
                    return { status = 200, body = { ID = "7587848", TTL = "-1" } }
                end,
            })
            local res = assert(h.lease.timetolive(h.cli, "7587848", true))
            t.expect(res.body.TTL).to.equal("-1")
        end)

        t.it("缺少 ID 时报错", function()
            local h = harness()
            t.expect(select(2, h.lease.timetolive(h.cli, nil))).to.match("ID")
            t.expect(#h.posts).to.equal(0)
        end)
    end)

    t.it("leases 不带请求体", function()
        local h = harness()
        h.lease.leases(h.cli)
        t.expect(last(h).uri).to.equal("/v3/lease/leases")
        t.expect(last(h).body).to.be_nil()
    end)
end)
