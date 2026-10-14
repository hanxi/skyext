local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/placement.lua")

-- 兜底告警状态缓存在模块局部变量里，每个用例都要一份全新的模块实例
local function harness()
    local h = { logs = {}, queries = 0 }

    local function record(level)
        return function(msg, ...)
            h.logs[#h.logs + 1] = { level = level, msg = msg, ... }
        end
    end

    local fake_discovery = {}
    function fake_discovery.nodes(service)
        h.queries = h.queries + 1
        h.queried_service = service
        if h.discovery_error then
            error(h.discovery_error, 0)
        end
        return h.live
    end

    local imports = {
        ["skyext.cluster_discovery"] = fake_discovery,
        ["skyext.log"] = { info = record("info"), warn = record("warn"), error = record("error") },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.mod = assert(loadfile(source, "t", env))()
    return h
end

local function last_log(h)
    return h.logs[#h.logs]
end

t.describe("entity placement", function()
    t.describe("rendezvous selection", function()
        t.it("picks a node from the candidate list and is stable for the same id", function()
            local h = harness()
            local nodes = { "a", "b", "c" }
            local allowed = { a = true, b = true, c = true }
            local seen = {}
            for id = 1, 300 do
                local node = h.mod.select(nodes, id)
                t.expect(allowed[node]).to.equal(true)
                t.expect(h.mod.select(nodes, id)).to.equal(node)
                seen[node] = (seen[node] or 0) + 1
            end
            -- 三个节点都要分到活，否则混合函数没起作用
            t.expect(seen.a).to.be_gt(0)
            t.expect(seen.b).to.be_gt(0)
            t.expect(seen.c).to.be_gt(0)
        end)

        t.it("does not depend on the order of the candidate list", function()
            -- 存活集合是从哈希表遍历出来的，顺序不定；各节点必须算出同一个结果
            local h = harness()
            for id = 1, 200 do
                t.expect(h.mod.select({ "a", "b", "c" }, id)).to.equal(h.mod.select({ "c", "a", "b" }, id))
            end
        end)

        t.it("only re-homes the leaving node's entities", function()
            -- HRW 取代 jchash 的全部理由：从中间摘掉一个节点不能把别人的实体也重排
            local h = harness()
            local before = {}
            for id = 1, 500 do
                before[id] = h.mod.select({ "a", "b", "c", "d" }, id)
            end
            local moved, kept = 0, 0
            for id = 1, 500 do
                local after = h.mod.select({ "a", "c", "d" }, id)
                if before[id] == "b" then
                    moved = moved + 1
                    t.expect(after).to_not.equal("b")
                else
                    kept = kept + 1
                    t.expect(after).to.equal(before[id])
                end
            end
            t.expect(moved).to.be_gt(0)
            t.expect(kept).to.be_gt(0)
        end)

        t.it("gives a returning node exactly its own entities back", function()
            local h = harness()
            for id = 1, 300 do
                local full = h.mod.select({ "a", "b", "c" }, id)
                local degraded = h.mod.select({ "a", "c" }, id)
                if full ~= "b" then
                    t.expect(degraded).to.equal(full)
                end
            end
        end)

        t.it("returns nil for an empty candidate list", function()
            local h = harness()
            t.expect(h.mod.select({}, 1)).to.be_nil()
        end)

        t.it("scores a single node deterministically", function()
            local h = harness()
            t.expect(h.mod.score("rolenode1", 42)).to.equal(h.mod.score("rolenode1", 42))
            t.expect(h.mod.score("rolenode1", 42)).to_not.equal(h.mod.score("rolenode2", 42))
            t.expect(h.mod.score("rolenode1", 42)).to_not.equal(h.mod.score("rolenode1", 43))
            t.expect(h.mod.score("rolenode1", 42)).to.be_gte(0)
        end)
    end)

    t.describe("service name", function()
        t.it("matches what entity_agentmgr registers", function()
            local h = harness()
            t.expect(h.mod.service_name("role")).to.equal("entity:role")
        end)
    end)

    t.describe("calc_node", function()
        t.it("routes onto the discovered live nodes, ignoring the configured list", function()
            local h = harness()
            h.live = { "rolenode3" }
            -- 配置里根本没有 rolenode3：扩容不需要改配置，发现到的才是权威
            t.expect(h.mod.calc_node("role", { nodes = { "rolenode1", "rolenode2" } }, 7)).to.equal("rolenode3")
            t.expect(h.queried_service).to.equal("entity:role")
            t.expect(h.queries).to.equal(1)
        end)

        t.it("falls back to the configured nodes when nothing is discovered", function()
            local h = harness()
            h.live = {}
            local node = h.mod.calc_node("role", { nodes = { "rolenode1", "rolenode2" } }, 7)
            t.expect(node).to.equal(h.mod.select({ "rolenode1", "rolenode2" }, 7))
            t.expect(last_log(h).level).to.equal("warn")
            t.expect(last_log(h).msg).to.match("fell back to configured nodes")
        end)

        t.it("warns once per type while degraded and announces recovery", function()
            local h = harness()
            h.live = {}
            local cfg = { nodes = { "rolenode1", "rolenode2" } }
            h.mod.calc_node("role", cfg, 7)
            h.mod.calc_node("role", cfg, 8)
            h.mod.calc_node("role", cfg, 9)
            t.expect(#h.logs).to.equal(1)

            h.live = { "rolenode1" }
            h.mod.calc_node("role", cfg, 7)
            t.expect(#h.logs).to.equal(2)
            t.expect(last_log(h).level).to.equal("info")
            t.expect(last_log(h).msg).to.match("back on discovered nodes")

            -- 恢复之后再掉下去，要再告警一次
            h.live = nil
            h.mod.calc_node("role", cfg, 7)
            t.expect(#h.logs).to.equal(3)
            t.expect(last_log(h).level).to.equal("warn")
        end)

        t.it("keeps routing when the discovery client blows up", function()
            local h = harness()
            h.discovery_error = "cluster_discovery service not initialized"
            local node = h.mod.calc_node("role", { nodes = { "rolenode1", "rolenode2" } }, 7)
            t.expect(node).to.equal(h.mod.select({ "rolenode1", "rolenode2" }, 7))
            t.expect(last_log(h).level).to.equal("warn")
        end)

        t.it("errors when neither discovery nor config offers a node", function()
            local h = harness()
            h.live = {}
            t.expect(function()
                h.mod.calc_node("ghost", {}, 1)
            end).to
                .throw("no available node for entity type: ghost")
            t.expect(function()
                h.mod.calc_node("ghost", { nodes = {} }, 1)
            end).to
                .throw("no available node for entity type: ghost")
        end)

        t.it("rejects a non-integer entity id before touching discovery", function()
            -- 分数计算用的是整数位运算，浮点 id 会在 ~ 上抛一条看不懂的错
            local h = harness()
            h.live = { "rolenode1" }
            t.expect(function()
                h.mod.calc_node("role", {}, 1.5)
            end).to
                .throw("entity id must be an integer: 1.5")
            t.expect(function()
                h.mod.calc_node("role", {}, "7")
            end).to
                .throw("entity id must be an integer: 7")
            t.expect(h.queries).to.equal(0)
        end)
    end)
end)
