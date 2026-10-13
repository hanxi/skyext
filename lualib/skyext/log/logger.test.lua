local t = require "skytest"
local logger = require "skyext.log.logger"
local log_level = require "skyext.log.log_level"

-- 静音的 traceback 替身：既避免测试输出噪音，也用于统计是否真的抓了堆栈
local function spy_logger(level)
    local lg = logger.new()
    local calls = 0
    lg:config({
        name = "logger_test",
        level = level or log_level.DEBUG,
        log_src = false,
        traceback = function()
            calls = calls + 1
            return "<traceback>"
        end,
    })
    return lg, function()
        return calls
    end
end

t.describe("logger:config", function()
    t.it("accepts numeric levels from app config", function()
        local lg = logger.new()
        lg:config({ level = 4 })
        t.expect(lg.level).to.equal(log_level.DEBUG)
        lg:config({ level = 0 })
        t.expect(lg.level).to.equal(log_level.FATAL)
    end)

    t.it("accepts level names case-insensitively", function()
        local lg = logger.new()
        lg:config({ level = "INFO" })
        t.expect(lg.level).to.equal(log_level.INFO)
        lg:config({ level = "warn" })
        t.expect(lg.level).to.equal(log_level.WARN)
    end)

    t.it("applies sibling fields together with a numeric level", function()
        local lg = logger.new()
        lg:config({ level = 3, log_src = false, log_table = false })
        t.expect(lg.level).to.equal(log_level.INFO)
        t.expect(lg.log_src).to.equal(false)
        t.expect(lg.log_table).to.equal(false)
    end)

    t.it("rejects out of range numeric levels", function()
        local lg = logger.new()
        t.expect(function()
            lg:config({ level = 99 })
        end).to
            .throw("invalid value: 99")
        t.expect(lg.level).to.equal(log_level.DEBUG)
    end)

    t.it("rejects unknown fields", function()
        local lg = logger.new()
        t.expect(function()
            lg:config({ not_a_field = 1 })
        end).to
            .throw("invalid config field")
    end)

    t.it("rejects type mismatches", function()
        local lg = logger.new()
        t.expect(function()
            lg:config({ log_src = "yes" })
        end).to
            .throw("type mismatch for field: log_src")
    end)

    t.it("rejects non table config", function()
        local lg = logger.new()
        t.expect(function()
            lg:config("level=4")
        end).to
            .throw("log config must be a table")
    end)
end)

t.describe("logger:is_enabled", function()
    t.it("reports whether a level passes the filter", function()
        local lg = logger.new()
        lg:config({ level = log_level.WARN })
        t.expect(lg:is_enabled(log_level.FATAL)).to.be_truthy()
        t.expect(lg:is_enabled(log_level.ERROR)).to.be_truthy()
        t.expect(lg:is_enabled(log_level.WARN)).to.be_truthy()
        t.expect(lg:is_enabled(log_level.INFO)).to.be_falsy()
        t.expect(lg:is_enabled(log_level.DEBUG)).to.be_falsy()
    end)
end)

t.describe("logger:error", function()
    t.it("skips the traceback when the level is filtered out", function()
        local lg, calls = spy_logger(log_level.FATAL)
        lg:error("filtered out", "k", "v")
        t.expect(calls()).to.equal(0)
    end)

    t.it("captures the traceback when the level is enabled", function()
        local lg, calls = spy_logger(log_level.ERROR)
        lg:error("visible", "k", "v")
        t.expect(calls()).to.equal(1)
    end)
end)

t.describe("logger error helpers", function()
    t.it("xpcall_msgh logs and returns the original message", function()
        local lg, calls = spy_logger()
        t.expect(lg:xpcall_msgh("boom")).to.equal("boom")
        t.expect(calls()).to.equal(1)
    end)

    t.it("sys_assert passes values through", function()
        local lg = spy_logger()
        local a, b = lg:sys_assert(1, "ok")
        t.expect(a).to.equal(1)
        t.expect(b).to.equal("ok")
    end)

    t.it("sys_assert raises the given message", function()
        local lg = spy_logger()
        t.expect(function()
            lg:sys_assert(false, "assert message")
        end).to
            .throw("assert message")
    end)

    t.it("sys_error raises the given message", function()
        local lg = spy_logger()
        t.expect(function()
            lg:sys_error("error message")
        end).to
            .throw("error message")
    end)

    t.it("does not install global pcall wrappers any more", function()
        t.expect(logger.safe_pcall).to.be_nil()
        t.expect(logger.safe_xpcall).to.be_nil()
    end)
end)
