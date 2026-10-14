local t = require "skytest"
local deadline = require "skyext.http_server.deadline"

-- 用真实协程模拟 skynet 的 fork/sleep/wakeup：
-- sleep 直接 yield，由 advance 推进时间并恢复，于是每次恢复都会让守卫重新算一次剩余时间
local function harness()
    local h = { now = 0, shutdowns = {} }
    local co, sleeping

    local function resume()
        if co and coroutine.status(co) == "suspended" then
            sleeping = nil
            assert(coroutine.resume(co))
        end
    end

    h.deps = {
        now = function()
            return h.now
        end,
        sleep = function(_, token)
            sleeping = token
            coroutine.yield()
        end,
        wakeup = function(token)
            if sleeping == token then
                resume()
            end
        end,
        fork = function(f, ...)
            local args = table.pack(...)
            co = coroutine.create(function()
                f(table.unpack(args, 1, args.n))
            end)
            assert(coroutine.resume(co))
        end,
        shutdown = function(fd)
            h.shutdowns[#h.shutdowns + 1] = fd
        end,
    }

    -- 推进时间并唤醒守卫协程，模拟定时器到点
    function h.advance(ticks)
        h.now = h.now + ticks
        resume()
    end

    function h.watcher_alive()
        return co ~= nil and coroutine.status(co) == "suspended"
    end

    return h
end

t.describe("deadline 超时触发", function()
    t.it("到期后 shutdown 这个 fd", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "read")
        t.expect(#h.shutdowns).to.equal(0)
        h.advance(1000)
        t.expect(h.shutdowns).to.equal({ 7 })
    end)

    t.it("未到期不动这个 fd", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "read")
        h.advance(999)
        t.expect(#h.shutdowns).to.equal(0)
        -- 没超时就不该有超时原因，否则调用方会把对端正常断开误报成超时
        t.expect(g:expired_reason()).to.be_nil()
    end)

    t.it("超时后能拿到当时的原因", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "keepalive")
        h.advance(1000)
        t.expect(g:expired_reason()).to.equal("keepalive")
    end)

    t.it("只 shutdown 一次", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(1, "read")
        h.advance(500)
        h.advance(500)
        t.expect(#h.shutdowns).to.equal(1)
    end)
end)

t.describe("deadline 延期", function()
    t.it("延期后不会在旧截止时间触发", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "keepalive")
        h.advance(500)
        -- 首字节到达，切换到读取时限
        g:set(10, "read")
        h.advance(600) -- 已越过旧截止时间 1000
        t.expect(#h.shutdowns).to.equal(0)
        t.expect(h.watcher_alive()).to.equal(true)
        h.advance(500) -- 越过新截止时间 1500
        t.expect(h.shutdowns).to.equal({ 7 })
        t.expect(g:expired_reason()).to.equal("read")
    end)

    t.it("反复延期不会堆出多个守卫协程", function()
        local h = harness()
        local forks = 0
        local raw_fork = h.deps.fork
        h.deps.fork = function(...)
            forks = forks + 1
            return raw_fork(...)
        end
        local g = deadline.new(7, h.deps)
        for _ = 1, 5 do
            g:set(10, "read")
        end
        t.expect(forks).to.equal(1)
    end)
end)

t.describe("deadline 取消", function()
    t.it("取消后不再 shutdown", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "read")
        g:cancel()
        h.advance(10000)
        t.expect(#h.shutdowns).to.equal(0)
    end)

    t.it("取消会立刻结束守卫协程，而不是挂到原截止时间", function()
        -- 否则高频短连接下，已关闭连接的守卫协程会按空闲时限堆积
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(60, "keepalive")
        t.expect(h.watcher_alive()).to.equal(true)
        g:cancel()
        t.expect(h.watcher_alive()).to.equal(false)
    end)

    t.it("取消之后还能重新启用", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "read")
        g:cancel()
        g:set(10, "write")
        h.advance(1000)
        t.expect(h.shutdowns).to.equal({ 7 })
        t.expect(g:expired_reason()).to.equal("write")
    end)

    t.it("set 传 0 等价于取消", function()
        local h = harness()
        local g = deadline.new(7, h.deps)
        g:set(10, "read")
        g:set(0, "keepalive")
        h.advance(10000)
        t.expect(#h.shutdowns).to.equal(0)
    end)
end)
