local t = require "skytest"
local str = require "skyext.util.string"

t.describe("util.string", function()
    t.describe("fromhex", function()
        t.it("converts hex to binary", function()
            t.expect(str.fromhex("48656C6C6F")).to.equal("Hello")
        end)

        t.it("handles lowercase hex", function()
            t.expect(str.fromhex("48656c6c6f")).to.equal("Hello")
        end)

        t.it("converts empty string", function()
            t.expect(str.fromhex("")).to.equal("")
        end)

        t.it("handles null bytes", function()
            t.expect(str.fromhex("006100")).to.equal("\0a\0")
        end)
    end)

    t.describe("tohex", function()
        t.it("converts binary to hex", function()
            t.expect(str.tohex("Hello")).to.equal("48656C6C6F")
        end)

        t.it("converts empty string", function()
            t.expect(str.tohex("")).to.equal("")
        end)

        t.it("handles null bytes", function()
            t.expect(str.tohex("\0\255")).to.equal("00FF")
        end)
    end)

    t.describe("round-trip", function()
        t.it("fromhex(tohex(s)) == s", function()
            local original = "Hello, World!\n\t\0"
            t.expect(str.fromhex(str.tohex(original))).to.equal(original)
        end)
    end)

    t.describe("split", function()
        t.it("splits by comma", function()
            local parts = str.split("a,b,c", ",")
            t.expect(#parts).to.equal(3)
            t.expect(parts[1]).to.equal("a")
            t.expect(parts[2]).to.equal("b")
            t.expect(parts[3]).to.equal("c")
        end)

        t.it("splits by space", function()
            local parts = str.split("hello world", " ")
            t.expect(#parts).to.equal(2)
            t.expect(parts[1]).to.equal("hello")
            t.expect(parts[2]).to.equal("world")
        end)

        t.it("single element has no delimiter", function()
            local parts = str.split("hello", ",")
            t.expect(#parts).to.equal(1)
            t.expect(parts[1]).to.equal("hello")
        end)

        t.it("skips empty segments", function()
            local parts = str.split("a,,b", ",")
            t.expect(#parts).to.equal(2)
            t.expect(parts[1]).to.equal("a")
            t.expect(parts[2]).to.equal("b")
        end)
    end)
end)
