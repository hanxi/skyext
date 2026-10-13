local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local orm = require "orm"
local skynet = require "skynet"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/dbmgr.lua")

local schema = { type = "message", rid = true, _version = true, name = true }
function schema:_parse_k(k)
    assert(self[k], "unknown key: " .. tostring(k))
    return k
end
function schema:_check_k(k)
    self:_parse_k(k)
end
function schema:_check_kv(k, value)
    assert(self[k])
    assert(type(value) == (k == "name" and "string" or "number"))
end

-- 下面是一个极小的 Mongo 行为模型：只支持 dbmgr 真正用到的算子，
-- 但 query/update/upsert/projection 的语义与 mongod 一致，
-- 这样测试才能复现“旧持有者在认领前后写入”的交错。
local function copy(doc)
    local out = {}
    for k, v in pairs(doc) do
        out[k] = v
    end
    return out
end

local function match_doc(doc, query)
    if not doc then
        return false
    end
    for k, v in pairs(query) do
        if k == "$or" then
            local any = false
            for _, sub in ipairs(v) do
                if match_doc(doc, sub) then
                    any = true
                    break
                end
            end
            if not any then
                return false
            end
        elseif type(v) == "table" then
            for op, operand in pairs(v) do
                if op == "$lte" then
                    -- mongod 的类型分组：缺失字段不会匹配数值比较算子
                    if doc[k] == nil or doc[k] > operand then
                        return false
                    end
                elseif op == "$exists" then
                    if (doc[k] ~= nil) ~= operand then
                        return false
                    end
                else
                    error("unsupported query operator: " .. tostring(op))
                end
            end
        elseif doc[k] ~= v then
            return false
        end
    end
    return true
end

local function apply_update(doc, update, inserting)
    for op, fields in pairs(update) do
        if op == "$set" or (op == "$setOnInsert" and inserting) then
            for k, v in pairs(fields) do
                doc[k] = v
            end
        elseif op ~= "$setOnInsert" then
            error("unsupported update operator: " .. tostring(op))
        end
    end
end

local function project(doc, fields)
    local out = {}
    for k, v in pairs(doc) do
        if not fields or fields[k] ~= false then
            out[k] = v
        end
    end
    return out
end

local DEFAULT_ROW = { rid = 7, _version = 0, name = "original" }

