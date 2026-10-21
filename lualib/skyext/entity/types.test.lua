local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local placement = require "skyext.entity.placement"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/types.lua")

local ROLE_TYPE = {
    nodes = { "role1", "role2", "role3" },
    agent_count = 4,
}

-- 每个用例加载一份全新的 types 模块：entity_types 缓存在模块局部变量里，
-- 复用同一个实例会让上一个用例的配置串到下一个用例。
local function harness(entity_types, realm_values)
    local h = { cfg = { entity_types = entity_types }, reads = 0 }
    local imports = {
        ["skyext.realm"] = {
            scope_values = function(scope)
                return (realm_values or {})[scope] or {}
            end,
        },
        ["skyext.config"] = {
            get_table = function(key)
                h.reads = h.reads + 1
                if key ~= "entity_types" then
                    return nil
                end
                return h.cfg.entity_types
            end,
        },
        -- 真实的 placement 会去连服务发现，这里只验证 types 把类型配置原样交了出去
        ["skyext.entity.placement"] = {
            calc_node = function(type_name, type_config, entity_id)
                h.placed = { type_name, type_config, entity_id }
                return "node-from-placement"
            end,
            hash = placement.hash,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.mod = assert(loadfile(source, "t", env))()
    return h
end

t.describe("entity types", function()
    t.it("does not read the config at load time", function()
        -- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的是 nil
        local h = harness({ role = ROLE_TYPE })
        t.expect(h.reads).to.equal(0)
        t.expect(h.mod.get("role")).to.equal(ROLE_TYPE)
        t.expect(h.reads).to.equal(1)
    end)

    t.it("errors instead of caching an empty table when entity_types is missing", function()
        local h = harness(nil)
        -- 以前的实现会把 config.get_table 返回的 nil 之外的空表缓存下来，
        -- 于是配置注入之后也永远是 unknown entity type。
        t.expect(function()
            h.mod.get("role")
        end).to
            .throw("entity_types is not configured")
        t.expect(function()
            h.mod.all()
        end).to
            .throw("entity_types is not configured")

        -- 配置注入之后必须能正常读到，证明失败的那次没有留下缓存
        h.cfg.entity_types = { role = ROLE_TYPE }
        t.expect(h.mod.get("role")).to.equal(ROLE_TYPE)
        t.expect(h.mod.all()).to.equal(h.cfg.entity_types)
    end)

    t.it("reads the config only once", function()
        local h = harness({ role = ROLE_TYPE })
        h.mod.get("role")
        local reads = h.reads
        h.mod.get("role")
        h.mod.all()
        h.mod.calc_node("role", 1)
        t.expect(h.reads).to.equal(reads)
    end)

    t.it("rejects an unknown entity type", function()
        local h = harness({ role = ROLE_TYPE })
        t.expect(function()
            h.mod.get("monster")
        end).to
            .throw("unknown entity type: monster")
        t.expect(function()
            h.mod.get(nil)
        end).to
            .throw("unknown entity type: nil")
    end)

    t.it("calc_node hands the resolved type config to placement", function()
        local h = harness({ role = ROLE_TYPE })
        t.expect(h.mod.calc_node("role", 42)).to.equal("node-from-placement")
        t.expect(h.placed).to.equal({ "role", ROLE_TYPE, 42 })
    end)

    t.it("calc_node still rejects an unknown entity type", function()
        local h = harness({ role = ROLE_TYPE })
        t.expect(function()
            h.mod.calc_node("ghost", 1)
        end).to
            .throw("unknown entity type: ghost")
        t.expect(h.placed).to.be_nil()
    end)

    t.it("calc_agent_index maps the hashed id into 1..agent_count", function()
        local h = harness({ role = ROLE_TYPE })
        for id = 0, 50 do
            local idx = h.mod.calc_agent_index("role", id)
            t.expect(idx).to.equal(placement.hash(id) % 4 + 1)
        end
    end)

    -- 回归：snowflake 低位是每秒归零的序号，低频发出的 ID 低位几乎全是 0。
    -- 直接 id % agent_count 时这些 ID 会全部落进第一个 agent
    t.it("spreads snowflake-like ids whose low bits are zero", function()
        local h = harness({ role = ROLE_TYPE })
        local hits = {}
        for second = 1, 400 do
            local idx = h.mod.calc_agent_index("role", (second << 31) | (3 << 17))
            hits[idx] = (hits[idx] or 0) + 1
        end
        for idx = 1, 4 do
            t.expect(hits[idx] ~= nil and hits[idx] > 60).to.equal(true)
        end
    end)

    t.it("calc_agent_index defaults to a single agent", function()
        local h = harness({ role = { nodes = { "role1" } } })
        t.expect(h.mod.calc_agent_index("role", 0)).to.equal(1)
        t.expect(h.mod.calc_agent_index("role", 12345)).to.equal(1)
    end)

    t.it("formats the agent service name", function()
        local h = harness({ role = ROLE_TYPE })
        t.expect(h.mod.format_agent_service_name("role", 2)).to.equal(".entity_agent:role:2")
    end)

    t.it("key_id maps a string key to the same positive id every time", function()
        local h = harness({ role = ROLE_TYPE })
        local id = h.mod.key_id("rank:game1")
        t.expect(math.type(id)).to.equal("integer")
        t.expect(id > 0).to.equal(true)
        t.expect(h.mod.key_id("rank:game1")).to.equal(id)
        t.expect(h.mod.key_id("rank:game2") ~= id).to.equal(true)
        t.expect(function()
            h.mod.key_id("")
        end).to
            .throw("non%-empty string")
    end)

    t.it("preload_ids keeps integers and hashes string keys", function()
        local h = harness({ rank = { preload = { 42, "game1" } } })
        t.expect(h.mod.preload_ids("rank")).to.equal({ 42, h.mod.key_id("game1") })
        local none = harness({ role = ROLE_TYPE })
        t.expect(none.mod.preload_ids("role")).to.equal({})
    end)

    t.it("scoped_id is stable per type and scope value", function()
        local h = harness({ rank = { scope = "game" }, guild = { scope = "game" }, role = ROLE_TYPE })
        local id = h.mod.scoped_id("rank", "game1")
        t.expect(id).to.equal(h.mod.key_id("rank:game:game1"))
        t.expect(h.mod.scoped_id("rank", "game2") ~= id).to.equal(true)
        -- 不同类型同一个 game 也是不同的实体
        t.expect(h.mod.scoped_id("guild", "game1") ~= id).to.equal(true)
        t.expect(function()
            h.mod.scoped_id("role", "game1")
        end).to
            .throw("has no scope")
    end)

    t.it("preloads one entity per value of the scope, following the realm directory", function()
        local h = harness({ rank = { scope = "game", preload = { 7 } } }, { game = { "game1", "game2" } })
        t.expect(h.mod.preload_ids("rank")).to.equal({
            h.mod.scoped_id("rank", "game1"),
            h.mod.scoped_id("rank", "game2"),
            7,
        })
    end)
end)
