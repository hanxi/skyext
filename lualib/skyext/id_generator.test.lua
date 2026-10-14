local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/id_generator.lua")

local function harness()
    local h = { forks = {}, batches = {}, singles = 0, next_id = 1, logs = {} }

    local function take(count)
        local ids = {}
        for i = 1, count do
            ids[i] = h.next_id
            h.next_id = h.next_id + 1
        end
        return ids
    end

    local imports = {
        skynet = {
            fork = function(f)
                h.forks[#h.forks + 1] = f
            end,
            init = function(f)
                h.boot = f
            end,
        },
        ["skyext.log"] = {
            debug = function(msg, ...)
                h.logs[#h.logs + 1] = { "debug", msg, ... }
            end,
            error = function(msg, ...)
                h.logs[#h.logs + 1] = { "error", msg, ... }
            end,
        },
        ["skyext.snowflake"] = {
            newid = function()
                if h.fail then
                    error(h.fail, 0)
                end
                h.singles = h.singles + 1
                return take(1)[1]
            end,
            newids = function(count)
                if h.fail then
                    error(h.fail, 0)
                end
                h.batches[#h.batches + 1] = count
                return take(count)
            end,
        },
    }

    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.idgen = assert(loadfile(source, "t", env))()

    function h.run_forks()
        local pending = h.forks
        h.forks = {}
        for _, f in ipairs(pending) do
            f()
        end
    end

    -- 走一遍 skynet.init：正常启动时缓存在这里灌满
    function h.boot_ok()
        h.boot()
        h.run_forks()
    end

    return h
end

t.describe("id_generator cache", function()
    t.it("prefetches a full batch on init and serves newid from it", function()
        local h = harness()
        h.boot_ok()
        t.expect(h.batches).to.equal({ 1000 })
        t.expect(h.idgen.get_cache_status().size).to.equal(1000)

        local id = h.idgen.newid()
        t.expect(id).to.exist()
        -- 缓存里有货就不该再打一次 snowflake
        t.expect(h.singles).to.equal(0)
        t.expect(h.idgen.get_cache_status().size).to.equal(999)
    end)

    t.it("hands out distinct ids", function()
        local h = harness()
        h.boot_ok()
        local seen = {}
        for _ = 1, 500 do
            local id = h.idgen.newid()
            t.expect(seen[id]).to.be_nil()
            seen[id] = true
        end
        t.expect(h.idgen.get_cache_status().size).to.equal(500)
    end)

    t.it("refills in the background once the cache drops to the threshold", function()
        local h = harness()
        h.boot_ok()
        for _ = 1, 799 do
            h.idgen.newid()
        end
        -- 还剩 201 个，没到 20%，不该有补充任务
        t.expect(#h.forks).to.equal(0)
        h.idgen.newid()
        t.expect(#h.forks).to.equal(1)
        t.expect(h.idgen.get_cache_status().is_refilling).to.equal(true)

        h.run_forks()
        t.expect(h.batches).to.equal({ 1000, 1000 })
        t.expect(h.idgen.get_cache_status().size).to.equal(1200)
        t.expect(h.idgen.get_cache_status().is_refilling).to.equal(false)
    end)

    t.it("does not stack refills while one is already in flight", function()
        local h = harness()
        h.boot_ok()
        for _ = 1, 850 do
            h.idgen.newid()
        end
        t.expect(#h.forks).to.equal(1)
        h.run_forks()
        t.expect(h.batches).to.equal({ 1000, 1000 })
    end)
end)

t.describe("id_generator refill failure", function()
    t.it("retries the refill on the next newid after the boot refill failed", function()
        local h = harness()
        h.fail = "snowflake machine id is not held"
        h.boot()
        h.run_forks()
        t.expect(h.idgen.get_cache_status().size).to.equal(0)
        t.expect(h.logs[1]).to.equal({ "error", "id_generator refill failed", "err", h.fail })

        -- 回归：以前缓存空了只会同步打一次 snowflake，永远不再补充，
        -- 启动期抢号慢一拍就让整个进程退化成每个 ID 一次 etcd 往返
        h.fail = nil
        local id = h.idgen.newid()
        t.expect(id).to.exist()
        t.expect(h.singles).to.equal(1)
        t.expect(#h.forks).to.equal(1)

        h.run_forks()
        t.expect(h.idgen.get_cache_status().size).to.equal(1000)
        t.expect(h.idgen.newid()).to.exist()
        t.expect(h.singles).to.equal(1)
    end)

    t.it("keeps serving ids while the refill still fails", function()
        local h = harness()
        h.fail = "snowflake machine id is not held"
        h.boot()
        h.run_forks()

        h.fail = nil
        t.expect(h.idgen.newid()).to.exist()
        -- 补充任务还挂着，这一次不该再排一个
        t.expect(h.idgen.newid()).to.exist()
        t.expect(#h.forks).to.equal(1)
        t.expect(h.singles).to.equal(2)
    end)
end)

t.describe("id_generator newids", function()
    t.it("serves a batch out of the cache", function()
        local h = harness()
        h.boot_ok()
        local ids = h.idgen.newids(10)
        t.expect(#ids).to.equal(10)
        t.expect(h.batches).to.equal({ 1000 })
        t.expect(h.idgen.get_cache_status().size).to.equal(990)
    end)

    t.it("tops up from snowflake when the cache cannot cover the request", function()
        local h = harness()
        h.boot_ok()
        local ids = h.idgen.newids(1200)
        t.expect(#ids).to.equal(1200)
        local seen = {}
        for _, id in ipairs(ids) do
            t.expect(seen[id]).to.be_nil()
            seen[id] = true
        end
        -- 缓存掏空后差额直接同步取，同时排一次补充
        t.expect(h.batches).to.equal({ 1000, 200 })
        t.expect(#h.forks).to.equal(1)
    end)

    t.it("works before any refill has succeeded", function()
        local h = harness()
        local ids = h.idgen.newids(3)
        t.expect(#ids).to.equal(3)
        t.expect(h.batches).to.equal({ 3 })
    end)
end)
