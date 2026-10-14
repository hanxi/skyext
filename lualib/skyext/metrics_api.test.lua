local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/metrics_api.lua")

local SELF = 0x01000009
local METRICS_SERVICE = 0x01000002

local function harness(opts)
    opts = opts or {}
    local h = {
        timers = {},
        registered = {},
        warns = {},
        service = opts.service,
        snapshot = opts.snapshot or { { name = "a_total", kind = "counter", samples = {} } },
        stat = { mqlen = 3, cpu = 1.25, message = 42 },
    }
    local imports = {
        skynet = {
            self = function()
                return SELF
            end,
            localname = function(name)
                t.expect(name).to.equal(".metrics")
                return h.service
            end,
            timeout = function(interval, fn)
                h.timers[#h.timers + 1] = { interval = interval, fn = fn }
            end,
            stat = function(what)
                return h.stat[what]
            end,
            call = function(addr, proto, cmd, arg)
                h.cmd_ready_at_register = h.CMD ~= nil
                h.registered[#h.registered + 1] = { addr = addr, proto = proto, cmd = cmd, arg = arg }
                if h.call_error then
                    error(h.call_error, 0)
                end
                return true
            end,
        },
        ["skyext.cmd_api"] = {
            register = function(CMD)
                h.CMD = CMD
            end,
        },
        ["skyext.log"] = {
            warn = function(...)
                h.warns[#h.warns + 1] = table.concat({ ... }, " ")
            end,
        },
        ["skyext.metrics"] = {
            collect = function()
                return h.snapshot
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.api = assert(loadfile(source, "t", env))()
    return h
end

-- 跑掉当前排队的定时器；注册重试会排新的，所以每轮先把队列摘走
local function run_timers(h)
    local pending = h.timers
    h.timers = {}
    for _, timer in ipairs(pending) do
        timer.fn()
    end
    return #pending
end

t.describe("metrics_api 注册", function()
    t.it("注册动作挪到定时器里做：cmd_api.dispatch 时还在服务初始化中", function()
        local h = harness({ service = METRICS_SERVICE })
        h.api.ensure_registered()
        t.expect(#h.registered).to.equal(0)
        t.expect(h.timers[1].interval).to.equal(0)

        run_timers(h)
        t.expect(h.registered[1]).to.equal({
            addr = METRICS_SERVICE,
            proto = "lua",
            cmd = "register_service",
            arg = SELF,
        })
        t.expect(h.api.registered()).to.be_truthy()
    end)

    t.it("先挂上 collect_metrics 再注册：注册完 .metrics 随时可能来拉", function()
        local h = harness({ service = METRICS_SERVICE })
        h.api.ensure_registered()
        run_timers(h)

        t.expect(h.cmd_ready_at_register).to.be_truthy()
        t.expect(h.CMD.collect_metrics).to.be_type("function")
    end)

    t.it("重复调用只注册一次", function()
        local h = harness({ service = METRICS_SERVICE })
        h.api.ensure_registered()
        h.api.ensure_registered()
        h.api.ensure_registered()
        t.expect(#h.timers).to.equal(1)
    end)

    t.it(".metrics 不注册自己：抓取时直接读本地指标就行", function()
        local h = harness({ service = SELF })
        h.api.ensure_registered()
        run_timers(h)

        t.expect(#h.registered).to.equal(0)
        t.expect(h.CMD).to.be_nil()
        t.expect(#h.timers).to.equal(0)
        t.expect(h.warns).to.equal({})
    end)
end)

t.describe("metrics_api .metrics 还没起来", function()
    t.it("按秒重试，起来之后补上注册", function()
        local h = harness()
        h.api.ensure_registered()
        run_timers(h)
        t.expect(#h.registered).to.equal(0)
        t.expect(h.timers[1].interval).to.equal(100)

        h.service = METRICS_SERVICE
        run_timers(h)
        t.expect(#h.registered).to.equal(1)
    end)

    t.it("重试 10 次后放弃，不能一直占着定时器", function()
        local h = harness()
        h.api.ensure_registered()
        local rounds = 0
        while run_timers(h) > 0 do
            rounds = rounds + 1
            t.expect(rounds).to.be_lte(20)
        end

        t.expect(rounds).to.equal(10)
        t.expect(#h.registered).to.equal(0)
        t.expect(h.warns[1]).to.contain("metrics service not found")
        t.expect(h.api.registered()).to.be_falsy()
    end)

    t.it("注册调用抛错时只记警告，不把业务服务带崩", function()
        local h = harness({ service = METRICS_SERVICE })
        h.call_error = "metrics service died"
        h.api.ensure_registered()
        t.expect(function()
            run_timers(h)
        end).to_not
            .throw()

        t.expect(h.warns[1]).to.contain("metrics register failed")
        t.expect(h.api.registered()).to.be_falsy()
    end)
end)

t.describe("metrics_api collect_metrics", function()
    t.it("回包里带上本服务的指标快照和运行时数据", function()
        local h = harness({ service = METRICS_SERVICE })
        h.api.ensure_registered()
        run_timers(h)

        local payload = h.CMD.collect_metrics()
        t.expect(payload.metrics).to.equal(h.snapshot)
        t.expect(payload.runtime.mqlen).to.equal(3)
        t.expect(payload.runtime.cpu).to.equal(1.25)
        t.expect(payload.runtime.message).to.equal(42)
        -- collectgarbage 返回的是 KB，换算成字节并取整
        t.expect(payload.runtime.memory).to.be_gt(0)
        t.expect(math.type(payload.runtime.memory)).to.equal("integer")
    end)
end)
