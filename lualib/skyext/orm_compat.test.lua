local t = require "skytest"
local compat = require "skyext.orm_compat"

local function levels(changes)
    local out = {}
    for _, change in ipairs(changes) do
        out[#out + 1] = compat.format(change)
    end
    return out
end

local INT = { type = "integer" }
local STR = { type = "string" }

-- 基线：types 是上次确认过的结构，retired 是删过、不许再用的名字
local function lock(types, retired_fields, retired_types)
    return {
        types = types,
        retired = { fields = retired_fields or {}, types = retired_types or {} },
    }
end

local function role(fields)
    return { role = fields }
end

t.describe("orm_compat 安全改动", function()
    t.it("两份相同的 schema 没有任何变更", function()
        local types = role({ rid = INT, name = STR })
        t.expect(compat.diff(lock(types), types)).to.equal({})
    end)

    t.it("加字段只是提示", function()
        local changes = compat.diff(lock(role({ rid = INT })), role({ rid = INT, name = STR }))
        t.expect(compat.count(changes)[compat.INFO]).to.equal(1)
        t.expect(levels(changes)).to.equal({ "[info] role.name: 新增字段 string：旧文档加载时补零值" })
    end)

    t.it("加结构只是提示", function()
        local changes = compat.diff(lock(role({ rid = INT })), { role = { rid = INT }, bag = { res = INT } })
        t.expect(levels(changes)).to.equal({ "[info] bag: 新增结构" })
    end)

    t.it("删字段能跑，但要提醒数据还在库里、名字不能再用", function()
        local changes = compat.diff(lock(role({ rid = INT, old = INT })), role({ rid = INT }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(0)
        t.expect(levels(changes)).to.equal({
            "[warn] role.old: 删除字段：库里已有的值从此读不到，这个名字之后不能再用",
        })
    end)
end)

t.describe("orm_compat 不兼容改动", function()
    t.it("改字段类型要拦下来", function()
        local changes = compat.diff(lock(role({ rid = INT })), role({ rid = STR }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(1)
        t.expect(levels(changes)).to
            .equal({ "[break] role.rid: 类型从 integer 改成 string：旧文档里的值对不上" })
    end)

    t.it("标量换成容器要拦下来", function()
        local changes = compat.diff(lock(role({ tags = STR })), role({ tags = { type = "array", item = "string" } }))
        t.expect(levels(changes)).to.equal({
            "[break] role.tags: 类型从 string 改成 array<string>：旧文档里的值对不上",
        })
    end)

    t.it("map 的键或值类型变了同样要拦", function()
        local old = lock(role({ bags = { type = "map", key = "integer", value = "bag" } }))
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
        local old = lock(role({ tags = { type = "array", item = "string" } }))
        local new = role({ tags = { type = "array", item = "integer" } })
        t.expect(levels(compat.diff(old, new))).to.equal({
            "[break] role.tags: 类型从 array<string> 改成 array<integer>：旧文档里的值对不上",
        })
    end)

    t.it("换掉引用的结构名也是改类型", function()
        local old = lock(role({ modules = { type = "role_modules" } }))
        t.expect(compat.count(compat.diff(old, role({ modules = { type = "mods" } })))[compat.BREAK]).to.equal(1)
    end)
end)

t.describe("orm_compat 墓碑", function()
    -- 删字段只是不再读它，值一直躺在 Mongo 里。几个版本之后有人加回同名字段，
    -- 相邻两次对比各自都是"兼容"的，只有墓碑记着才拦得住。
    t.it("加回删过的字段名要拦下来", function()
        local baseline = lock(role({ rid = INT }), { role = { create_time = "integer" } })
        local changes = compat.diff(baseline, role({ rid = INT, create_time = INT }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(1)
        t.expect(levels(changes)).to.equal({
            "[break] role.create_time: 这个名字之前删过（当时是 integer）："
                .. "库里还躺着那会儿写下的值，加回同名字段会把旧值当成新值读出来，换个名字",
        })
    end)

    t.it("换个类型加回来也一样拦，旧值还在那儿", function()
        local baseline = lock(role({ rid = INT }), { role = { create_time = "integer" } })
        local changes = compat.diff(baseline, role({ rid = INT, create_time = STR }))
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(1)
    end)

    t.it("换个名字就放行", function()
        local baseline = lock(role({ rid = INT }), { role = { create_time = "integer" } })
        local changes = compat.diff(baseline, role({ rid = INT, created_at = INT }))
        t.expect(levels(changes)).to
            .equal({ "[info] role.created_at: 新增字段 integer：旧文档加载时补零值" })
    end)

    t.it("墓碑只管自己那个结构，别的结构可以用这个名字", function()
        local baseline = lock({ role = { rid = INT }, bag = {} }, { role = { create_time = "integer" } })
        local changes = compat.diff(baseline, { role = { rid = INT }, bag = { create_time = INT } })
        t.expect(compat.count(changes)[compat.BREAK]).to.equal(0)
    end)

    t.it("加回删过的结构名要拦下来", function()
        local baseline = lock(role({ rid = INT }), nil, { bag = true })
        local changes = compat.diff(baseline, { role = { rid = INT }, bag = { res = INT } })
        t.expect(levels(changes)).to.equal({
            "[break] bag: 这个结构名之前删过：库里可能还留着按旧结构写下的文档，换个名字",
        })
    end)
end)

t.describe("orm_compat 生成新基线", function()
    t.it("把这次删掉的字段记进墓碑", function()
        local baseline = lock(role({ rid = INT, old = STR }))
        local new_lock = compat.build_lock(baseline, role({ rid = INT }))
        t.expect(new_lock.types).to.equal(role({ rid = INT }))
        t.expect(new_lock.retired.fields).to.equal({ role = { old = "string" } })
    end)

    t.it("墓碑只增不减，之前记下的不会因为这次没动就丢掉", function()
        local baseline = lock(role({ rid = INT, old = STR }), { role = { ancient = "integer" } })
        local new_lock = compat.build_lock(baseline, role({ rid = INT }))
        t.expect(new_lock.retired.fields).to.equal({ role = { ancient = "integer", old = "string" } })
    end)

    t.it("结构整个删掉时，结构名和它的字段名一起退休", function()
        local baseline = lock({ role = { rid = INT }, bag = { res = INT, cap = STR } })
        local new_lock = compat.build_lock(baseline, role({ rid = INT }))
        t.expect(new_lock.retired.types).to.equal({ bag = true })
        t.expect(new_lock.retired.fields).to.equal({ bag = { res = "integer", cap = "string" } })
    end)

    t.it(
        "名字又回到当前 schema 里（--force 放行过）就不再留墓碑，否则之后每次检查都失败",
        function()
            local baseline = lock(role({ rid = INT }), { role = { old = "string" } }, { bag = true })
            local new_lock = compat.build_lock(baseline, { role = { rid = INT, old = STR }, bag = { res = INT } })
            t.expect(new_lock.retired.fields).to.equal({})
            t.expect(new_lock.retired.types).to.equal({})
        end
    )

    t.it("加字段不会产生墓碑", function()
        local baseline = lock(role({ rid = INT }))
        local new_lock = compat.build_lock(baseline, role({ rid = INT, name = STR }))
        t.expect(new_lock.retired).to.equal({ fields = {}, types = {} })
    end)
end)

t.describe("orm_compat 改名", function()
    t.it("同类型的一删一加算疑似改名，不再重复报新增", function()
        local changes = compat.diff(lock(role({ rid = INT, nick = STR })), role({ rid = INT, name = STR }))
        t.expect(levels(changes)).to.equal({
            "[warn] role.nick: 疑似改名为 name（类型都是 string）：旧文档里的值不会跟着搬过去",
        })
    end)

    t.it("类型不同就不配对，各报各的", function()
        local changes = compat.diff(lock(role({ nick = STR })), role({ level = INT }))
        t.expect(levels(changes)).to.equal({
            "[warn] role.nick: 删除字段：库里已有的值从此读不到，这个名字之后不能再用",
            "[info] role.level: 新增字段 integer：旧文档加载时补零值",
        })
    end)

    t.it("多个同类型字段一删一加时按字典序一一配对，结果稳定", function()
        local old = lock(role({ a = STR, b = STR }))
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
        local baseline = lock({ role = { rid = INT }, bag = { res = INT } })
        t.expect(levels(compat.diff(baseline, role({ rid = INT })))).to.equal({
            "[warn] bag: 删除结构：如果它是某个集合的根结构，这个集合将无法加载，这个名字之后不能再用",
        })
    end)
end)

t.describe("orm_compat 输出顺序", function()
    t.it("先 break 再 warn 最后 info，同级按结构名和字段名排", function()
        local old = lock({ role = { rid = INT, gone = INT }, bag = { res = INT } })
        local new = { role = { rid = STR, added = INT }, bag = { res = STR } }
        t.expect(levels(compat.diff(old, new))).to.equal({
            "[break] bag.res: 类型从 integer 改成 string：旧文档里的值对不上",
            "[break] role.rid: 类型从 integer 改成 string：旧文档里的值对不上",
            "[warn] role.gone: 疑似改名为 added（类型都是 integer）：旧文档里的值不会跟着搬过去",
        })
        t.expect(compat.count(compat.diff(old, new))).to.equal({
            [compat.BREAK] = 2,
            [compat.WARN] = 1,
            [compat.INFO] = 0,
        })
    end)
end)

t.describe("orm_compat 基线序列化", function()
    t.it("键按字典序输出，同一份基线每次写出来都一样", function()
        local source = compat.encode(lock({ role = { rid = INT, account = STR } }, { role = { old = "string" } }))
        t.expect(source).to.equal([[
return {
    retired = {
        fields = {
            role = {
                old = "string",
            },
        },
        types = {},
    },
    types = {
        role = {
            account = {
                type = "string",
            },
            rid = {
                type = "integer",
            },
        },
    },
}
]])
    end)

    t.it("写出来的基线能原样读回去", function()
        local original = compat.build_lock(lock({ role = { rid = INT, ["odd key"] = STR } }), role({ rid = INT }))
        local restored = assert(load(compat.encode(original), "lock", "t", {}))()
        t.expect(restored).to.equal(original)
        t.expect(compat.diff(restored, original.types)).to.equal({})
    end)
end)
