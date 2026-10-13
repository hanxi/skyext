local t = require "skytest"
local formatter = require "skyext.log.formatter"
local log_level = require "skyext.log.log_level"

local json = require "cjson.safe"

local function make_record(msg, events, level)
    return {
        module = "unittest",
        level = level or log_level.INFO,
        timestamp = 1700000000.25,
        line = "@formatter.test.lua:1",
        msg = msg,
        events = events,
    }
end

t.describe("formatter.json", function()
    t.it("encodes record fields and events", function()
        local fmt = formatter.get_formatter("json", false)
        local decoded = json.decode(fmt(make_record("hello", { { "key", "value" } })))
        t.expect(decoded).to.exist()
        t.expect(decoded.module).to.equal("unittest")
        t.expect(decoded.level).to.equal("INFO")
        t.expect(decoded.msg).to.equal("hello")
        t.expect(decoded.key).to.equal("value")
        t.expect(decoded.time).to.match("%d%d%d%d%-%d%d%-%d%d .*%.%d%d%d")
    end)

    t.it("does not leak events from the previous record", function()
        local fmt = formatter.get_formatter("json", false)
        local first = json.decode(fmt(make_record("first", { { "alpha", "1" } })))
        t.expect(first.alpha).to.equal("1")

        local second = json.decode(fmt(make_record("second", { { "beta", "2" } })))
        t.expect(second.beta).to.equal("2")
        t.expect(second.alpha).to.be_nil()
        t.expect(second.msg).to.equal("second")
    end)

    t.it("keeps records independent across formatter instances", function()
        local fmt1 = formatter.get_formatter("json", false)
        local fmt2 = formatter.get_formatter("json", false)
        fmt1(make_record("first", { { "only_in_first", "1" } }))
        local second = json.decode(fmt2(make_record("second", {})))
        t.expect(second.only_in_first).to.be_nil()
    end)
end)

t.describe("formatter.text", function()
    t.it("renders message and events", function()
        local fmt = formatter.get_formatter("text", false)
        local line = fmt(make_record("hello", { { "key", "value" }, { "n", "1" } }))
        t.expect(line).to.contain("msg:hello")
        t.expect(line).to.contain("key:value")
        t.expect(line).to.contain("n:1")
        t.expect(line).to.contain("unittest")
    end)

    t.it("wraps output in color codes when enabled", function()
        local fmt = formatter.get_formatter("text", true)
        local line = fmt(make_record("colored", {}, log_level.ERROR))
        t.expect(line).to.contain("\x1b[")
    end)

    t.it("rejects unknown levels", function()
        local fmt = formatter.get_formatter("text", false)
        t.expect(function()
            fmt(make_record("bad", {}, 99))
        end).to
            .throw("log level not exist")
    end)
end)
