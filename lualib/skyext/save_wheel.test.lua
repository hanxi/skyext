local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/save_wheel.lua")

local function harness()
    local h = { forks = {}, logs = {}, timers = {} }

    local imports = {
        skynet = {
            fork = function(f)
                h.forks[#h.forks + 1] = f
            end,
        },
        ["skyext.timer"] = {
            repeat_delayed = function(name, sec, f)
                h.timers[#h.timers + 1] = { name = name, sec = sec }
                h.tick_fn = f
                return { cancel = function() end }
            end,
        },
        ["skyext.log"] = {
            warn = function(msg)
                h.logs[#h.logs + 1] = { "warn", msg }
            end,
            info = function(msg)
                h.logs[#h.logs + 1] = { "info", msg }
            end,
            xpcall_msgh = function(err)
                h.logs[#h.logs + 1] = { "error", err }
                return err
            end,
        },
    }

    -- 落槽是随机的，测试里换成可控的序号，才能把条目放进指定的槽
    local fake_math = setmetatable({
        random = function(low, high)
            local slot = h.next_slot or low
            h.next_slot = nil
            assert(slot >= low and slot <= high, "slot out of range")
            return slot
        end,
    }, { __index = math })

    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
        math = fake_math,
    }, { __index = _G })
    h.wheel = assert(loadfile(source, "t", env))()

    -- 跑一次 tick：定时器回调只负责起协程，真正刷槽的是 fork 出去的那段
    function h.tick(skip_fork)
        assert(h.tick_fn, "timer not started")()
        if skip_fork then
            return
        end
        local pending = h.forks
        h.forks = {}
        for _, f in ipairs(pending) do
            f()
        end
    end

    function h.flush_forks()
        local pending = h.forks
        h.forks = {}
        for _, f in ipairs(pending) do
            f()
        end
    end

    return h
end

local function counter(h)
    local seen = {}
    return seen,
        function(entry)
            seen[entry] = (seen[entry] or 0) + 1
            if h.on_entry then
                h.on_entry(entry)
            end
        end
end

t.describe("save_wheel layout", function()
    t.it("splits the period into one slot per second", function()
        local h = harness()
        local w = h.wheel.new("dbmgr", 180, function() end)
        t.expect(w.slot_count).to.equal(180)
        t.expect(w.tick).to.equal(1)
    end)

    t.it("degrades to a single slot for a sub-second period without stretching it", function()
        local h = harness()
        local w = h.wheel.new("dbmgr", 0.5, function() end)
        t.expect(w.slot_count).to.equal(1)
        t.expect(w.tick).to.equal(0.5)
    end)

    t.it("rejects a non-positive period and a missing callback", function()
        local h = harness()
        t.expect(function()
            h.wheel.new("dbmgr", 0, function() end)
        end).to
            .throw("positive number")
        t.expect(function()
            h.wheel.new("dbmgr", 10)
        end).to
            .throw("must be a function")
    end)

    t.it("starts one timer no matter how many entries join, and none before the first", function()
        local h = harness()
        local w = h.wheel.new("dbmgr", 4, function() end)
        t.expect(#h.timers).to.equal(0)
        w:add({})
        w:add({})
        w:add({})
        t.expect(#h.timers).to.equal(1)
        t.expect(h.timers[1].sec).to.equal(1)
    end)
end)

t.describe("save_wheel rotation", function()
    t.it("processes every entry exactly once per full rotation", function()
        local h = harness()
        local seen, on_entry = counter(h)
        local w = h.wheel.new("dbmgr", 3, on_entry)
        local entries = {}
        for slot = 1, 3 do
            h.next_slot = slot
            entries[slot] = {}
            w:add(entries[slot])
        end
        t.expect(w.count).to.equal(3)

        for slot = 1, 3 do
            h.tick()
            t.expect(seen[entries[slot]]).to.equal(1)
        end
        for slot = 1, 3 do
            t.expect(seen[entries[slot]]).to.equal(1)
        end
        -- 第二轮每个条目再处理一次，节奏不漂
        for _ = 1, 3 do
            h.tick()
        end
        for slot = 1, 3 do
            t.expect(seen[entries[slot]]).to.equal(2)
        end
    end)

    t.it("never processes a removed entry again", function()
        local h = harness()
        local seen, on_entry = counter(h)
        local w = h.wheel.new("dbmgr", 2, on_entry)
        h.next_slot = 1
        local gone = {}
        w:add(gone)
        t.expect(w:remove(gone)).to.equal(true)
        t.expect(w:remove(gone)).to.equal(false)
        t.expect(w.count).to.equal(0)
        h.next_slot = 1
        local kept = {}
        w:add(kept)

        h.tick()
        h.tick()
        t.expect(seen[gone]).to.be_nil()
        t.expect(seen[kept]).to.equal(1)
    end)

    t.it("skips an entry removed by an earlier callback in the same slot", function()
        local h = harness()
        local seen, on_entry = counter(h)
        local w = h.wheel.new("dbmgr", 2, on_entry)
        local first, second = {}, {}
        h.next_slot = 1
        w:add(first)
        h.next_slot = 1
        w:add(second)
        -- 刷槽时回调会让出，让出期间同槽的另一个条目可能被卸载
        h.on_entry = function()
            w:remove(first)
            w:remove(second)
        end

        h.tick()
        local processed = (seen[first] or 0) + (seen[second] or 0)
        t.expect(processed).to.equal(1)
        t.expect(w.count).to.equal(0)
    end)

    t.it("keeps sweeping the slot after one entry blows up", function()
        local h = harness()
        local seen, on_entry = counter(h)
        local w = h.wheel.new("dbmgr", 2, on_entry)
        local bad, good = {}, {}
        h.next_slot = 1
        w:add(bad)
        h.next_slot = 1
        w:add(good)
        h.on_entry = function(entry)
            if entry == bad then
                error("save blew up")
            end
        end

        h.tick()
        t.expect(seen[good]).to.equal(1)
        t.expect(seen[bad]).to.equal(1)
        t.expect(h.logs[1][1]).to.equal("error")
        t.expect(h.logs[1][2]).to.match("save blew up")
    end)

    t.it("keeps turning after a flush raises outside the callback", function()
        local h = harness()
        local w = h.wheel.new("dbmgr", 2, function() end)
        h.next_slot = 1
        w:add({})
        -- 槽表被抽掉，刷槽本身就会抛错；flushing 要是卡在 true，轮子就再也不转了
        local slots = w.slots
        w.slots = nil
        h.tick()
        w.slots = slots
        t.expect(w.flushing).to.equal(false)
    end)
end)

t.describe("save_wheel backpressure", function()
    t.it("drops a tick while the previous flush is still running", function()
        local h = harness()
        local seen, on_entry = counter(h)
        local w = h.wheel.new("dbmgr", 2, on_entry)
        local slot1, slot2 = {}, {}
        h.next_slot = 1
        w:add(slot1)
        h.next_slot = 2
        w:add(slot2)

        -- 第一个 tick 的刷槽协程还没跑完
        h.tick(true)
        t.expect(#h.forks).to.equal(1)
        h.tick(true)
        h.tick(true)
        t.expect(#h.forks).to.equal(1)

        h.flush_forks()
        t.expect(seen[slot1]).to.equal(1)
        t.expect(seen[slot2]).to.be_nil()
        -- 慢只是让周期变长，指针不会被跳过的 tick 带着空转
        h.tick()
        t.expect(seen[slot2]).to.equal(1)
    end)

    t.it("warns once while behind and reports catching up", function()
        local h = harness()
        local w = h.wheel.new("dbmgr", 2, function() end)
        h.next_slot = 1
        w:add({})

        h.tick(true)
        h.tick(true)
        h.tick(true)
        local warns = 0
        for _, entry in ipairs(h.logs) do
            if entry[1] == "warn" then
                warns = warns + 1
                t.expect(entry[2]).to.match("falling behind")
            end
        end
        t.expect(warns).to.equal(1)

        h.flush_forks()
        h.tick()
        t.expect(h.logs[#h.logs][1]).to.equal("info")
        t.expect(h.logs[#h.logs][2]).to.match("caught up")
    end)
end)
