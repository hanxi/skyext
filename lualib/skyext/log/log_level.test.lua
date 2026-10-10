local t = require "skytest"
local log_level = require "skyext.log.log_level"

t.describe("log_level", function()
    t.it("defines all level constants", function()
        t.expect(log_level.DEBUG).to.equal(4)
        t.expect(log_level.INFO).to.equal(3)
        t.expect(log_level.WARN).to.equal(2)
        t.expect(log_level.ERROR).to.equal(1)
        t.expect(log_level.FATAL).to.equal(0)
    end)

    t.it("priority: FATAL < ERROR < WARN < INFO < DEBUG", function()
        t.expect(log_level.FATAL).to.be_lt(log_level.ERROR)
        t.expect(log_level.ERROR).to.be_lt(log_level.WARN)
        t.expect(log_level.WARN).to.be_lt(log_level.INFO)
        t.expect(log_level.INFO).to.be_lt(log_level.DEBUG)
    end)
end)
