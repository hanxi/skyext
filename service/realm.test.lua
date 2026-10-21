local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/realm.lua")

local PREFIX = "/skyext/realm/"

-- opts.store  etcd 里已有的键值：完整 key -> value
-- opts.seed   配置里的 realm_seed
local function harness(opts)
    opts = opts or {}
    local h = { store = opts.store or {}, revision = 10, published = {}, sets = {} }

    local client = {}
    function client:readdir(prefix)
        t.expect(prefix).to.equal(PREFIX)
        local kvs = {}
        for key, value in pairs(h.store) do
            kvs[#kvs + 1] = { key = key, value = value }
        end
        return { status = 200, body = { header = { revision = tostring(h.revision) }, kvs = kvs } }
    end
    function client:setnx(key, value)
        if h.store[key] == nil then
            h.store[key] = value
            h.revision = h.revision + 1
        end
        return { status = 200, body = {} }
    end
    function client:set(key, value)
        h.sets[#h.sets + 1] = key
        h.store[key] = value
        h.revision = h.revision + 1
        return { status = 200, body = {} }
    end

    local imports = {
        skynet = {
            start = function(f)
                h.boot = f
            end,
            -- watch 循环在测试里不跑，事件由用例直接喂给 apply
            fork = function() end,
        },
        ["skyext.etcd"] = {
            new = function()
                return client
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                h.CMD = cmd
            end,
        },
        ["skyext.gm_api"] = {
            register = function(cmds)
                h.GM = cmds
            end,
        },
        ["skyext.event_channel_api"] = {
            init = function() end,
            publish = function(cmd, dir)
                h.published[#h.published + 1] = { cmd = cmd, dir = dir }
            end,
        },
        ["skyext.config"] = {
            get_table = function(key)
                if key == "realm_seed" then
                    return opts.seed
                end
                return {}
            end,
        },
        ["skyext.time"] = {
            now = function()
                return 1700000000
            end,
        },
        ["skyext.log"] = setmetatable({}, {
            __index = function()
                return function() end
            end,
        }),
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()
    return h
end

local SEED = {
    zones = { zone1 = {} },
    games = { game1 = { zone = "zone1" } },
    servers = { s1 = { game = "game1", name = "一区", tag = "S1" } },
}

t.describe("realm directory", function()
    t.it("loads servers, games and zones from etcd", function()
        local h = harness({
            store = {
                [PREFIX .. "server/s1"] = { game = "game1" },
                [PREFIX .. "game/game1"] = { zone = "zone1" },
                [PREFIX .. "zone/zone1"] = {},
                [PREFIX .. "other/x"] = {},
            },
        })
        local dir = h.CMD.snapshot()
        t.expect(dir.servers.s1.game).to.equal("game1")
        t.expect(dir.games.game1.zone).to.equal("zone1")
        t.expect(dir.zones.zone1).to.equal({})
        t.expect(dir.revision).to.equal(10)
        t.expect(h.published[#h.published].cmd).to.equal("realm_change")
    end)

    t.it("writes the seed into an empty directory", function()
        local h = harness({ seed = SEED })
        local dir = h.CMD.snapshot()
        t.expect(dir.servers.s1.game).to.equal("game1")
        t.expect(dir.servers.s1.status).to.equal("open")
        t.expect(dir.servers.s1.open_time).to.equal(1700000000)
        t.expect(dir.games.game1.zone).to.equal("zone1")
    end)

    t.it("never touches a directory that already has servers", function()
        local h = harness({ store = { [PREFIX .. "server/s9"] = { game = "g9" } }, seed = SEED })
        t.expect(h.CMD.snapshot().servers.s1).to.be_nil()
    end)
end)

t.describe("realm GM", function()
    local function seeded()
        return harness({ seed = SEED })
    end

    t.it("opens a server on an existing game", function()
        local h = seeded()
        t.expect(h.GM.realm_open.handler({ server = "s2", game = "game1", name = "二区" })).to.equal(true)
        local info = h.store[PREFIX .. "server/s2"]
        t.expect(info.game).to.equal("game1")
        t.expect(info.tag).to.equal("S2")
        t.expect(info.status).to.equal("open")
    end)

    t.it("creates a new game when opening a server on it, given an existing zone", function()
        local h = seeded()
        t.expect(h.GM.realm_open.handler({ server = "s2", game = "game2", zone = "zone1" })).to.equal(true)
        t.expect(h.store[PREFIX .. "game/game2"]).to.equal({ zone = "zone1" })
        t.expect(table.pack(h.GM.realm_open.handler({ server = "s3", game = "game3", zone = "nope" }))).to.equal({
            false,
            "new game needs an existing zone",
            n = 2,
        })
    end)

    t.it("rejects a duplicate server and malformed names", function()
        local h = seeded()
        t.expect((h.GM.realm_open.handler({ server = "s1", game = "game1" }))).to.equal(false)
        t.expect((h.GM.realm_open.handler({ server = "s/2", game = "game1" }))).to.equal(false)
        t.expect(#h.sets).to.equal(0)
    end)

    t.it("moves a game to another zone, creating the zone", function()
        local h = seeded()
        t.expect(h.GM.realm_set_zone.handler({ game = "game1", zone = "zone2" })).to.equal(true)
        t.expect(h.store[PREFIX .. "zone/zone2"]).to.equal({})
        t.expect(h.store[PREFIX .. "game/game1"]).to.equal({ zone = "zone2" })
        t.expect((h.GM.realm_set_zone.handler({ game = "ghost", zone = "zone2" }))).to.equal(false)
    end)
end)
