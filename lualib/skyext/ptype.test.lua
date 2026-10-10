local t = require "skytest"
local ptype = require "skyext.ptype"

t.describe("ptype", function()
    t.it("defines log protocol type", function()
        t.expect(ptype.PTYPE_LOG).to.equal(128)
        t.expect(ptype.PTYPE_LOG_NAME).to.equal("log")
    end)

    t.it("defines log-err protocol type", function()
        t.expect(ptype.PTYPE_LOG_ERR).to.equal(129)
        t.expect(ptype.PTYPE_LOG_ERR_NAME).to.equal("log-err")
    end)

    t.it("protocol types are above skynet range", function()
        t.expect(ptype.PTYPE_LOG).to.be_gte(128)
        t.expect(ptype.PTYPE_LOG_ERR).to.be_gte(128)
    end)
end)
