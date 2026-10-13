local t = require "skytest"
local bson = require "bson"
local orm = require "orm"

local integer = { type = "integer" }
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
