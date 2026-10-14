local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/orm_migration.lua")
local migration = assert(loadfile(source, "t", setmetatable({}, { __index = _G })))()

local function step(version, migrate, desc)
    return { version = version, desc = desc or ("step " .. version), migrate = migrate }
end

local function noop() end

t.describe("orm_migration.compile", function()
    t.it("accepts an empty definition table", function()
        local compiled = migration.compile({})
        t.expect(compiled).to.equal({})
        t.expect(migration.target(compiled, "role")).to.equal(0)
    end)

    t.it("keeps every step of a chain in order", function()
        local compiled = migration.compile({ role = { step(1, noop), step(2, noop), step(3, noop) } })
        t.expect(migration.target(compiled, "role")).to.equal(3)
        t.expect(compiled.role[2].desc).to.equal("step 2")
    end)

    t.it("rejects a step whose version does not match its position", function()
        t.expect(function()
            migration.compile({ role = { step(1, noop), step(3, noop) } })
        end).to
            .throw("migration role%[2%]: version must be 2, got 3")
    end)

    t.it("rejects a step with no version at all", function()
        t.expect(function()
            migration.compile({ role = { { desc = "x", migrate = noop } } })
        end).to
            .throw("version must be 1, got nil")
    end)

    t.it("rejects a chain with a hole in it", function()
        -- ipairs 在洞前就停下，第 3 步会被静默跳过
        t.expect(function()
            migration.compile({ role = { [1] = step(1, noop), [3] = step(3, noop) } })
        end).to
            .throw("migration role: has 2 steps but the chain stops at 1")
    end)

    t.it("requires a description and a function on every step", function()
        t.expect(function()
            migration.compile({ role = { { version = 1, migrate = noop } } })
        end).to
            .throw("desc must be a non%-empty string")
        t.expect(function()
            migration.compile({ role = { { version = 1, desc = "", migrate = noop } } })
        end).to
            .throw("desc must be a non%-empty string")
        t.expect(function()
            migration.compile({ role = { { version = 1, desc = "x" } } })
        end).to
            .throw("migrate must be a function")
        t.expect(function()
            migration.compile({ role = { "not a table" } })
        end).to
            .throw("step must be a table")
    end)

    t.it("rejects malformed containers", function()
        t.expect(function()
            migration.compile("nope")
        end).to
            .throw("migrations must be a table")
        t.expect(function()
            migration.compile({ role = "nope" })
        end).to
            .throw("migrations for role must be a table")
    end)
end)

t.describe("orm_migration.version_of", function()
    t.it("treats a document without the field as version 0", function()
        t.expect(migration.version_of({})).to.equal(0)
    end)

    t.it("reads an integer version", function()
        t.expect(migration.version_of({ _schema_version = 4 })).to.equal(4)
        -- mongo 可能把整数解码成 float
        t.expect(migration.version_of({ _schema_version = 4.0 })).to.equal(4)
    end)

    t.it("refuses a version that is not a non-negative integer", function()
        local version, err = migration.version_of({ _schema_version = -1 })
        t.expect(version).to.be_nil()
        t.expect(err).to.equal("invalid _schema_version: -1")
        t.expect(migration.version_of({ _schema_version = 1.5 })).to.be_nil()
        t.expect(migration.version_of({ _schema_version = "2" })).to.be_nil()
    end)
end)

t.describe("orm_migration.apply", function()
    t.it("runs only the steps the document is missing, in order", function()
        local ran = {}
        local compiled = migration.compile({
            role = {
                step(1, function(doc)
                    ran[#ran + 1] = 1
                    doc.a = true
                end),
                step(2, function(doc)
                    ran[#ran + 1] = 2
                    doc.b = true
                end),
                step(3, function(doc)
                    ran[#ran + 1] = 3
                    doc.c = true
                end),
            },
        })
        local doc = {}
        t.expect(migration.apply(compiled, "role", doc, 1)).to.equal(3)
        t.expect(ran).to.equal({ 2, 3 })
        t.expect(doc).to.equal({ b = true, c = true })
    end)

    t.it("mutates the document in place rather than returning a copy", function()
        local compiled = migration.compile({
            role = {
                step(1, function(doc)
                    doc.name = doc.nick
                    doc.nick = nil
                end),
            },
        })
        local doc = { nick = "legacy", rid = 7 }
        t.expect(migration.apply(compiled, "role", doc, 0)).to.equal(1)
        t.expect(doc).to.equal({ name = "legacy", rid = 7 })
    end)

    t.it("is a no-op for a collection with no chain", function()
        local compiled = migration.compile({})
        local doc = { rid = 7 }
        t.expect(migration.apply(compiled, "role", doc, 0)).to.equal(0)
        t.expect(doc).to.equal({ rid = 7 })
    end)

    t.it("does nothing when the document is already current", function()
        local compiled = migration.compile({
            role = {
                step(1, function(doc)
                    doc.touched = true
                end),
            },
        })
        local doc = {}
        t.expect(migration.apply(compiled, "role", doc, 1)).to.equal(1)
        t.expect(doc.touched).to.be_nil()
    end)

    t.it("refuses a document written by a newer build", function()
        local compiled = migration.compile({ role = { step(1, noop) } })
        local version, err = migration.apply(compiled, "role", {}, 5)
        t.expect(version).to.be_nil()
        t.expect(err).to.equal("role document schema version 5 is ahead of code version 1")
    end)

    t.it("reports which step failed and stops the chain there", function()
        local reached = false
        local compiled = migration.compile({
            role = {
                step(1, noop),
                step(2, function()
                    error("bad data")
                end, "拆分背包"),
                step(3, function()
                    reached = true
                end),
            },
        })
        local version, err = migration.apply(compiled, "role", {}, 0)
        t.expect(version).to.be_nil()
        t.expect(err).to.match("role migration 2 %(拆分背包%) failed")
        t.expect(err).to.match("bad data")
        t.expect(reached).to.equal(false)
    end)
end)
