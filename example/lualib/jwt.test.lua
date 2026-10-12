local t = require "skytest"
local jwt = require "jwt"

t.describe("jwt", function()
    local secret = "test_secret_key_12345"

    t.describe("sign and verify round-trip", function()
        t.it("HS256 round-trip", function()
            local payload = { sub = "user1", username = "alice" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            t.expect(token).to.be_type("string")
            t.expect(token).to.contain(".")

            local decoded, err = jwt.verify(token, secret)
            t.expect(err).to.be_nil()
            t.expect(decoded).to.exist()
            t.expect(decoded.sub).to.equal("user1")
            t.expect(decoded.username).to.equal("alice")
        end)

        t.it("HS512 round-trip", function()
            local payload = { sub = "user2", role = "admin" }
            local token = jwt.sign(payload, secret, "HS512", 3600)
            t.expect(token).to.be_type("string")

            local decoded, err = jwt.verify(token, secret)
            t.expect(err).to.be_nil()
            t.expect(decoded).to.exist()
            t.expect(decoded.sub).to.equal("user2")
            t.expect(decoded.role).to.equal("admin")
        end)
    end)

    t.describe("verify failures", function()
        t.it("rejects invalid format", function()
            local result, err = jwt.verify("not.a.valid.token.format", secret)
            t.expect(result).to.be_nil()
            t.expect(err).to.equal("invalid token format")
        end)

        t.it("rejects wrong secret", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            local result, err = jwt.verify(token, "wrong_secret")
            t.expect(result).to.be_nil()
            t.expect(err).to.contain("signature")
        end)

        t.it("rejects tampered payload", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            -- Tamper with the middle segment
            local parts = {}
            for part in token:gmatch("[^%.]+") do
                parts[#parts + 1] = part
            end
            parts[2] = parts[2] .. "x"
            local tampered = table.concat(parts, ".")
            local result, err = jwt.verify(tampered, secret)
            t.expect(result).to.be_nil()
            t.expect(err).to.exist()
        end)
    end)

    t.describe("token fields", function()
        t.it("sets iat automatically", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 3600)
            local decoded = jwt.verify(token, secret)
            t.expect(decoded.iat).to.be_type("number")
            t.expect(decoded.iat).to.be_gt(0)
        end)

        t.it("sets exp when exp_secs provided", function()
            local payload = { sub = "user1" }
            local token = jwt.sign(payload, secret, "HS256", 7200)
            local decoded = jwt.verify(token, secret)
            t.expect(decoded.exp).to.be_type("number")
            t.expect(decoded.exp).to.be_gt(decoded.iat)
        end)
    end)
end)
