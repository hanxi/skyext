local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/types.lua")

local ROLE_TYPE = {
    nodes = { "role1", "role2", "role3" },
    agent_count = 4,
}

-- 每个用例加载一份全新的 types 模块：entity_types 缓存在模块局部变量里，
-- 复用同一个实例会让上一个用例的配置串到下一个用例。
local function harness(entity_types)
    local h = { cfg = { entity_types = entity_types }, reads = 0 }
    local imports = {
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

    t.it("calc_agent_index wraps by agent_count", function()
        local h = harness({ role = ROLE_TYPE })
        t.expect(h.mod.calc_agent_index("role", 0)).to.equal(1)
        t.expect(h.mod.calc_agent_index("role", 1)).to.equal(2)
        t.expect(h.mod.calc_agent_index("role", 3)).to.equal(4)
        t.expect(h.mod.calc_agent_index("role", 4)).to.equal(1)
        t.expect(h.mod.calc_agent_index("role", 9)).to.equal(2)
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
end)
