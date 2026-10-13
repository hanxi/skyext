-- 校验 skyext 初始化之后标准库保持原生语义（不再有全局覆盖）
local t = require "skytest"

require "skyext"

t.describe("skyext global environment", function()
    t.it("does not leave override sentinels in _G", function()
        t.expect(_G.raw_error).to.be_nil()
        t.expect(_G.raw_assert).to.be_nil()
        t.expect(_G.rawnext).to.be_nil()
    end)

    t.it("keeps next native (ignores __next metamethods)", function()
        local tbl = setmetatable({ 1 }, {
            __next = function()
                error("__next must not be used by the global next")
            end,
        })
        local k, v = next(tbl)
        t.expect(k).to.equal(1)
        t.expect(v).to.equal(1)
    end)

    t.it("keeps table helpers native (ignore orm metamethods)", function()
        local mt = {
            __unpack = function()
                error("__unpack must not be used")
            end,
            __concat = function()
                error("__concat must not be used")
            end,
            __insert = function()
                error("__insert must not be used")
            end,
            __remove = function()
                error("__remove must not be used")
            end,
        }
        local tbl = setmetatable({ "a", "b" }, mt)
        t.expect(table.concat(tbl, ",")).to.equal("a,b")
        local first, second = table.unpack(tbl)
        t.expect(first).to.equal("a")
        t.expect(second).to.equal("b")
        table.insert(tbl, "c")
        t.expect(tbl[3]).to.equal("c")
        t.expect(table.remove(tbl)).to.equal("c")
    end)

    t.it("table.insert still validates its argument count", function()
        t.expect(function()
            table.insert({}, 1, 2, 3)
        end).to
            .throw("wrong number of arguments")
    end)

    t.it("error keeps the native level argument semantics", function()
        local _, err = pcall(function()
            error("plain message", 0)
        end)
        t.expect(err).to.equal("plain message")
    end)

    t.it("error preserves non string values", function()
        local payload = { code = 42 }
        local _, err = pcall(function()
            error(payload)
        end)
        t.expect(err).to.equal(payload)
    end)

    t.it("assert returns all of its arguments", function()
        local a, b, c = assert(1, "two", 3)
        t.expect(a).to.equal(1)
        t.expect(b).to.equal("two")
        t.expect(c).to.equal(3)
    end)
end)
