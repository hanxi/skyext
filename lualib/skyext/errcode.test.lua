local t = require "skytest"
local errcode = require "skyext.errcode"

t.describe("errcode", function()
    t.it("has standard error codes", function()
        t.expect(errcode.OK).to.equal(0)
        t.expect(errcode.PARAM_ERROR).to.equal(10)
        t.expect(errcode.AUTH_FAILED).to.equal(11)
        t.expect(errcode.DB_ERROR).to.equal(6)
    end)

    t.it("has entity error codes", function()
        t.expect(errcode.ENTITY_NOT_FOUND).to.equal(20)
        t.expect(errcode.ENTITY_LOCK_FAILED).to.equal(21)
        t.expect(errcode.ENTITY_LOAD_FAILED).to.equal(22)
    end)

    t.it("has MongoDB error codes", function()
        t.expect(errcode.MONGO_DUPLICATE_KEY).to.equal(11000)
    end)

    t.it("throws on invalid error code access", function()
        t.expect(function()
            local _ = errcode.NONEXISTENT_CODE
        end).to.throw("Invalid error code")
    end)
end)
