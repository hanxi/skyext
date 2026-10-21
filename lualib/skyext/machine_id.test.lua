local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/machine_id.lua")

local function harness(node_name)
    local h = { attempts = {}, forks = {}, sleeps = {}, taken = {}, locks = {}, logs = {} }
    h.node_name = node_name or "rolenode1"

    local imports = {
        skynet = {
            fork = function(f)
                h.forks[#h.forks + 1] = f
            end,
            sleep = function(ticks)
                h.sleeps[#h.sleeps + 1] = ticks
                if h.on_sleep then
                    h.on_sleep()
                end
            end,
        },
        ["skyext.config"] = {
            get = function(name)
                t.expect(name).to.equal("cluster_node_name")
                return h.node_name
            end,
        },
        ["skyext.log"] = {
            info = function(msg, ...)
                h.logs[#h.logs + 1] = { "info", msg, ... }
            end,
            warn = function(msg, ...)
                h.logs[#h.logs + 1] = { "warn", msg, ... }
            end,
            error = function(msg, ...)
                h.logs[#h.logs + 1] = { "error", msg, ... }
            end,
        },
        ["skyext.distributed_lock"] = {
            try_lock = function(key, value, expired_cb)
                h.attempts[#h.attempts + 1] = key
                if h.lock_error then
                    return false, h.lock_error
                end
                if h.taken[key] then
                    return false, "lock held", "other-node"
                end
                local handle = { key = key, value = value, expired_cb = expired_cb, valid = true }
                h.locks[key] = handle
                return true, handle
            end,
            is_valid = function(handle)
                return handle ~= nil and handle.valid
            end,
            unlock = function(key, handle)
                h.unlocked = key
                if h.unlock_error then
                    return false, h.unlock_error
                end
                handle.valid = false
                h.locks[key] = nil
                return true
            end,
        },
    }

    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.machine_id = assert(loadfile(source, "t", env))()

    -- 模拟租约过期：distributed_lock 会把句柄置为失效再回调
    function h.expire(key)
        local handle = assert(h.locks[key], "no lock on " .. key)
        handle.valid = false
        h.locks[key] = nil
        handle.expired_cb()
    end

    function h.run_forks()
        local pending = h.forks
        h.forks = {}
        for _, f in ipairs(pending) do
            f()
        end
    end

    return h
end

t.describe("machine_id claim", function()
    t.it("takes the first free slot and holds a lease on it", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        t.expect(#h.attempts).to.equal(1)
        t.expect(h.attempts[1]).to.equal(string.format("machine_id/snowflake/%d", slot.id))
        t.expect(slot.id).to.be_gte(0)
        t.expect(slot.id).to.be_lt(1024)
        t.expect(slot:valid()).to.equal(true)
        -- 锁上记的是节点名，便于在 etcd 里看出号被谁占着
        t.expect(h.locks[h.attempts[1]].value).to.equal("rolenode1")
    end)

    t.it("probes forward past the slots other nodes already hold", function()
        local h = harness()
        local probe = h.machine_id.new("snowflake", 1024)
        probe:acquire()
        local first = probe.id
        h.taken[string.format("machine_id/snowflake/%d", first)] = true
        h.taken[string.format("machine_id/snowflake/%d", (first + 1) % 1024)] = true

        local h2 = harness()
        h2.taken = h.taken
        local slot = h2.machine_id.new("snowflake", 1024)
        slot:acquire()
        t.expect(slot.id).to.equal((first + 2) % 1024)
        t.expect(#h2.attempts).to.equal(3)
    end)

    t.it("starts from the same slot for the same node and a different one for another", function()
        local same = harness("rolenode1")
        local first = same.machine_id.new("snowflake", 1024)
        first:acquire()
        local again = harness("rolenode1")
        local second = again.machine_id.new("snowflake", 1024)
        second:acquire()
        -- 重启后大概率拿回原来的号，日志和排查都方便
        t.expect(second.id).to.equal(first.id)

        local other = harness("rolenode2")
        local third = other.machine_id.new("snowflake", 1024)
        third:acquire()
        t.expect(third.id == first.id).to.equal(false)
    end)

    t.it("wraps around the end of the range", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 4)
        -- 号段只有 4 个，探测必然要绕回 0
        slot:acquire()
        t.expect(slot.id).to.be_lt(4)
        local wrapped = h.machine_id.new("snowflake", 4)
        h.taken[h.attempts[1]] = true
        wrapped:acquire()
        t.expect(wrapped.id).to.be_lt(4)
        t.expect(wrapped.id == slot.id).to.equal(false)
    end)

    t.it("stops probing when etcd itself is unavailable and retries later", function()
        local h = harness()
        h.lock_error = "etcd lease unavailable"
        h.on_sleep = function()
            h.lock_error = nil
        end
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        -- etcd 不可用时把整个号段试一遍只是白费请求
        t.expect(#h.attempts).to.equal(2)
        t.expect(#h.sleeps).to.equal(1)
        -- 第一轮只等 0.1 秒：启动期租约还没批下来这种失败毫秒级就恢复了，
        -- 固定睡 5 秒会让整个节点干等
        t.expect(h.sleeps[1]).to.equal(10)
        t.expect(slot:valid()).to.equal(true)
    end)

    t.it("backs off exponentially up to a five second cap", function()
        local h = harness()
        h.lock_error = "etcd lease unavailable"
        local rounds = 0
        h.on_sleep = function()
            rounds = rounds + 1
            if rounds == 8 then
                h.lock_error = nil
            end
        end
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        -- 翻倍到 5 秒封顶：etcd 真的长时间挂了也不会把重试打成风暴
        t.expect(h.sleeps).to.equal({ 10, 20, 40, 80, 160, 320, 500, 500 })
        t.expect(slot:valid()).to.equal(true)
    end)

    t.it("gives up a round after the probe limit and keeps retrying", function()
        local h = harness()
        local rounds = 0
        h.on_sleep = function()
            rounds = rounds + 1
            if rounds == 1 then
                h.taken = {}
            end
        end
        setmetatable(h.taken, {
            __index = function()
                return true
            end,
        })
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        t.expect(#h.attempts).to.equal(65)
        t.expect(rounds).to.equal(1)
        t.expect(slot.id).to.exist()
        local failure
        for _, entry in ipairs(h.logs) do
            if entry[1] == "error" then
                failure = entry
            end
        end
        t.expect(failure[6]).to.equal("no free slot")
    end)

    t.it("rejects a bad name or range", function()
        local h = harness()
        t.expect(function()
            h.machine_id.new("", 16)
        end).to
            .throw("name required")
        t.expect(function()
            h.machine_id.new("snowflake", 0)
        end).to
            .throw("positive integer")
        t.expect(function()
            h.machine_id.new("snowflake", 10.5)
        end).to
            .throw("positive integer")
    end)
end)

t.describe("machine_id lease loss", function()
    t.it("reports the slot as unusable and claims a different one", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        local lost = slot.id

        h.expire(string.format("machine_id/snowflake/%d", lost))
        t.expect(slot:valid()).to.equal(false)
        t.expect(slot.id).to.be_nil()

        h.run_forks()
        t.expect(slot:valid()).to.equal(true)
        -- 丢过的号不原地捡回来：接手的进程可能已经用它发过 ID
        t.expect(slot.id == lost).to.equal(false)
    end)

    t.it("ignores an expiry that belongs to a slot it already moved off", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        local first_key = h.attempts[1]
        local stale = h.locks[first_key]

        h.expire(first_key)
        h.run_forks()
        local current = slot.id
        t.expect(slot:valid()).to.equal(true)

        -- 上一轮的句柄再回调一次，不能把现在这个号也顶掉
        stale.expired_cb()
        t.expect(slot.id).to.equal(current)
        t.expect(slot:valid()).to.equal(true)
        t.expect(#h.forks).to.equal(0)
    end)

    t.it("does not start a second claim loop while one is already running", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        h.lock_error = "etcd lease unavailable"
        h.on_sleep = function()
            -- 抢号协程还在循环里，这时再调一次 acquire 不该叠加一轮探测
            slot:acquire()
            h.lock_error = nil
        end
        slot:acquire()
        t.expect(#h.attempts).to.equal(2)
        t.expect(slot:valid()).to.equal(true)
    end)
end)

t.describe("machine_id release", function()
    t.it("gives the slot back so a quick restart gets the same number", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        local key = h.attempts[1]
        t.expect(slot:release()).to.equal(true)
        t.expect(h.unlocked).to.equal(key)
        t.expect(slot:valid()).to.equal(false)
        t.expect(slot.id).to.be_nil()
    end)

    t.it("never re-acquires after release", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        local handle = h.locks[h.attempts[1]]
        slot:release()
        -- 释放之后迟到的过期回调不能把号又抢回来
        handle.expired_cb()
        h.run_forks()
        t.expect(#h.attempts).to.equal(1)
        slot:acquire()
        t.expect(#h.attempts).to.equal(1)
    end)

    t.it("reports a failed unlock", function()
        local h = harness()
        local slot = h.machine_id.new("snowflake", 1024)
        slot:acquire()
        h.unlock_error = "etcd unavailable"
        t.expect(slot:release()).to.equal(false)
        t.expect(slot:valid()).to.equal(false)
    end)
end)
