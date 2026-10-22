local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/realm.lua")

local DIR = {
    revision = 5,
    servers = {
        s1 = { game = "game1", tag = "S1" },
        s2 = { game = "game2" },
        s3 = { game = "game2", tag = "S3" },
        s9 = { game = "lost" },
    },
    games = { game1 = { zone = "zone1" }, game2 = { zone = "zone2" } },
    zones = { zone1 = {}, zone2 = {} },
    gates = {
        gate2 = { tcp_addr = "10.0.0.2:7012" },
        gate1 = { tcp_addr = "10.0.0.1:7012", ws_url = "wss://gw.example.com", weight = 3 },
    },
}

local function harness()
    local h = { snapshots = 0 }
    local imports = {
        skynet = {
            uniqueservice = function(name)
                t.expect(name).to.equal("realm")
                return ":realm"
            end,
            call = function(addr, _, cmd)
                t.expect(addr).to.equal(":realm")
                t.expect(cmd).to.equal("snapshot")
                h.snapshots = h.snapshots + 1
                return DIR
            end,
        },
        ["skyext.event_channel_api"] = {
            subscribe = function(service, cmd, fn)
                t.expect(service).to.equal(":realm")
                t.expect(cmd).to.equal("realm_change")
                h.push = fn
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.realm = assert(loadfile(source, "t", env))()
    return h
end

t.describe("realm lookups", function()
    t.it("resolves game and zone from a birth server", function()
        local h = harness()
        t.expect(h.realm.game_of("s3")).to.equal("game2")
        t.expect(h.realm.zone_of("game2")).to.equal("zone2")
        t.expect(h.realm.game_of("nope")).to.be_nil()
        t.expect(h.realm.tag_of("s1")).to.equal("S1")
        t.expect(h.realm.tag_of("s2")).to.equal("s2")
        -- 只取一次快照，之后都查内存
        t.expect(h.snapshots).to.equal(1)
    end)

    t.it("maps a birth server onto every scope", function()
        local h = harness()
        t.expect(h.realm.scope_value("server", "s3")).to.equal("s3")
        t.expect(h.realm.scope_value("game", "s3")).to.equal("game2")
        t.expect(h.realm.scope_value("zone", "s3")).to.equal("zone2")
        t.expect(h.realm.scope_value("global", "s3")).to.equal("global")
        -- 目录里查不到就是 nil，调用方据此拒绝，而不是拿 nil 去拼作用域键
        t.expect(h.realm.scope_value("zone", "s9")).to.be_nil()
        t.expect(h.realm.scope_value("game", "nope")).to.be_nil()
        t.expect(function()
            h.realm.scope_value("planet", "s1")
        end).to
            .throw("unknown realm scope")
    end)

    t.it("lists every value of a scope, sorted", function()
        local h = harness()
        t.expect(h.realm.scope_values("game")).to.equal({ "game1", "game2" })
        t.expect(h.realm.scope_values("zone")).to.equal({ "zone1", "zone2" })
        t.expect(h.realm.scope_values("global")).to.equal({ "global" })
        t.expect(h.realm.scope_values("server")).to.equal({ "s1", "s2", "s3", "s9" })
    end)

    t.it("follows directory changes and notifies listeners", function()
        local h = harness()
        local seen = {}
        h.realm.subscribe(function(dir)
            seen[#seen + 1] = dir.revision
        end)
        h.push({
            revision = 6,
            servers = { s1 = { game = "game2" } },
            games = { game2 = { zone = "zone2" } },
            zones = { zone2 = {} },
        })
        t.expect(h.realm.game_of("s1")).to.equal("game2")
        t.expect(seen).to.equal({ 6 })
    end)

    t.it("lists online gates sorted by node, defaulting the weight", function()
        local h = harness()
        t.expect(h.realm.gates()).to.equal({
            { node = "gate1", tcp_addr = "10.0.0.1:7012", ws_url = "wss://gw.example.com", weight = 3 },
            { node = "gate2", tcp_addr = "10.0.0.2:7012", weight = 1 },
        })
    end)

    t.it("ignores a broadcast older than what it already has", function()
        local h = harness()
        h.realm.game_of("s1")
        h.push({ revision = 4, servers = {}, games = {}, zones = {} })
        t.expect(h.realm.game_of("s1")).to.equal("game1")
    end)
end)
