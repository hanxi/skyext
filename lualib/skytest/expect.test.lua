local t = require "skytest"

t.describe("expect.equal", function()
    t.it("passes for equal numbers", function()
        t.expect(1).to.equal(1)
        t.expect(0).to.equal(0)
        t.expect(-1).to.equal(-1)
    end)

    t.it("passes for equal strings", function()
        t.expect("hello").to.equal("hello")
        t.expect("").to.equal("")
    end)

    t.it("passes for equal booleans", function()
        t.expect(true).to.equal(true)
        t.expect(false).to.equal(false)
    end)

    t.it("passes for deep equal tables", function()
        t.expect({ 1, 2, 3 }).to.equal({ 1, 2, 3 })
        t.expect({ a = 1, b = { c = 2 } }).to.equal({ a = 1, b = { c = 2 } })
        t.expect({}).to.equal({})
    end)

    t.it("fails for unequal values", function()
        t.expect(function()
            t.expect(1).to.equal(2)
        end).to
            .throw("equal")
    end)

    t.it("to_not.equal passes for unequal values", function()
        t.expect(1).to_not.equal(2)
        t.expect("a").to_not.equal("b")
        t.expect({ 1 }).to_not.equal({ 2 })
    end)
end)

t.describe("expect.exist", function()
    t.it("passes for non-nil values", function()
        t.expect(1).to.exist()
        t.expect("").to.exist()
        t.expect(false).to.exist()
        t.expect(0).to.exist()
        t.expect({}).to.exist()
    end)

    t.it("fails for nil", function()
        t.expect(function()
            t.expect(nil).to.exist()
        end).to
            .throw()
    end)
end)

t.describe("expect.be_nil", function()
    t.it("passes for nil", function()
        t.expect(nil).to.be_nil()
    end)

    t.it("fails for non-nil", function()
        t.expect(function()
            t.expect(1).to.be_nil()
        end).to
            .throw()
    end)
end)

t.describe("expect.be_truthy / be_falsy", function()
    t.it("truthy passes for non-nil non-false", function()
        t.expect(1).to.be_truthy()
        t.expect("hello").to.be_truthy()
        t.expect({}).to.be_truthy()
        t.expect(0).to.be_truthy()
    end)

    t.it("truthy fails for nil and false", function()
        t.expect(function()
            t.expect(nil).to.be_truthy()
        end).to
            .throw()
        t.expect(function()
            t.expect(false).to.be_truthy()
        end).to
            .throw()
    end)

    t.it("falsy passes for nil and false", function()
        t.expect(nil).to.be_falsy()
        t.expect(false).to.be_falsy()
    end)

    t.it("falsy fails for truthy values", function()
        t.expect(function()
            t.expect(1).to.be_falsy()
        end).to
            .throw()
    end)
end)

t.describe("expect.be_type", function()
    t.it("checks types correctly", function()
        t.expect(1).to.be_type("number")
        t.expect("s").to.be_type("string")
        t.expect({}).to.be_type("table")
        t.expect(true).to.be_type("boolean")
        t.expect(nil).to.be_type("nil")
        t.expect(print).to.be_type("function")
    end)

    t.it("fails for wrong type", function()
        t.expect(function()
            t.expect(1).to.be_type("string")
        end).to
            .throw()
    end)
end)

t.describe("expect.comparisons", function()
    t.it("be_gt", function()
        t.expect(2).to.be_gt(1)
        t.expect(function()
            t.expect(1).to.be_gt(1)
        end).to
            .throw()
    end)

    t.it("be_gte", function()
        t.expect(2).to.be_gte(1)
        t.expect(1).to.be_gte(1)
        t.expect(function()
            t.expect(0).to.be_gte(1)
        end).to
            .throw()
    end)

    t.it("be_lt", function()
        t.expect(1).to.be_lt(2)
        t.expect(function()
            t.expect(1).to.be_lt(1)
        end).to
            .throw()
    end)

    t.it("be_lte", function()
        t.expect(1).to.be_lte(2)
        t.expect(1).to.be_lte(1)
        t.expect(function()
            t.expect(2).to.be_lte(1)
        end).to
            .throw()
    end)
end)

t.describe("expect.string", function()
    t.it("contain", function()
        t.expect("hello world").to.contain("world")
        t.expect("hello world").to.contain("hello")
        t.expect("hello").to_not.contain("xyz")
    end)

    t.it("match", function()
        t.expect("hello123").to.match("%d+")
        t.expect("hello").to_not.match("%d+")
    end)
end)

t.describe("expect.table", function()
    t.it("have_key", function()
        t.expect({ a = 1, b = 2 }).to.have_key("a")
        t.expect({ a = 1 }).to_not.have_key("b")
    end)

    t.it("have_length", function()
        t.expect({ 1, 2, 3 }).to.have_length(3)
        t.expect({}).to.have_length(0)
        t.expect("hello").to.have_length(5)
    end)
end)

t.describe("expect.throw", function()
    t.it("passes when function throws", function()
        t.expect(function()
            error("boom")
        end).to
            .throw()
    end)

    t.it("matches error pattern", function()
        t.expect(function()
            error("something bad happened")
        end).to
            .throw("bad")
    end)

    t.it("fails when function does not throw", function()
        t.expect(function()
            t.expect(function() end).to.throw()
        end).to
            .throw("did not")
    end)

    t.it("to_not.throw passes for non-throwing function", function()
        t.expect(function() end).to_not.throw()
    end)
end)
