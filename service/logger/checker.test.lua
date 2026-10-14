local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/logger/checker.lua")

-- checker 是个服务内模块：加载期 config.init() 还没跑（skyext 的 skynet.init 回调
-- 比本模块注册的回调先执行），所以阈值必须在 init 回调里读。
-- 这里的加载顺序和线上一致：先 loadfile（配置为空）→ 注入配置 → 跑 init 回调。
local function harness(cfg)
    local h = {
        cfg = {},
        loading = true,
        reads_at_load = 0,
        mqlen = 0,
        logs = {},
        timers = {},
        init_fns = {},
    }

    local function record(level, msg, ...)
        h.logs[#h.logs + 1] = { level = level, msg = msg, args = { ... } }
    end

    h.global = { log_overload = false, bucket = { buckets = {} } }

    local fake_skynet = setmetatable({
        mqlen = function()
            return h.mqlen
        end,
        init = function(f)
            h.init_fns[#h.init_fns + 1] = f
        end,
    }, { __index = skynet })

    local imports = {
        skynet = fake_skynet,
        global = h.global,
        ["skyext.config"] = {
            get_number = function(key)
                if h.loading then
                    h.reads_at_load = h.reads_at_load + 1
                end
                return h.cfg[key]
            end,
        },
        ["skyext.log"] = {
            debug = function(...)
                record("debug", ...)
            end,
            info = function(...)
                record("info", ...)
            end,
            warn = function(...)
                record("warn", ...)
            end,
            error = function(...)
                record("error", ...)
            end,
            xpcall_msgh = debug.traceback,
        },
        ["skyext.timer"] = {
            repeat_delayed = function(name, _, f)
                h.timers[name] = f
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })

    local chunk = assert(loadfile(source, "t", env))
    chunk()
    h.loading = false

    -- 配置注入完成，然后才轮到本模块的 init 回调
    h.cfg = cfg or {}
    for _, f in ipairs(h.init_fns) do
        f()
    end
    return h
end

local function logged(h, msg)
    for _, entry in ipairs(h.logs) do
        if entry.msg == msg then
            return true
        end
    end
    return false
end

t.describe("logger checker", function()
    t.it("does not read the config at load time", function()
        local h = harness({ log_overload_mqlen = 100 })
        t.expect(h.reads_at_load).to.equal(0)
        t.expect(h.timers.log_heartbeat).to.be_type("function")
    end)

    t.it("uses the configured threshold", function()
        local h = harness({ log_overload_mqlen = 100 })
        h.mqlen = 99
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(false)

        h.mqlen = 100
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(true)
        t.expect(logged(h, "log overload on")).to.equal(true)
    end)

    t.it("falls back to the default threshold when nothing is configured", function()
        local h = harness({})
        h.mqlen = 999999
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(false)

        h.mqlen = 1000000
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(true)
    end)

    t.it("turns the overload flag off below 80% of the threshold", function()
        local h = harness({ log_overload_mqlen = 100 })
        h.mqlen = 150
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(true)

        -- 回落到 80% 以上时继续保持过载，避免抖动
        h.logs = {}
        h.mqlen = 85
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(true)
        t.expect(logged(h, "log overload off")).to.equal(false)

        h.mqlen = 79
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(false)
        t.expect(logged(h, "log overload off")).to.equal(true)
    end)

    t.it("keeps checking the queue when a bucket checker blows up", function()
        -- 心跳里每个 checker 都是 pcall 包的：一个坏掉的 bucket 不能连带把
        -- 过载检测一起废掉（真出问题时 mqlen 比较会抛错，而 pcall 会把错误吞掉）
        local h = harness({ log_overload_mqlen = 100 })
        h.global.bucket.buckets.broken = {
            check_error = function()
                error("bucket is broken")
            end,
            reload = function() end,
        }
        h.mqlen = 150
        h.timers.log_heartbeat()
        t.expect(h.global.log_overload).to.equal(true)
    end)

    t.it("reloads a bucket that reports an error", function()
        local h = harness({})
        local reloads = 0
        h.global.bucket.buckets.bad = {
            check_error = function()
                return true
            end,
            reload = function()
                reloads = reloads + 1
            end,
        }
        h.timers.log_heartbeat()
        t.expect(reloads).to.equal(1)
    end)
end)
