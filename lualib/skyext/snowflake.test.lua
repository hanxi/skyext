local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/snowflake.lua")

local SEQUENCE_BIT = 13
local MACHINE_BIT = 8
local MAX_SEQUENCE = (1 << SEQUENCE_BIT) - 1
local MAX_MACHINE_ID = (1 << MACHINE_BIT) - 1
local TIMESTAMP_LEFT = SEQUENCE_BIT + MACHINE_BIT

-- 把 ID 拆回三段，断言才能说清是哪一段错了
local function decode(id)
    return {
        ts = id >> TIMESTAMP_LEFT,
        machine = (id >> SEQUENCE_BIT) & MAX_MACHINE_ID,
        seq = id & MAX_SEQUENCE,
    }
end

-- opts.machine_id   固定机器号（对应 snowflake_machine_id 配置）
-- opts.start_date   时间起点
-- opts.slot_valid   未配固定号时，etcd 槽位当前是否在手上
local function harness(opts)
    opts = opts or {}
    local h = {
        now = opts.now or os.time({ year = 2026, month = 1, day = 1, hour = 12 }),
        sleeps = 0,
        warns = {},
        order = {},
        slot_valid = opts.slot_valid,
    }

    local fake_slot = {
        id = opts.slot_id or 3,
        valid = function()
            return h.slot_valid ~= false
        end,
        acquire = function()
            h.acquired = true
            h.order[#h.order + 1] = "acquire"
        end,
        release = function()
            h.released = true
            return true
        end,
    }

    local imports = {
        skynet = {
            init = function(fn)
                fn()
            end,
            start = function(fn)
                fn()
            end,
            time = function()
                return h.now
            end,
            sleep = function(ticks)
                h.sleeps = h.sleeps + 1
                h.now = h.now + ticks / 100
                if h.on_sleep then
                    h.on_sleep()
                end
            end,
            fork = function(fn)
                fn()
            end,
        },
        ["skynet.service"] = {
            new = function(name, fn)
                h.service_name = name
                fn()
                return 100
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                h.CMD = cmd
                h.order[#h.order + 1] = "dispatch"
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("snowflake_start_date")
                return opts.start_date
            end,
            get_number = function(key)
                t.expect(key).to.equal("snowflake_machine_id")
                return opts.machine_id
            end,
        },
        ["skyext.node_shutdown_api"] = {
            add_hook = function(phase, cmd)
                h.hook = { phase, cmd }
            end,
        },
        ["skyext.machine_id"] = {
            new = function(name, size)
                h.slot_name = name
                h.slot_size = size
                return fake_slot
            end,
        },
        ["skyext.log"] = {
            info = function() end,
            warn = function(msg)
                h.warns[#h.warns + 1] = msg
            end,
            error = function() end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.module = assert(loadfile(source, "t", env))()
    return h
end

t.describe("snowflake id generation", function()
    t.it("把时间、机器号、序列号拼进同一个 64 位整数的固定位段", function()
        local h = harness({ machine_id = 9 })
        local id = h.CMD.newid()
        local parts = decode(id)
        t.expect(parts.machine).to.equal(9)
        -- 符号位必须空着：ID 要能安全地当有符号整数传
        t.expect(id).to.be_gt(0)
        -- 时间段是相对起点的秒数，不是绝对时间戳
        local begin_ts = os.time({ year = 2025, month = 10, day = 9, hour = 0 })
        t.expect(parts.ts).to.equal(h.now - begin_ts)
    end)

    t.it("同一秒内连续取号严格递增", function()
        local h = harness({ machine_id = 1 })
        local prev = h.CMD.newid()
        for _ = 1, 100 do
            local id = h.CMD.newid()
            t.expect(id).to.be_gt(prev)
            prev = id
        end
    end)

    t.it("进入新的一秒后序列号归零", function()
        local h = harness({ machine_id = 1 })
        h.CMD.newid()
        h.CMD.newid()
        t.expect(decode(h.CMD.newid()).seq).to.equal(3)
        h.now = h.now + 1
        t.expect(decode(h.CMD.newid()).seq).to.equal(0)
    end)

    t.it("时钟回拨时直接报错，不发可能重复的号", function()
        local h = harness({ machine_id = 1 })
        h.CMD.newid()
        h.now = h.now - 5
        t.expect(function()
            h.CMD.newid()
        end).to
            .throw("clock moved backwards")
    end)

    t.it("序列号用尽时等到下一秒再发，而不是回绕复用", function()
        local h = harness({ machine_id = 1 })
        local first_second = decode(h.CMD.newid()).ts
        -- 第一次取号已经吃掉 seq=1，再取满 MAX_SEQUENCE 就会触发溢出
        local last
        for _ = 1, MAX_SEQUENCE do
            last = h.CMD.newid()
        end
        t.expect(h.sleeps).to.be_gte(1)
        t.expect(#h.warns).to.equal(1)
        local parts = decode(last)
        t.expect(parts.seq).to.equal(0)
        t.expect(parts.ts).to.be_gt(first_second)
    end)

    t.it("配置的起点日期决定时间段的基准", function()
        local h = harness({ machine_id = 1, start_date = "2026-01-01" })
        local begin_ts = os.time({ year = 2026, month = 1, day = 1, hour = 0 })
        t.expect(decode(h.CMD.newid()).ts).to.equal(h.now - begin_ts)
    end)

    t.it("起点日期格式非法时启动就失败，不带着错误基准跑起来", function()
        t.expect(function()
            harness({ machine_id = 1, start_date = "2026/01/01" })
        end).to
            .throw("invalid date format")
    end)

    t.it("固定机器号超出位宽时启动失败", function()
        t.expect(function()
            harness({ machine_id = MAX_MACHINE_ID + 1 })
        end).to
            .throw("invalid machine_id")
    end)

    t.it("没配固定机器号时按位宽容量去抢 etcd 槽位", function()
        local h = harness()
        t.expect(h.slot_name).to.equal("snowflake")
        t.expect(h.slot_size).to.equal(MAX_MACHINE_ID + 1)
        t.expect(h.acquired).to.equal(true)
        t.expect(decode(h.CMD.newid()).machine).to.equal(3)
    end)

    t.it("机器号一直不在手上时等一会儿后拒绝发号", function()
        -- 接手这个号的进程可能正在用同一个 (时间, 机器号)，发出去就是重复 ID
        local h = harness({ slot_valid = false })
        t.expect(function()
            h.CMD.newid()
        end).to
            .throw("machine id is not held")
        t.expect(h.sleeps).to.equal(30)
        t.expect(function()
            h.CMD.newids(5)
        end).to
            .throw("machine id is not held")
    end)

    -- 回归：启动时 id_generator 抢在机器号到手之前预取，以前直接报错刷一条 error
    t.it("机器号还在抢的时候先等它到手再发号", function()
        local h = harness({ slot_valid = false })
        h.on_sleep = function()
            if h.sleeps == 3 then
                h.slot_valid = true
            end
        end
        t.expect(decode(h.CMD.newid()).machine).to.equal(3)
        t.expect(h.sleeps).to.equal(3)
    end)

    t.it("先开始收消息再去抢号，etcd 没就绪时启动不会卡住", function()
        -- 反过来先抢号，etcd 不可用时服务会卡在启动里，调用方一律超时而不是拿到明确报错
        local h = harness()
        t.expect(h.order).to.equal({ "dispatch", "acquire" })
    end)

    t.it("newids 返回的是一段连续递增的号", function()
        local h = harness({ machine_id = 2 })
        local list = h.CMD.newids(5)
        t.expect(list).to.have_length(5)
        for i = 2, #list do
            t.expect(list[i]).to.be_gt(list[i - 1])
        end
    end)

    t.it("newids 的 count 非法时退化成 1 条，不报错也不返回空表", function()
        local h = harness({ machine_id = 2 })
        t.expect(h.CMD.newids()).to.have_length(1)
        t.expect(h.CMD.newids("abc")).to.have_length(1)
        t.expect(h.CMD.newids(0)).to.have_length(1)
        t.expect(h.CMD.newids(-7)).to.have_length(1)
        -- 字符串数字要能用：GM/HTTP 传过来的参数都是字符串
        t.expect(h.CMD.newids("3")).to.have_length(3)
    end)

    t.it("newids 一次要太多时报错，不让单次调用占住服务", function()
        local h = harness({ machine_id = 2 })
        t.expect(h.CMD.newids(10000)).to.have_length(10000)
        t.expect(function()
            h.CMD.newids(10001)
        end).to
            .throw("count is too large")
    end)
end)

t.describe("snowflake 停服", function()
    t.it("抢号的节点挂 release 钩子，停服时归还机器号", function()
        local h = harness()
        t.expect(h.hook).to.equal({ "release", "shutdown" })
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(h.released).to.equal(true)
    end)

    t.it("写死机器号的节点没有号可还，也不挂钩子", function()
        local h = harness({ machine_id = 4 })
        t.expect(h.hook).to.be_nil()
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(h.released).to.be_nil()
    end)
end)
