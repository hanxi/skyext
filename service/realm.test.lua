local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/realm.lua")

local PREFIX = "/skyext/realm/"

-- opts.store  etcd 里已有的键值：完整 key -> value
-- opts.seed   配置里的 realm_seed
local function harness(opts)
    opts = opts or {}
    local h = {
        store = opts.store or {},
        revision = 10,
        published = {},
        sets = {},
        deletes = {},
        leases = {},
        hooks = {},
        lease_valid = opts.lease_valid ~= false,
    }

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
    function client:set(key, value, set_opts)
        h.sets[#h.sets + 1] = key
        h.store[key] = value
        h.leases[key] = set_opts and set_opts.lease
        h.revision = h.revision + 1
        return { status = 200, body = {} }
    end
    function client:delete(key)
        h.deletes[#h.deletes + 1] = key
        h.store[key] = nil
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
        ["skyext.node_lease"] = {
            valid = function()
                return h.lease_valid
            end,
            id = function()
                return "lease-1"
            end,
            on_lost = function(_, fn)
                h.on_lease_lost = fn
            end,
        },
        ["skyext.node_shutdown_api"] = {
            add_hook = function(phase, cmd)
                h.hooks[#h.hooks + 1] = { phase = phase, cmd = cmd }
            end,
        },
        -- 定时器只记下回调，用例自己决定什么时候跑一拍
        ["skyext.timer"] = {
            repeat_immediately = function(_, _, fn)
                h.gate_tick = fn
                fn()
                return {
                    wakeup = function()
                        fn()
                    end,
                    cancel = function()
                        h.gate_tick = nil
                    end,
                }
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                if key == "cluster_node_name" then
                    return "gate1"
                end
                return nil
            end,
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

t.describe("realm 网关注册", function()
    local GATE_KEY = PREFIX .. "gate/gate1"

    t.it("把本节点的接入地址挂在节点租约上", function()
        local h = harness()
        h.CMD.register_gate({ tcp_addr = "10.0.0.1:7012", weight = 3 })
        t.expect(h.store[GATE_KEY]).to.equal({ tcp_addr = "10.0.0.1:7012", weight = 3 })
        -- 租约是关键：进程没了键跟着没，客户端不会被引导到一台死掉的网关
        t.expect(h.leases[GATE_KEY]).to.equal("lease-1")
    end)

    t.it("两个网关合成一条节点记录", function()
        local h = harness()
        h.CMD.register_gate({ tcp_addr = "10.0.0.1:7012" })
        h.CMD.register_gate({ ws_url = "wss://gw.example.com" })
        t.expect(h.store[GATE_KEY]).to.equal({
            tcp_addr = "10.0.0.1:7012",
            ws_url = "wss://gw.example.com",
        })
    end)

    t.it("没有租约时不写，等到租约可用的那一拍再写", function()
        local h = harness({ lease_valid = false })
        h.CMD.register_gate({ tcp_addr = "10.0.0.1:7012" })
        t.expect(h.store[GATE_KEY]).to.be_nil()
        h.lease_valid = true
        h.gate_tick()
        t.expect(h.store[GATE_KEY]).to.equal({ tcp_addr = "10.0.0.1:7012" })
    end)

    t.it("租约失效后重新注册：挂在旧租约上的键已经被 etcd 删了", function()
        local h = harness()
        h.CMD.register_gate({ tcp_addr = "10.0.0.1:7012" })
        t.expect(#h.sets).to.equal(1)
        -- 已经同步过就不重复写
        h.gate_tick()
        t.expect(#h.sets).to.equal(1)
        h.on_lease_lost(1, "expired")
        h.gate_tick()
        t.expect(#h.sets).to.equal(2)
    end)

    t.it("停止接入时摘掉自己，已连上的客户端不受影响", function()
        local h = harness()
        h.CMD.register_gate({ tcp_addr = "10.0.0.1:7012" })
        t.expect(h.hooks).to.equal({ { phase = "stop_accepting", cmd = "unregister_gate" } })
        t.expect(h.CMD.unregister_gate()).to.equal(true)
        t.expect(h.deletes).to.equal({ GATE_KEY })
        t.expect(h.store[GATE_KEY]).to.be_nil()
    end)

    t.it("非网关节点不注册、不起定时器", function()
        local h = harness()
        t.expect(h.gate_tick).to.be_nil()
        t.expect(#h.sets).to.equal(0)
        t.expect(h.CMD.unregister_gate()).to.equal(true)
        t.expect(#h.deletes).to.equal(0)
    end)

    t.it("网关记录不参与 realm_seed", function()
        local h = harness({ seed = { gates = { gate9 = { tcp_addr = "x" } }, zones = { zone1 = {} } } })
        t.expect(h.store[PREFIX .. "gate/gate9"]).to.be_nil()
        t.expect(h.CMD.snapshot().zones.zone1).to.equal({})
    end)

    t.it("从 etcd 读回来的网关记录进快照", function()
        local h = harness({ store = { [GATE_KEY] = { tcp_addr = "10.0.0.1:7012" } } })
        t.expect(h.CMD.snapshot().gates.gate1.tcp_addr).to.equal("10.0.0.1:7012")
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
