local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/entity_handler/rank.lua")

-- 普通表就能代替 ORM 文档；实体定时器换成手动触发
local function harness()
    local h = { now = 1000 }
    local env = setmetatable({
        require = function(name)
            if name == "skyext.time" then
                return {
                    now_ms = function()
                        h.now = h.now + 1
                        return h.now
                    end,
                }
            end
            return require(name)
        end,
    }, { __index = _G })
    h.rank = assert(loadfile(source, "t", env))()
    h.entity = {
        data = { entries = {} },
        every = function(_, name, sec, fn)
            h.timer = { name = name, sec = sec, fn = fn }
        end,
    }
    h.rank.on_load(h.entity)
    function h.submit(rid, score)
        return h.rank.handlers.submit(h.entity, rid, "p" .. rid, score)
    end
    function h.tick()
        h.timer.fn(h.entity)
    end
    function h.top(count)
        local rids = {}
        for i, e in ipairs(h.rank.handlers.top(h.entity, count)) do
            rids[i] = e.rid
        end
        return rids
    end
    return h
end

t.describe("rank entity", function()
    t.it("refreshes the ranking on its own timer, not on every submit", function()
        local h = harness()
        t.expect(h.timer.name).to.equal("refresh")
        h.submit(1, 50)
        h.submit(2, 80)
        t.expect(h.top(10)).to.equal({})
        h.tick()
        t.expect(h.top(10)).to.equal({ 2, 1 })
    end)

    t.it("keeps only a player's best score", function()
        local h = harness()
        t.expect(h.submit(1, 50)).to.equal(true)
        t.expect(h.submit(1, 40)).to.equal(false)
        t.expect(h.submit(1, 50)).to.equal(false)
        t.expect(h.submit(1, 60)).to.equal(true)
        h.tick()
        t.expect(h.rank.handlers.top(h.entity, 1)).to.equal({ { rid = 1, name = "p1", score = 60 } })
    end)

    t.it("breaks ties by who got there first", function()
        local h = harness()
        h.submit(9, 70)
        h.submit(3, 70)
        h.tick()
        t.expect(h.top(10)).to.equal({ 9, 3 })
    end)

    t.it("trims the board to the top 100 so the document stays bounded", function()
        local h = harness()
        for rid = 1, 120 do
            h.submit(rid, rid)
        end
        h.tick()
        local count = 0
        for _ in pairs(h.entity.data.entries) do
            count = count + 1
        end
        t.expect(count).to.equal(100)
        t.expect(h.entity.data.entries[20]).to.be_nil()
        t.expect(h.top(3)).to.equal({ 120, 119, 118 })
    end)

    t.it("ranks what is already stored as soon as it loads", function()
        local h = harness()
        h.entity.data.entries[5] = { rid = 5, name = "p5", score = 10, time = 1 }
        h.rank.on_load(h.entity)
        t.expect(h.top(10)).to.equal({ 5 })
    end)
end)
