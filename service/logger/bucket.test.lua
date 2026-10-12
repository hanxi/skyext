local skynet = require "skynet"
local t = require "skytest"
local bucket = assert(loadfile("service/logger/bucket.lua"))()

t.describe("logger bucket", function()
    t.it("uses the default bucket when log_config is absent", function()
        t.expect(skynet.getenv("log_config")).to.be_nil()
        local obj = bucket.new()
        local received
        obj.default = {
            put = function(_, record)
                received = record
                return true
            end,
        }

        local record = {}
        t.expect(obj.buckets).to.have_length(0)
        t.expect(obj:put(record)).to.equal(true)
        t.expect(received).to.equal(record)
        obj:reload()
        obj:close()
    end)

    t.it("retains configured buckets", function()
        local obj = bucket.new({ { name = "console" } })
        t.expect(obj.buckets).to.have_length(1)
        obj:close()
    end)
end)
