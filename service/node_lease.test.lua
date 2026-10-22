local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/node_lease.lua")

local function harness(opts)
    opts = opts or {}
    local h = { now = 0, lease = 0, grants = 0, keepalives = 0, events = {} }

    local client = {}
    function client:grant(ttl)
        t.expect(ttl).to.equal(30)
        h.grants = h.grants + 1
        if h.fail_grant then
            return nil, "no quorum"
        end
        h.lease = h.lease + 1
        return { status = 200, body = { ID = tostring(h.lease) } }
    end
    function client:keepalive(lease)
        h.keepalives = h.keepalives + 1
        h.last_keepalive = lease
        if h.keepalive_result == "unreachable" then
            return nil, "connection refused"
        elseif h.keepalive_result == "server_error" then
            return { status = 503, body = {} }
        elseif h.keepalive_result == "gone" then
            -- etcd 明确回答租约已不存在：TTL 归零
            return { status = 200, body = { result = { TTL = 0, ID = lease } } }
        elseif h.keepalive_result == "gone_elided" then
            -- 同一件事的真实线上形态：JSON 网关把 protobuf 零值字段整个省掉，
            -- 所以租约没了的响应里压根没有 TTL 这一项
            return { status = 200, body = { result = { ID = lease } } }
        elseif h.keepalive_result == "malformed" then
            return { status = 200, body = {} }
        end
        return { status = 200, body = { result = { TTL = 30, ID = lease } } }
    end
    function client:revoke(lease)
        h.revoked = lease
        if h.fail_revoke then
            return nil, "no quorum"
        end
        return { status = 200, body = {} }
    end

    local noop = function() end
    local imports = {
        skynet = {
            start = function(fn)
                h.boot = fn
            end,
            now = function()
                return h.now
            end,
        },
        ["skyext.etcd"] = {
            new = function()
                return client
            end,
        },
        ["skyext.timer"] = {
            repeat_delayed = function(name, sec, fn)
                h.heartbeat_name = name
                h.heartbeat_interval = sec
                h.heartbeat = fn
                return {
                    cancel = function()
                        h.heartbeat_cancelled = true
                    end,
                }
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(commands)
                h.CMD = commands
            end,
        },
        ["skyext.event_channel_api"] = {
            init = noop,
            publish = function(cmd, ...)
                h.events[#h.events + 1] = { cmd, ... }
            end,
        },
        ["skyext.config"] = {
            get_table = function()
                return {}
            end,
        },
        ["skyext.log"] = { debug = noop, info = noop, warn = noop, error = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()

    h.fail_grant = opts.fail_grant
    h.boot()
    h.fail_grant = nil

    function h.last_event()
        return h.events[#h.events]
    end
    function h.count_events(cmd)
        local n = 0
        for _, ev in ipairs(h.events) do
            if ev[1] == cmd then
                n = n + 1
            end
        end
        return n
    end
    return h
end

t.describe("node lease lifecycle", function()
    t.it("holds a usable lease as soon as the service starts", function()
        local h = harness()
        t.expect(h.grants).to.equal(1)
        t.expect(h.heartbeat_name).to.equal("node_lease_heartbeat")
        t.expect(h.heartbeat_interval).to.equal(10)

        local snapshot = h.CMD.get()
        t.expect(snapshot.leaseid).to.equal("1")
        t.expect(snapshot.epoch).to.equal(1)
        -- TTL 30 减 2 秒余量，单位是 skynet.now() 的 1/100 秒刻度
        t.expect(snapshot.deadline).to.equal(2800)
        t.expect(h.last_event()).to.equal({ "lease_alive", "1", 1, 2800 })
    end)

    t.it("pushes the deadline forward on every confirmed keepalive", function()
        local h = harness()
        h.now = 1000
        h.heartbeat()
        t.expect(h.keepalives).to.equal(1)
        t.expect(h.grants).to.equal(1)
        t.expect(h.CMD.get().deadline).to.equal(3800)
        t.expect(h.last_event()).to.equal({ "lease_alive", "1", 1, 3800 })
    end)

    t.it("starts anyway when etcd cannot grant and recovers on the next heartbeat", function()
        local h = harness({ fail_grant = true })
        t.expect(h.grants).to.equal(1)
        t.expect(h.CMD.get()).to.be_nil()

        h.heartbeat()
        t.expect(h.grants).to.equal(2)
        t.expect(h.keepalives).to.equal(0)
        t.expect(h.CMD.get().epoch).to.equal(1)
    end)
end)

-- 这里是 P0 的回归点。原来只要一次续租没成功就立刻隔离本节点的全部实体，
-- etcd 一次 GC 抖动或 leader 切换（都是秒级、远短于 30 秒 TTL）就能把全服玩家踢掉。
t.describe("node lease keepalive tolerance", function()
    local function transient(kind)
        t.it("tolerates a transient keepalive failure: " .. kind, function()
            local h = harness()
            h.keepalive_result = kind

            -- 宽限期内连续失败两拍：租约必须还在
            h.now = 1000
            h.heartbeat()
            h.now = 2000
            h.heartbeat()
            t.expect(h.count_events("lease_lost")).to.equal(0)
            t.expect(h.CMD.get().epoch).to.equal(1)
            t.expect(h.CMD.get().deadline).to.equal(2800)

            -- etcd 恢复：deadline 继续往后推，期间一次也没隔离过
            h.keepalive_result = nil
            h.now = 2700
            h.heartbeat()
            t.expect(h.CMD.get().deadline).to.equal(5500)
            t.expect(h.count_events("lease_lost")).to.equal(0)
            t.expect(h.grants).to.equal(1)
        end)
    end

    transient("unreachable")
    transient("server_error")
    transient("malformed")

    t.it("gives up and re-grants once the grace period is really exhausted", function()
        local h = harness()
        h.keepalive_result = "unreachable"
        h.now = 1000
        h.heartbeat()
        t.expect(h.count_events("lease_lost")).to.equal(0)

        -- 宽限期（TTL 30 - 2 秒余量）走完：租约这次是真的可以认为没了
        h.now = 2800
        h.heartbeat()
        t.expect(h.count_events("lease_lost")).to.equal(1)
        t.expect(h.last_event()).to.equal({ "lease_alive", "2", 2, 5600 })
        t.expect(h.grants).to.equal(2)
        t.expect(h.CMD.get().epoch).to.equal(2)
    end)

    -- etcd 明确回答"这个租约不存在了"是确定性结论，没有理由再等 28 秒宽限期：
    -- 锁键此刻已经被 etcd 删掉，别的节点随时可能接手同一个实体。
    local function gone(kind)
        t.it("isolates immediately when etcd reports the lease is gone (" .. kind .. ")", function()
            local h = harness()
            h.keepalive_result = kind
            h.now = 100
            h.heartbeat()
            t.expect(h.count_events("lease_lost")).to.equal(1)
            -- 同一拍里就换了新租约
            t.expect(h.grants).to.equal(2)
            t.expect(h.CMD.get().epoch).to.equal(2)
        end)
    end

    gone("gone")
    gone("gone_elided")

    t.it("reports the lease as unavailable once the deadline elapses without a heartbeat", function()
        local h = harness()
        h.now = 2800
        t.expect(h.CMD.get()).to.be_nil()
        t.expect(h.count_events("lease_lost")).to.equal(1)
    end)
end)

t.describe("node lease shutdown", function()
    t.it("revokes the lease without reporting it as lost and stops renewing", function()
        local h = harness()
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(h.revoked).to.equal("1")
        t.expect(h.heartbeat_cancelled).to.equal(true)
        -- 主动放手不是失租：失租回调的语义是"别人可能已经接手了"，
        -- machine_id 收到就会去重新抢号，停服时不该触发
        t.expect(h.count_events("lease_lost")).to.equal(0)
        t.expect(h.CMD.get()).to.be_nil()
        -- 再调一次没有租约可撤
        t.expect(h.CMD.shutdown()).to.equal(true)
    end)

    t.it("reports a failed revoke and leaves the keys to expire with the lease", function()
        local h = harness()
        h.fail_revoke = true
        t.expect(h.CMD.shutdown()).to.equal(false)
    end)
end)
