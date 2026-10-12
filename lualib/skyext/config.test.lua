local t = require "skytest"
local config = require "skyext.config"

t.describe("config.serialize", function()
    t.it("serializes numbers", function()
        t.expect(config.serialize(42)).to.equal("42")
        t.expect(config.serialize(0)).to.equal("0")
        t.expect(config.serialize(-1)).to.equal("-1")
    end)

    t.it("serializes strings with proper escaping", function()
        local result = config.serialize("hello")
        t.expect(result).to.contain("hello")
        -- string.format %q wraps in quotes
        t.expect(result:sub(1, 1)).to.equal('"')
    end)

    t.it("escapes special characters in strings", function()
        local result = config.serialize('has "quotes" and \\backslash')
        -- should not produce broken Lua when loaded
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        t.expect(fn()).to.equal('has "quotes" and \\backslash')
    end)

    t.it("escapes newlines in strings", function()
        local result = config.serialize("line1\nline2")
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        t.expect(fn()).to.equal("line1\nline2")
    end)

    t.it("serializes booleans", function()
        t.expect(config.serialize(true)).to.equal("true")
        t.expect(config.serialize(false)).to.equal("false")
    end)

    t.it("serializes simple tables", function()
        local result = config.serialize({ a = 1, b = "two" })
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        local tbl = fn()
        t.expect(tbl.a).to.equal(1)
        t.expect(tbl.b).to.equal("two")
    end)

    t.it("serializes nested tables", function()
        local result = config.serialize({ x = { y = 3 } })
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        local tbl = fn()
        t.expect(tbl.x.y).to.equal(3)
    end)

    t.it("serializes array-like tables", function()
        local result = config.serialize({ 1, 2, 3 })
        local fn = load("return " .. result)
        t.expect(fn).to.exist()
        local tbl = fn()
        t.expect(#tbl).to.equal(3)
        t.expect(tbl[1]).to.equal(1)
        t.expect(tbl[3]).to.equal(3)
    end)

    t.it("round-trips complex tables", function()
        local original = {
            name = "console",
            level = 5,
            nested = { a = true, b = { 1, 2 } },
        }
        local serialized = config.serialize(original)
        local fn = load("return " .. serialized)
        t.expect(fn).to.exist()
        local restored = fn()
        t.expect(restored.name).to.equal("console")
        t.expect(restored.level).to.equal(5)
        t.expect(restored.nested.a).to.equal(true)
        t.expect(restored.nested.b[2]).to.equal(2)
    end)
end)

t.describe("config.get", function()
    t.it("returns nil for unset keys", function()
        t.expect(config.get("__test_nonexistent_key__")).to.be_nil()
    end)
end)
