local t = require "skytest"
local bson = require "bson"
local orm = require "orm"

local integer = { type = "integer" }
local str = { type = "string" }
local item = { type = "message", count = integer }
local items = { type = "map", count = item }
local list = { type = "array", count = integer }
local item_list = { type = "array", count = item }
local root = { type = "message", rid = integer, _version = integer, items = items, list = list, item_list = item_list }
setmetatable(items, {
    __index = function(_, k)
        return tonumber(k) and item
    end,
})
setmetatable(list, {
    __index = function(_, k)
        return tonumber(k) and integer
    end,
})
setmetatable(item_list, {
    __index = function(_, k)
        return tonumber(k) and item
    end,
})

local function install_checks(schema)
    function schema:_parse_k(k)
        if self.type == "map" or self.type == "array" then
            return assert(tonumber(k))
        end
        assert(self[k], "unknown key: " .. tostring(k))
        return k
    end
    function schema:_check_k(k)
        self:_parse_k(k)
    end
    function schema:_check_kv(k, value)
        local expected = self.type == "message" and self[k] or self.count
        assert(expected == value or (expected == integer and type(value) == "number"))
    end
end
for _, schema in ipairs({ item, items, list, item_list, root }) do
    install_checks(schema)
end

local function new_doc()
    return orm.new(root, {
        rid = 1,
        _version = 0,
        items = { [1] = { count = 2 } },
        list = { 3, 4 },
        item_list = { { count = 1 }, { count = 2 }, { count = 3 } },
    })
end

