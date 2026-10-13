local t = require "skytest"
local skynet = require "skynet"
local time = require "skyext.time"
local timer = require "skyext.timer"

-- skynet.sleep 的单位是 1/100 秒
local function sleep_ms(ms)
    skynet.sleep(ms // 10)
end

-- 占住工作线程的忙等（模拟慢回调），带 CPU 时间兜底避免测试卡死
local function busy_wait_ms(ms)
    local deadline = time.now_ms() + ms
    local cpu_deadline = os.clock() + ms / 1000 * 4 + 1
    while time.now_ms() < deadline and os.clock() < cpu_deadline do
    end
end

t.describe("timer", function()
    t.after_each(function()
        timer.shutdown()
    end)

    t.it("runs a one-shot timer once", function()
        local count = 0
        timer.timeout("one_shot", 0, function()
            count = count + 1
        end)
        sleep_ms(200)
        t.expect(count).to.equal(1)
        sleep_ms(200)
        t.expect(count).to.equal(1)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("cancels a pending timer", function()
        local count = 0
        local obj = timer.timeout("cancel_me", 0.1, function()
            count = count + 1
        end)
        obj:cancel()
        t.expect(timer.active_count()).to.equal(0)
        sleep_ms(400)
        t.expect(count).to.equal(0)
    end)

    t.it("wakeup pulls the execution forward", function()
        local count = 0
        local obj = timer.timeout("wake_me", 30, function()
            count = count + 1
        end)
        sleep_ms(50)
        t.expect(count).to.equal(0)
        obj:wakeup()
        sleep_ms(200)
        t.expect(count).to.equal(1)
    end)

    t.it("wakeup on a cancelled timer is a no-op", function()
        local count = 0
        local obj = timer.timeout("cancelled", 30, function()
            count = count + 1
        end)
        obj:cancel()
        obj:wakeup()
        sleep_ms(200)
        t.expect(count).to.equal(0)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("repeats exactly the requested number of times", function()
        local count = 0
        timer.repeat_immediately("limited", 0.05, function()
            count = count + 1
        end, 3)
        sleep_ms(800)
        t.expect(count).to.equal(3)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("runs every due timer of a large batch", function()
        local count = 0
        for i = 1, 100 do
            timer.timeout("batch_" .. i, 0, function()
                count = count + 1
            end)
        end
        sleep_ms(500)
        t.expect(count).to.equal(100)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("schedules the next run after a slow callback finishes (no overlap)", function()
        local interval_ms = 300
        local cost_ms = 150
        local starts = {}
        timer.repeat_immediately("slow", interval_ms / 1000, function()
            starts[#starts + 1] = time.now_ms()
            busy_wait_ms(cost_ms)
        end, 3)
        sleep_ms(2000)
        t.expect(#starts).to.equal(3)
        for i = 2, #starts do
            local gap = starts[i] - starts[i - 1]
            -- 下一次的计时基准是回调结束时刻：间隔 >= 执行耗时 + interval（留出调度误差）
            t.expect(gap).to.be_gte(interval_ms + cost_ms * 0.8)
        end
    end)

    t.it("keeps running other timers when one callback throws", function()
        local good = 0
        timer.repeat_immediately("bad", 0.05, function()
            error("callback failure on purpose")
        end, 1)
        timer.repeat_immediately("good", 0.05, function()
            good = good + 1
        end, 2)
        sleep_ms(500)
        t.expect(good).to.equal(2)
    end)

    t.it("shutdown stops scheduling and clears timers", function()
        local count = 0
        timer.repeat_immediately("stopped", 0.05, function()
            count = count + 1
        end)
        sleep_ms(200)
        t.expect(count).to.be_gt(0)
        timer.shutdown()
        t.expect(timer.active_count()).to.equal(0)
        local after_shutdown = count
        sleep_ms(400)
        t.expect(count).to.equal(after_shutdown)
    end)

    t.it("can be restarted after shutdown", function()
        timer.repeat_immediately("before", 0.05, function() end)
        sleep_ms(100)
        timer.shutdown()

        local count = 0
        timer.repeat_immediately("after", 0.05, function()
            count = count + 1
        end, 2)
        sleep_ms(500)
        t.expect(count).to.equal(2)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("shutdown inside a callback is safe", function()
        local count = 0
        timer.repeat_immediately("self_shutdown", 0.05, function()
            count = count + 1
            timer.shutdown()
        end)
        sleep_ms(400)
        t.expect(count).to.equal(1)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("cancel inside a callback stops further runs", function()
        local count = 0
        local obj
        obj = timer.repeat_immediately("self_cancel", 0.05, function()
            count = count + 1
            obj:cancel()
        end)
        sleep_ms(400)
        t.expect(count).to.equal(1)
        t.expect(timer.active_count()).to.equal(0)
    end)

    t.it("validates callback and interval arguments", function()
        t.expect(function()
            timer.timeout("bad_func", 1, nil)
        end).to
            .throw("timer callback must be a function")
        t.expect(function()
            timer.repeat_delayed("bad_interval", -1, function() end)
        end).to
            .throw("timer interval must be a non%-negative number")
    end)

    t.it("supports sub second intervals for random delayed timers", function()
        local count = 0
        timer.repeat_random_delayed("sub_second", 0.2, function()
            count = count + 1
        end, 1)
        sleep_ms(600)
        t.expect(count).to.equal(1)
    end)
end)
