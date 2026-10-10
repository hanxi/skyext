local t = require "skytest"
local tbl = require "skyext.util.table"

t.describe("util.table", function()
    t.describe("deepcopy", function()
        t.it("copies nested tables", function()
            local orig = { a = 1, b = { c = 2 } }
            local copy = tbl.deepcopy(orig)
            t.expect(copy.a).to.equal(1)
            t.expect(copy.b.c).to.equal(2)
        end)

        t.it("original unchanged after modifying copy", function()
            local orig = { a = { x = 10 } }
            local copy = tbl.deepcopy(orig)
            copy.a.x = 99
            t.expect(orig.a.x).to.equal(10)
        end)

        t.it("handles non-table values", function()
            t.expect(tbl.deepcopy(42)).to.equal(42)
            t.expect(tbl.deepcopy("hello")).to.equal("hello")
            t.expect(tbl.deepcopy(true)).to.equal(true)
            t.expect(tbl.deepcopy(nil)).to.be_nil()
        end)

        t.it("copies tables with mixed key types", function()
            local orig = { [1] = "a", ["x"] = 2, [true] = "yes" }
            local copy = tbl.deepcopy(orig)
            t.expect(copy[1]).to.equal("a")
            t.expect(copy["x"]).to.equal(2)
            t.expect(copy[true]).to.equal("yes")
        end)
    end)

    t.describe("keys", function()
        t.it("returns all keys", function()
            local k = tbl.keys({ x = 1, y = 2, z = 3 })
            table.sort(k)
            t.expect(#k).to.equal(3)
            t.expect(k[1]).to.equal("x")
            t.expect(k[2]).to.equal("y")
            t.expect(k[3]).to.equal("z")
        end)

        t.it("returns empty for empty table", function()
            t.expect(#tbl.keys({})).to.equal(0)
        end)
    end)

    t.describe("size", function()
        t.it("counts hash table entries", function()
            t.expect(tbl.size({ a = 1, b = 2 })).to.equal(2)
        end)

        t.it("counts array entries", function()
            t.expect(tbl.size({ 10, 20, 30 })).to.equal(3)
        end)

        t.it("empty table returns 0", function()
            t.expect(tbl.size({})).to.equal(0)
        end)

        t.it("non-table returns 0", function()
            t.expect(tbl.size("hello")).to.equal(0)
            t.expect(tbl.size(42)).to.equal(0)
            t.expect(tbl.size(nil)).to.equal(0)
        end)
    end)

    t.describe("values", function()
        t.it("returns all values", function()
            local v = tbl.values({ a = 10, b = 20 })
            table.sort(v)
            t.expect(#v).to.equal(2)
            t.expect(v[1]).to.equal(10)
            t.expect(v[2]).to.equal(20)
        end)
    end)

    t.describe("clear", function()
        t.it("empties a table", function()
            local data = { a = 1, b = 2 }
            tbl.clear(data)
            t.expect(tbl.size(data)).to.equal(0)
            t.expect(data.a).to.be_nil()
        end)
    end)

    t.describe("merge", function()
        t.it("merges t2 into t1", function()
            local t1 = { a = 1 }
            local t2 = { b = 2 }
            tbl.merge(t1, t2)
            t.expect(t1.a).to.equal(1)
            t.expect(t1.b).to.equal(2)
        end)

        t.it("overwrites existing keys", function()
            local t1 = { a = 1 }
            local t2 = { a = 99 }
            tbl.merge(t1, t2)
            t.expect(t1.a).to.equal(99)
        end)
    end)

    t.describe("tostring", function()
        t.it("serializes simple table", function()
            local s = tbl.tostring({ a = 1 })
            t.expect(s).to.be_type("string")
            t.expect(s).to.contain("a")
            t.expect(s).to.contain("1")
        end)

        t.it("serializes nested table", function()
            local s = tbl.tostring({ x = { y = 2 } })
            t.expect(s).to.contain("y")
            t.expect(s).to.contain("2")
        end)

        t.it("handles circular references", function()
            local data = { a = 1 }
            data.self = data
            local s = tbl.tostring(data)
            t.expect(s).to.contain("<ref:")
        end)

        t.it("handles strings and numbers", function()
            t.expect(tbl.tostring("hello")).to.contain("hello")
            t.expect(tbl.tostring(42)).to.equal("42")
        end)
    end)

    t.describe("in_array", function()
        t.it("finds value and returns index", function()
            local idx = tbl.in_array({ "a", "b", "c" }, "b")
            t.expect(idx).to.equal(2)
        end)

        t.it("returns nil for missing value", function()
            local idx = tbl.in_array({ "a", "b" }, "z")
            t.expect(idx).to.be_nil()
        end)
    end)
end)
