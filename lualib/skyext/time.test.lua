local t = require "skytest"
local time = require "skyext.time"

t.describe("time", function()
    t.it("now returns integer seconds", function()
        local n = time.now()
        t.expect(n).to.be_type("number")
        t.expect(n).to.be_gt(0)
        t.expect(n % 1).to.equal(0)
    end)

    t.it("time returns float seconds", function()
        local ts = time.time()
        t.expect(ts).to.be_type("number")
        t.expect(ts).to.be_gt(0)
    end)

    t.it("now_ms returns milliseconds", function()
        local ms = time.now_ms()
        t.expect(ms).to.be_type("number")
        t.expect(ms).to.be_gt(time.now())
    end)

    t.it("format produces date string", function()
        local s = time.format(1700000000)
        t.expect(s).to.be_type("string")
        t.expect(s).to.match("%d%d%d%d%-%d%d%-%d%d")
    end)
end)