t.describe("ORM Mongo snapshots", function()
    t.it("does not clear dirty state while preparing a detached snapshot", function()
        local doc = new_doc()
        doc.items[1].count = 5
        local dirty, update, revision = orm.snapshot_mongo(doc)
        t.expect(dirty).to.equal(true)
        t.expect(update["$set"].items["1"].count).to.equal(5)
        t.expect(orm.is_dirty(doc)).to.equal(true)
        doc.items[1].count = 6
        t.expect(update["$set"].items["1"].count).to.equal(5)
        t.expect(orm.ack_mongo(doc, revision, 1)).to.equal(false)
        t.expect(doc._version).to.equal(1)
        t.expect(orm.is_dirty(doc)).to.equal(true)
        local _, retry = orm.snapshot_mongo(doc)
        t.expect(retry["$set"].items["1"].count).to.equal(6)
    end)

    t.it("clears dirty flags only after confirmed acknowledgement", function()
        local doc = new_doc()
        doc.items[1].count = 9
        local _, update, revision = orm.snapshot_mongo(doc)
        t.expect(update["$set"].items["1"].count).to.equal(9)
        t.expect(orm.ack_mongo(doc, revision, 1)).to.equal(true)
        t.expect(orm.is_dirty(doc)).to.equal(false)
        t.expect(orm.is_dirty(doc.items[1])).to.equal(false)
        t.expect(doc._version).to.equal(1)
        local dirty = orm.snapshot_mongo(doc)
        t.expect(dirty).to.equal(false)
    end)

    t.it("stores replacements and deletions as complete top-level fields", function()
        local doc = new_doc()
        doc.items[1] = nil
        doc.list = {}
        local _, update = orm.snapshot_mongo(doc)
        t.expect(update["$set"].items).to.equal({})
        t.expect(update["$set"].list).to.equal({})
        t.expect(update["$unset"]).to.be_nil()
        doc.items = nil
        local _, deleted = orm.snapshot_mongo(doc)
        t.expect(deleted["$unset"].items).to.equal(true)
        t.expect(deleted["$set"].items).to.be_nil()
    end)

    t.it("encodes empty arrays as BSON arrays and maps with string keys", function()
        local doc = new_doc()
        doc.list = {}
        local _, update = orm.snapshot_mongo(doc)
        local encoded = bson.encode({ list = update["$set"].list })
        t.expect(tostring(encoded):byte(5)).to.equal(4)
        t.expect(orm.to_bson(doc).items["1"].count).to.equal(2)
    end)

    t.it("does not mark a parent dirty after replacing an attached child", function()
        local doc = new_doc()
        local removed = doc.items[1]
        doc.items[1] = { count = 7 }
        local _, _, revision = orm.snapshot_mongo(doc)
        orm.ack_mongo(doc, revision, 1)
        removed.count = 99
        t.expect(orm.is_dirty(doc)).to.equal(false)
    end)

    t.it("tracks surviving array children after a removal is acknowledged", function()
        local doc = new_doc()
        local removed = doc.item_list[1]
        local moved = doc.item_list[2]
        local last = doc.item_list[3]
        t.expect(orm.remove(doc.item_list, 1)).to.equal(removed)
        t.expect(#doc.item_list).to.equal(2)
        t.expect(doc.item_list[1]).to.equal(moved)
        t.expect(doc.item_list[2]).to.equal(last)
        local _, update, revision = orm.snapshot_mongo(doc)
        t.expect(update["$set"].item_list[1].count).to.equal(2)
        t.expect(update["$set"].item_list[2].count).to.equal(3)
        t.expect(orm.ack_mongo(doc, revision, 1)).to.equal(true)

        removed.count = 88
        t.expect(orm.is_dirty(doc)).to.equal(false)
        moved.count = 77
        t.expect(orm.is_dirty(doc)).to.equal(true)
        local changed, next_update = orm.snapshot_mongo(doc)
        t.expect(changed).to.equal(true)
        t.expect(next_update["$set"].item_list[1].count).to.equal(77)
    end)

    t.it("tracks surviving array children after an insertion is acknowledged", function()
        local doc = new_doc()
        local moved = doc.item_list[2]
        local last = doc.item_list[3]
        orm.insert(doc.item_list, 2, { count = 8 })
        t.expect(#doc.item_list).to.equal(4)
        t.expect(doc.item_list[2].count).to.equal(8)
        t.expect(doc.item_list[3]).to.equal(moved)
        t.expect(doc.item_list[4]).to.equal(last)
        local _, update, revision = orm.snapshot_mongo(doc)
        t.expect(update["$set"].item_list[4].count).to.equal(3)
        t.expect(orm.ack_mongo(doc, revision, 1)).to.equal(true)

        last.count = 99
        t.expect(orm.is_dirty(doc)).to.equal(true)
        local changed, next_update = orm.snapshot_mongo(doc)
        t.expect(changed).to.equal(true)
        t.expect(next_update["$set"].item_list[4].count).to.equal(99)
    end)

    t.it("moves scalar array elements and rejects out-of-range positions without changing data", function()
        local doc = new_doc()
        orm.insert(doc.list, 1, 9)
        t.expect(orm.to_bson(doc).list).to.equal({ 9, 3, 4 })
        t.expect(orm.remove(doc.list, 2)).to.equal(3)
        t.expect(orm.to_bson(doc).list).to.equal({ 9, 4 })
        local _, _, revision = orm.snapshot_mongo(doc)
        orm.ack_mongo(doc, revision, 1)
        t.expect(orm.remove(doc.list, 3)).to.be_nil()
        t.expect(pcall(orm.insert, doc.list, 5, 1)).to.equal(false)
        t.expect(pcall(orm.remove, doc.list, 5)).to.equal(false)
        t.expect(orm.is_dirty(doc)).to.equal(false)
        t.expect(orm.to_bson(doc).list).to.equal({ 9, 4 })
    end)
end)

t.describe("ORM schema reload", function()
    local function message(schema_name, fields)
        local obj = { type = "message" }
        for k, v in pairs(fields) do
            obj[k] = v
        end
        setmetatable(obj, {
            __tostring = function()
                return "schema_" .. schema_name
            end,
        })
        return obj
    end

    t.it("refuses to reload a schema table into itself", function()
        local role = message("role", { rid = integer })
        local old_schema = { role = role }
        -- 同一张表 reload 会先把 schema 清空再从自己被清空的自己身上取值，必须拒绝
        t.expect(function()
            orm.reload_schema(old_schema, old_schema)
        end).to
            .throw("distinct new_schema")
        -- 拒绝之后不能留下半清空的状态
        t.expect(old_schema.role).to.equal(role)
        t.expect(role.rid).to.equal(integer)
        t.expect(role.type).to.equal("message")
    end)

    t.it("keeps table and object identity while swapping field definitions", function()
        local role = message("role", { rid = integer, name = str })
        local old_schema = { role = role }
        local new_role = message("role", { rid = integer, level = integer })

        orm.reload_schema(old_schema, { role = new_role })

        -- 引用必须保持不变：进程里已有的 orm doc 和 role.new 闭包都持有它
        t.expect(old_schema.role).to.equal(role)
        t.expect(role.rid).to.equal(integer)
        t.expect(role.level).to.equal(integer)
        t.expect(role.name).to.be_nil()
        t.expect(getmetatable(role)).to.equal(getmetatable(new_role))
        t.expect(tostring(role)).to.equal("schema_role")
    end)

    t.it("drops removed types and picks up newly added ones", function()
        local role = message("role", { rid = integer })
        local mail = message("mail", { id = integer })
        local old_schema = { role = role, mail = mail }
        local bag = message("bag", { size = integer })

        orm.reload_schema(old_schema, { role = message("role", { rid = integer }), bag = bag })

        t.expect(old_schema.role).to.equal(role)
        t.expect(old_schema.role.rid).to.equal(integer)
        t.expect(old_schema.mail).to.be_nil()
        t.expect(old_schema.bag).to.equal(bag)
    end)

    t.it("keeps an already loaded doc usable across a reload", function()
        local role_schema = message("role", { rid = integer, level = integer })
        install_checks(role_schema)
        -- 生成代码里的 role.new 捕获的就是 schema 表里那个对象
        role_schema.new = function(init)
            return orm.new(role_schema, init)
        end
        local old_schema = { role = role_schema }
        local doc = old_schema.role.new({ rid = 1, level = 2 })
        t.expect(doc.level).to.equal(2)

        local new_role = message("role", { rid = integer, level = integer, exp = integer })
        install_checks(new_role)
        new_role.new = function(init)
            return orm.new(new_role, init)
        end
        orm.reload_schema(old_schema, { role = new_role })

        -- reload 之前建好的 doc 仍然可用，并且能写新增字段
        doc.exp = 100
        t.expect(orm.is_dirty(doc)).to.equal(true)
        t.expect(orm.to_bson(doc).exp).to.equal(100)

        -- reload 之后新建的 doc 也走同一份定义
        local fresh = old_schema.role.new({ rid = 2, exp = 7 })
        t.expect(orm.is_orm(fresh)).to.equal(true)
        t.expect(orm.to_bson(fresh).exp).to.equal(7)
    end)
end)

t.describe("orm.decode", function()
    local int_t = { type = "integer" }
    local str_t = { type = "string" }
    local bool_t = { type = "boolean" }

    -- 按生成器产出的形状造 schema：字段直接挂在表上，带 fields() 和类型检查
    local function struct(name, fields)
        local obj = { type = "struct" }
        local names = {}
        for k, v in pairs(fields) do
            obj[k] = v
            names[#names + 1] = k
        end
        table.sort(names)
        obj.fields = function()
            return names
        end
        obj._parse_k = function(self, k)
            assert(self[k], "not exist key: " .. tostring(k))
            return k
        end
        obj._check_k = obj._parse_k
        obj._check_kv = function(self, k, v)
            local field = self[k]
            assert(field, "not exist key: " .. tostring(k))
            if field == int_t then
                assert(math.tointeger(v), "need integer")
            elseif field == str_t then
                assert(type(v) == "string", "need string")
            elseif field == bool_t then
                assert(type(v) == "boolean", "need boolean")
            else
                assert(field == v, "need " .. name .. "." .. k)
            end
        end
        return obj
    end

    local function container(tp, value_t)
        local obj = { type = tp }
        setmetatable(obj, {
            __index = function()
                return value_t
            end,
        })
        obj._parse_k = function(_, k)
            return math.tointeger(k) or k
        end
        obj._check_k = obj._parse_k
        obj._check_kv = function(_, _, v)
            if value_t == int_t then
                assert(math.tointeger(v), "need integer")
            else
                assert(value_t == v, "need " .. tp .. " value")
            end
        end
        return obj
    end

    t.it("drops fields the schema no longer declares and reports their paths", function()
        local role = struct("role", { rid = int_t, name = str_t })
        local doc, dropped = orm.decode(role, { rid = 1, name = "a", nick = "old", level = 3 })
        t.expect(dropped).to.equal({ "level", "nick" })
        t.expect(doc.rid).to.equal(1)
        t.expect(doc.name).to.equal("a")
        -- 丢掉的字段连读都不该读到
        t.expect(function()
            return doc.nick
        end).to
            .throw("not exist key")
    end)

    t.it("fills a newly declared scalar with its zero value", function()
        local role = struct("role", { rid = int_t, name = str_t, vip = bool_t, exp = int_t })
        local doc = orm.decode(role, { rid = 1 })
        t.expect(doc.rid).to.equal(1)
        t.expect(doc.exp).to.equal(0)
        t.expect(doc.name).to.equal("")
        t.expect(doc.vip).to.equal(false)
    end)

    t.it("fills a newly declared struct, map and array", function()
        local attach = struct("attach", { res_id = int_t, res_size = int_t })
        local mails = container("map", attach)
        local tags = container("array", int_t)
        local role = struct("role", { rid = int_t, attach = attach, mails = mails, tags = tags })

        local doc = orm.decode(role, { rid = 1 })
        -- 新结构体的标量同样补到底，玩法代码可以直接 doc.attach.res_id
        t.expect(doc.attach.res_id).to.equal(0)
        t.expect(orm.to_bson(doc.mails)).to.equal({})
        t.expect(#doc.tags).to.equal(0)
    end)

    t.it("keeps the filled-in values clean so they are never written back", function()
        local role = struct("role", { rid = int_t, exp = int_t })
        local doc = orm.decode(role, { rid = 1, extra = 1 })
        t.expect(orm.is_dirty(doc)).to.equal(false)
        local is_dirty, update = orm.snapshot_mongo(doc)
        t.expect(is_dirty).to.equal(false)
        t.expect(update).to.equal({})
    end)

    t.it("aligns nested structs and the values inside a map", function()
        local mail = struct("mail", { mail_id = int_t, title = str_t })
        local mails = container("map", mail)
        local modules = struct("modules", { mails = mails })
        local role = struct("role", { rid = int_t, modules = modules })

        local doc, dropped = orm.decode(role, {
            rid = 1,
            modules = { mails = { [1] = { mail_id = 7, subject = "old" } }, legacy = 1 },
        })
        t.expect(dropped).to.equal({ "modules.legacy", "modules.mails.1.subject" })
        t.expect(doc.modules.mails[1].mail_id).to.equal(7)
        t.expect(doc.modules.mails[1].title).to.equal("")
    end)

    t.it("leaves a self-referencing struct field empty instead of recursing forever", function()
        local node = struct("node", { id = int_t })
        node.next = node
        node.fields = function()
            return { "id", "next" }
        end
        local doc = orm.decode(node, { id = 1 })
        t.expect(doc.id).to.equal(1)
        t.expect(doc.next).to.be_nil()
    end)
end)
