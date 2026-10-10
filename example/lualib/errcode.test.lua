local t = require "skytest"
local errcode = require "errcode"

t.describe("example errcode", function()
    t.it("has game-specific codes", function()
        t.expect(errcode.ROLE_NOT_EXIST).to.equal(100)
        t.expect(errcode.ROLE_TOO_MANY).to.equal(101)
        t.expect(errcode.TOKEN_ERROR).to.equal(102)
        t.expect(errcode.PROTO_CHECKSUM).to.equal(103)
        t.expect(errcode.SERVER_NOT_EXIST).to.equal(104)
    end)

    t.it("inherits base codes from skyext.errcode", function()
        t.expect(errcode.OK).to.equal(0)
        t.expect(errcode.PARAM_ERROR).to.equal(10)
        t.expect(errcode.AUTH_FAILED).to.equal(11)
        t.expect(errcode.DB_ERROR).to.equal(6)
        t.expect(errcode.MONGO_DUPLICATE_KEY).to.equal(11000)
    end)

    t.it("throws on invalid code access", function()
        t.expect(function()
            local _ = errcode.TOTALLY_BOGUS_CODE
        end).to.throw("Invalid error code")
    end)
end)
