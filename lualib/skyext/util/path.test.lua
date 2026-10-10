local t = require "skytest"
local path = require "skyext.util.path"

t.describe("util.path", function()
    t.describe("join", function()
        t.it("joins two segments", function()
            t.expect(path.join("a", "b")).to.equal("a/b")
        end)

        t.it("joins multiple segments", function()
            t.expect(path.join("a", "b", "c")).to.equal("a/b/c")
        end)

        t.it("filters empty strings", function()
            t.expect(path.join("a", "", "b")).to.equal("a/b")
        end)

        t.it("normalizes multiple slashes", function()
            t.expect(path.join("a/", "/b")).to.equal("a/b")
        end)

        t.it("returns empty for no args", function()
            t.expect(path.join()).to.equal("")
        end)

        t.it("returns single segment as-is", function()
            t.expect(path.join("hello")).to.equal("hello")
        end)
    end)
end)