-- harness(handle, stored, defer)
--   stored: nil 用默认行；false 表示集合里还没有这条文档；table 则作为初始文档
--   defer:  true 时不自动 load，由用例自己调用
local function harness(handle, stored, defer)
    local h = { calls = 0, fam = {}, updates = {}, cancelled = false, fail = false, handle = handle, duplicates = 0 }
    if stored == nil then
        h.store = copy(DEFAULT_ROW)
    elseif stored then
        h.store = stored
    end

    local collection = {}
    h.collection = collection

    local function run_find_and_modify(opts)
        assert(opts.query, "findAndModify requires query")
        assert(opts.update, "findAndModify requires update")
        if opts.update["$set"] and opts.update["$setOnInsert"] then
            for k in pairs(opts.update["$set"]) do
                assert(opts.update["$setOnInsert"][k] == nil, "conflicting update path: " .. k)
            end
        end
        if h.fam_fail == "exception" then
            error("network failure")
        elseif h.fam_fail then
            return { ok = 0, errmsg = "command failed" }
        end
        if match_doc(h.store, opts.query) then
            local before = copy(h.store)
            apply_update(h.store, opts.update, false)
            return { ok = 1, value = project(opts.new and h.store or before, opts.fields) }
        end
        if not opts.upsert then
            -- 驱动把 BSON null 解码成单字节字符串
            return { ok = 1, value = "\0", lastErrorObject = { n = 0 } }
        end
        if h.store then
            -- 真实 mongod 会插入第二条同 key 文档（没有唯一索引时），
            -- 这里只记账，用例断言实现永远不走到这条路径。
            h.duplicates = h.duplicates + 1
            return { ok = 1, value = "\0", lastErrorObject = { n = 0 } }
        end
        local inserted = {}
        for k, v in pairs(opts.query) do
            if k ~= "$or" and type(v) ~= "table" then
                inserted[k] = v
            end
        end
        apply_update(inserted, opts.update, true)
        h.store = inserted
        return {
            ok = 1,
            value = opts.new and project(inserted, opts.fields) or "\0",
            lastErrorObject = { n = 1, upserted = 1 },
        }
    end

    function collection:find_and_modify(opts)
        h.calls = h.calls + 1
        h.fam[#h.fam + 1] = opts
        if h.on_fam then
            h.on_fam(opts)
        end
        local reply = run_find_and_modify(opts)
        if h.after_fam then
            h.after_fam(opts)
        end
        return reply
    end

    function collection:safe_update(query, update, upsert)
        h.updates[#h.updates + 1] = { query = query, update = update, upsert = upsert }
        if h.on_update then
            h.on_update()
        end
        if h.fail == "exception" then
            error("network failure")
        end
        if h.fail then
            return false, "write failed", { n = 0, nModified = 0 }
        end
        if h.matched == false then
            return true, nil, { n = 0, nModified = 0 }
        end
        if not match_doc(h.store, query) then
            return true, nil, { n = 0, nModified = 0 }
        end
        apply_update(h.store, update, false)
        return true, nil, { n = 1, nModified = 1 }
    end

    local imports = {
        skynet = { init = function() end },
        ["skyext.config"] = {
            get_table = function()
                return { demo = { collections = { role = {} } } }
            end,
            get_number = function()
                return 10
            end,
        },
        ["skyext.log"] = { debug = function() end, info = function() end, error = function() end },
        ["skyext.mongo_conn"] = {
            get_collection = function()
                return collection
            end,
        },
        ["skyext.distributed_lock"] = {
            is_valid = function(lease)
                return lease.valid
            end,
        },
        ["game.orm.schema"] = {
            role = {
                new = function(data)
                    return orm.new(schema, data)
                end,
            },
        },
        ["skyext.timer"] = {
            repeat_random_delayed = function(_, _, fn)
                h.timer = fn
                return {
                    cancel = function()
                        h.cancelled = true
                    end,
                }
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.db = assert(loadfile(source, "t", env))()
    if not defer then
        h.doc, h.load_error = h.db.load("demo", "role", "rid", 7, nil, handle)
        if not handle or h.doc then
            assert(h.doc, h.load_error)
        end
    end
    return h
end

t.describe("dbmgr persistence", function()
    t.it("retains a dirty document and version on write failure", function()
        local h = harness()
        h.doc.name = "updated"
        h.fail = true
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.doc._version).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(h.updates[1].upsert).to.equal(false)
        t.expect(h.updates[1].update["$set"]._version).to.equal(1)
        t.expect(h.db.load("demo", "role", "rid", 7)).to.equal(h.doc)
        t.expect(h.calls).to.equal(1)
        h.fail = false
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(false)
        t.expect(h.store.name).to.equal("updated")
        t.expect(h.store._version).to.equal(1)
    end)

    t.it("does not evict cache or cancel retry timer on uncertain or unmatched writes", function()
        local h = harness()
        h.doc.name = "updated"
        h.fail = "exception"
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.cancelled).to.equal(false)
        t.expect(h.db.load("demo", "role", "rid", 7)).to.equal(h.doc)
        h.fail = false
        h.matched = false
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        h.matched = true
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.cancelled).to.equal(true)
    end)

    t.it("claims a fencing token and constrains every subsequent write by fence and version", function()
        local handle = { fence = 13, valid = true }
        local h = harness(handle)
        t.expect(h.calls).to.equal(1)
        local claim = h.fam[1]
        t.expect(claim.query.rid).to.equal(7)
        t.expect(claim.query["$or"][1]._fence["$lte"]).to.equal(13)
        t.expect(claim.query["$or"][2]._fence["$exists"]).to.equal(false)
        t.expect(claim.update["$set"]._fence).to.equal(13)
        t.expect(claim.update["$setOnInsert"]).to.be_nil()
        t.expect(claim.upsert).to.equal(false)
        t.expect(claim.new).to.equal(true)
        t.expect(claim.fields._fence).to.equal(false)
        t.expect(h.store._fence).to.equal(13)
        t.expect(#h.updates).to.equal(0)
        h.doc.name = "saved"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[1].query._version).to.equal(0)
        t.expect(h.updates[1].query._fence).to.equal(13)
        t.expect(h.updates[1].upsert).to.equal(false)
        h.doc.name = "unsaved"
        handle.valid = false
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.db.discard_clean("demo", "role", 7, handle)).to.equal(false)
        t.expect(#h.updates).to.equal(1)
        t.expect(h.cancelled).to.equal(false)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        local replacement, err = h.db.load("demo", "role", "rid", 7, nil, { fence = 14, valid = true })
        t.expect(replacement).to.be_nil()
        t.expect(err).to.equal("stale dirty cache requires recovery")
    end)

    t.it("loads the document its own claim returned, so a losing holder cannot strand the cache", function()
        -- 旧持有者 fence=5 还在写；新持有者 fence=13 来接管。
        local h = harness(nil, { rid = 7, _version = 0, name = "original", _fence = 5 }, true)
        h.after_fam = function()
            -- 认领返回之后旧持有者才把写入发出去：读与认领若不是同一次操作，
            -- 这条写入就会落在两者之间，缓存文档从此永远追不上数据库。
            h.after_fam = nil
            local _, _, reply = h.collection:safe_update(
                { rid = 7, _version = 0, _fence = 5 },
                { ["$set"] = { name = "old-write", _version = 1 } },
                false
            )
            h.old_reply = reply
        end
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { fence = 13, valid = true }))
        -- 认领已经抬高 fence，旧持有者的写入被拒
        t.expect(h.old_reply.n).to.equal(0)
        t.expect(h.store.name).to.equal("original")
        t.expect(h.store._fence).to.equal(13)
        t.expect(doc.name).to.equal("original")
        t.expect(doc._version).to.equal(0)
        -- 缓存与数据库一致，新持有者的写入能生效
        doc.name = "successor"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.store.name).to.equal("successor")
        t.expect(h.store._version).to.equal(1)
    end)

    t.it("adopts a write that landed before the claim instead of reading a stale snapshot", function()
        local h = harness(nil, { rid = 7, _version = 0, name = "original", _fence = 5 }, true)
        h.on_fam = function()
            h.on_fam = nil
            h.collection:safe_update(
                { rid = 7, _version = 0, _fence = 5 },
                { ["$set"] = { name = "in-flight", _version = 1 } },
                false
            )
        end
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { fence = 13, valid = true }))
        t.expect(doc.name).to.equal("in-flight")
        t.expect(doc._version).to.equal(1)
        doc.name = "successor"
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.store._version).to.equal(2)
    end)

    t.it("refuses to claim or duplicate a row already owned by a higher fence", function()
        local h = harness({ fence = 4, valid = true })
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        h.store._fence = 9
        local doc, err = h.db.load("demo", "role", "rid", 7, nil, { fence = 5, valid = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence superseded")
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.store._fence).to.equal(9)
        -- 创建分支只能带 $setOnInsert，不能改动既有文档
        t.expect(h.fam[#h.fam].update["$setOnInsert"]).to.be_type("table")
        t.expect(h.fam[#h.fam].update["$set"]).to.be_nil()
        t.expect(h.fam[#h.fam].query["$or"]).to.be_nil()
        t.expect(h.store.name).to.equal("original")
        -- fence 更高的后继者照常接管
        local successor = assert(h.db.load("demo", "role", "rid", 7, nil, { fence = 11, valid = true }))
        t.expect(successor).to.be_type("table")
        t.expect(h.store._fence).to.equal(11)
    end)

    t.it("rejects an unconfirmed fence claim without caching the document", function()
        local h = harness(nil, nil, true)
        h.fam_fail = true
        local doc, err = h.db.load("demo", "role", "rid", 7, nil, { fence = 5, valid = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim failed")
        t.expect(h.store._fence).to.be_nil()
        t.expect(h.timer).to.be_nil()
        h.fam_fail = "exception"
        doc, err = h.db.load("demo", "role", "rid", 7, nil, { fence = 5, valid = true })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence claim failed")
        h.fam_fail = nil
        local successor = assert(h.db.load("demo", "role", "rid", 7, nil, { fence = 6, valid = true }))
        t.expect(successor).to.be_type("table")
        t.expect(h.store._fence).to.equal(6)
    end)

    t.it("creates a missing row that already carries the claiming fence", function()
        local h = harness(nil, false, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, { name = "fresh" }, { fence = 21, valid = true }))
        t.expect(doc.name).to.equal("fresh")
        t.expect(doc._version).to.equal(0)
        t.expect(h.calls).to.equal(2)
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.store.rid).to.equal(7)
        t.expect(h.store._version).to.equal(0)
        t.expect(h.store._fence).to.equal(21)
        t.expect(h.fam[2].update["$setOnInsert"]._fence).to.equal(21)
        -- _fence 不能泄漏进 ORM 文档（schema 里没有这个字段）
        t.expect(rawget(doc, "_fence")).to.be_nil()
    end)

    t.it("does not stamp a fence onto a row created without a lock handle", function()
        local h = harness(nil, false, true)
        local doc = assert(h.db.load("demo", "role", "rid", 7, { name = "fresh" }))
        t.expect(doc.name).to.equal("fresh")
        t.expect(h.calls).to.equal(1)
        t.expect(h.store._fence).to.be_nil()
        t.expect(h.fam[1].fields._fence).to.equal(false)
    end)

    t.it("does not write the key, version or fence back into the caller's default table", function()
        local h = harness(nil, false, true)
        local default = { name = "fresh" }
        assert(h.db.load("demo", "role", "rid", 7, default, { fence = 2, valid = true }))
        t.expect(default.rid).to.be_nil()
        t.expect(default._version).to.be_nil()
        t.expect(default._fence).to.be_nil()
    end)

    t.it("retries the claim when another node creates the row first", function()
        local h = harness(nil, false, true)
        h.after_fam = function()
            if h.calls == 1 then
                h.store = { rid = 7, _version = 0, name = "created-elsewhere" }
            end
        end
        local doc = assert(h.db.load("demo", "role", "rid", 7, nil, { fence = 8, valid = true }))
        t.expect(doc.name).to.equal("created-elsewhere")
        t.expect(h.calls).to.equal(3)
        t.expect(h.duplicates).to.equal(0)
        t.expect(h.store._fence).to.equal(8)
    end)

    t.it("does not cache the document when the lease dies during the claim", function()
        local handle = { fence = 30, valid = true }
        local h = harness(nil, nil, true)
        h.after_fam = function()
            h.after_fam = nil
            handle.valid = false
        end
        local doc, err = h.db.load("demo", "role", "rid", 7, nil, handle)
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("lease expired during fence claim")
        t.expect(h.timer).to.be_nil()
        -- fence 已落库且不回滚：旧持有者本就该被拒，后继者的 fence 一定更大
        t.expect(h.store._fence).to.equal(30)
        local successor = assert(h.db.load("demo", "role", "rid", 7, nil, { fence = 31, valid = true }))
        t.expect(successor).to.be_type("table")
        t.expect(h.store._fence).to.equal(31)
    end)

    t.it("refuses to touch the database once the lease is already gone", function()
        local h = harness(nil, nil, true)
        local doc, err = h.db.load("demo", "role", "rid", 7, nil, { fence = 3, valid = false })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("lease expired")
        t.expect(h.calls).to.equal(0)
        t.expect(h.store._fence).to.be_nil()
    end)

    t.it("retains a detached snapshot when the lease expires during an acknowledged write", function()
        local handle = { fence = 21, valid = true }
        local h = harness(handle)
        h.doc.name = "snapshot"
        h.on_update = function()
            if #h.updates == 1 then
                handle.valid = false
                h.doc.name = "later"
            end
        end
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.updates[1].update["$set"].name).to.equal("snapshot")
        t.expect(h.doc._version).to.equal(0)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(false)
        t.expect(h.cancelled).to.equal(false)
    end)

    t.it("serializes two concurrent writes to one row and preserves intervening changes", function()
        local h = harness()
        h.doc.name = "first"
        local running, done = 0, 0
        local results = {}
        h.on_update = function()
            running = running + 1
            t.expect(running).to.equal(1)
            if #h.updates == 1 then
                h.started = true
                skynet.sleep(10)
            end
            running = running - 1
        end
        skynet.fork(function()
            results[1] = h.db.save("demo", "role", "rid", 7)
            done = done + 1
        end)
        for _ = 1, 50 do
            if h.started then
                break
            end
            skynet.sleep(1)
        end
        t.expect(h.started).to.equal(true)
        h.doc.name = "second"
        skynet.fork(function()
            results[2] = h.db.unload("demo", "role", "rid", 7)
            done = done + 1
        end)
        skynet.sleep(2)
        t.expect(#h.updates).to.equal(1)
        for _ = 1, 50 do
            if done == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(done).to.equal(2)
        t.expect(results[1]).to.equal(true)
        t.expect(results[2]).to.equal(true)
        t.expect(h.updates[1].update["$set"].name).to.equal("first")
        t.expect(h.updates[2].query._version).to.equal(1)
        t.expect(h.updates[2].update["$set"].name).to.equal("second")
        t.expect(h.cancelled).to.equal(true)
    end)

    t.it("preserves changes made while a Mongo operation is in flight", function()
        local h = harness()
        h.doc.name = "snapshot"
        h.on_update = function()
            h.doc.name = "later"
        end
        t.expect(h.db.save("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[1].update["$set"].name).to.equal("snapshot")
        t.expect(h.doc._version).to.equal(1)
        t.expect(orm.is_dirty(h.doc)).to.equal(true)
        h.on_update = nil
        t.expect(h.db.unload("demo", "role", "rid", 7)).to.equal(true)
        t.expect(h.updates[2].query._version).to.equal(1)
        t.expect(h.updates[2].update["$set"].name).to.equal("later")
    end)
end)
