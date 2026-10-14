local t = require "skytest"
local compat = require "skyext.orm_compat"

local function levels(changes)
    local out = {}
    for _, change in ipairs(changes) do
        out[#out + 1] = compat.format(change)
    end
    return out
end

local function role(fields)
    return { role = fields }
end

local INT = { type = "integer" }
local STR = { type = "string" }

t.describe("orm_compat 安全改动", function()
    t.it("两份相同的 schema 没有任何变更", function()
        local defs = role({ rid = INT, name = STR })
        t.expect(compat.diff(defs, defs)).to.equal({})
    end)

    t.it("加字段只是提示", function()
        local changes = compat.diff(role({ rid = INT }), role({ rid = INT, name = STR }))
        t.expect(compat.count(changes)[compat.INFO]).to.equal(1)
        t.expect(levels(changes)).to.equal({ "[info] role.name: 新增字段 string：旧文档加载时补零值" })
    end)

    t.it("加结构只是提示", function()
        local changes = compat.diff(role({ rid = INT }), { role = { rid = INT }, bag = { res = INT } })
        t.expect(levels(changes)).to.equal({ "[info] bag: 新增结构" })
    end)

    t.it("删字段能跑，但要提醒数据读不到了", function()
        local changes = compat.diff(role({ rid = INT, old = INT }), role({ rid = INT }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(0)
        t.expect(levels(changes)).to.equal({
            "[warn] role.old: 删除字段：库里已有的值从此读不到，确认这份数据不再需要",
        })
    end)
end)

t.describe("orm_compat 不兼容改动", function()
    t.it("改字段类型要拦下来", function()
        local changes = compat.diff(role({ rid = INT }), role({ rid = STR }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(1)
        t.expect(levels(changes)).to
            .equal({ "[break] role.rid: 类型从 integer 改成 string：旧文档里的值对不上" })
    end)

    t.it("标量换成容器要拦下来", function()
        local changes = compat.diff(role({ tags = STR }), role({ tags = { type = "array", item = "string" } }))
        t.expect(levels(changes)).to.equal({
            "[break] role.tags: 类型从 string 改成 array<string>：旧文档里的值对不上",
        })
    end)

    t.it("map 的键或值类型变了同样要拦", function()
        local old = role({ bags = { type = "map", key = "integer", value = "bag" } })
        local key_changed = role({ bags = { type = "map", key = "string", value = "bag" } })
        local value_changed = role({ bags = { type = "map", key = "integer", value = "bag2" } })
        t.expect(levels(compat.diff(old, key_changed))).to.equal({
            "[break] role.bags: 类型从 map<integer,bag> 改成 map<string,bag>：旧文档里的值对不上",
        })
        t.expect(levels(compat.diff(old, value_changed))).to.equal({
            "[break] role.bags: 类型从 map<integer,bag> 改成 map<integer,bag2>：旧文档里的值对不上",
        })
    end)

    t.it("array 的元素类型变了要拦", function()
        local old = role({ tags = { type = "array", item = "string" } })
        local new = role({ tags = { type = "array", item = "integer" } })
        t.expect(levels(compat.diff(old, new))).to.equal({
            "[break] role.tags: 类型从 array<string> 改成 array<integer>：旧文档里的值对不上",
        })
    end)

    t.it("换掉引用的结构名也是改类型", function()
        local changes =
            compat.diff(role({ modules = { type = "role_modules" } }), role({ modules = { type = "mods" } }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(1)
    end)
end)

t.describe("orm_compat 改名", function()
    t.it("同类型的一删一加算疑似改名，不再重复报新增", function()
        local changes = compat.diff(role({ rid = INT, nick = STR }), role({ rid = INT, name = STR }))
        t.expect(levels(changes)).to.equal({
            "[warn] role.nick: 疑似改名为 name（类型都是 string）：旧文档里的值不会跟着搬过去",
        })
    end)

    t.it("类型不同就不配对，各报各的", function()
        local changes = compat.diff(role({ nick = STR }), role({ level = INT }))
        t.expect(levels(changes)).to.equal({
            "[warn] role.nick: 删除字段：库里已有的值从此读不到，确认这份数据不再需要",
            "[info] role.level: 新增字段 integer：旧文档加载时补零值",
        })
    end)

    t.it("多个同类型字段一删一加时按字典序一一配对，结果稳定", function()
        local old = role({ a = STR, b = STR })
        local new = role({ x = STR, y = STR })
        local once = levels(compat.diff(old, new))
        t.expect(once).to.equal({
            "[warn] role.a: 疑似改名为 x（类型都是 string）：旧文档里的值不会跟着搬过去",
            "[warn] role.b: 疑似改名为 y（类型都是 string）：旧文档里的值不会跟着搬过去",
        })
        t.expect(levels(compat.diff(old, new))).to.equal(once)
    end)
end)

t.describe("orm_compat 结构删除", function()
    t.it("整个结构没了要提醒集合可能加载不起来", function()
        local changes = compat.diff({ role = { rid = INT }, bag = { res = INT } }, role({ rid = INT }))
        t.expect(levels(changes)).to.equal({
            "[warn] bag: 删除结构：如果它是某个集合的根结构，这个集合将无法加载",
        })
    end)
end)

t.describe("orm_compat 输出顺序", function()
    t.it("先 break 再 warn 最后 info，同级按结构名和字段名排", function()
        local old = { role = { rid = INT, gone = INT }, bag = { res = INT } }
        local new = { role = { rid = STR, added = INT }, bag = { res = STR } }
        t.expect(levels(compat.diff(old, new))).to.equal({
            "[break] bag.res: 类型从 integer 改成 string：旧文档里的值对不上",
            "[break] role.rid: 类型从 integer 改成 string：旧文档里的值对不上",
            "[warn] role.gone: 疑似改名为 added（类型都是 integer）：旧文档里的值不会跟着搬过去",
        })
        t.expect(compat.count(compat.diff(old, new))).to
            .equal({ [compat.BREAK] = 2, [compat.WARN] = 1, [compat.INFO] = 0 })
    end)
end)
