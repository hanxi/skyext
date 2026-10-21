local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

if os.getenv("SKYTEST_INTEGRATION") ~= "1" then
    return
end

local mongo = require "skynet.db.mongo"
local schema = require "game.orm.schema"
local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local lock_source = fs.join(root, "lualib/skyext/distributed_lock.lua")
local db_source = fs.join(root, "lualib/skyext/dbmgr.lua")
local unique = string.format("%d_%d_%d", os.time(), skynet.self(), math.random(1, 1000000000))
local dbname = "skyext_it_" .. unique

local h = {}

local function load_module(source, imports)
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    return assert(loadfile(source, "t", env))()
end

local function new_holder(etcd_config)
    local holder = {}
    local noop = function() end
    local log = { info = noop, warn = noop, error = noop }
    holder.lock = load_module(lock_source, {
        skynet = setmetatable({
            init = function(fn)
                holder.init = fn
            end,
        }, { __index = skynet }),
        ["skyext.config"] = {
            get_table = function()
                return etcd_config
            end,
        },
        ["skyext.timer"] = {
            repeat_delayed = function(_, _, fn)
                holder.heartbeat = fn
            end,
        },
        ["skyext.log"] = log,
    })
    -- init 内部已经同步申请过租约，这里不用再手工跑一轮心跳
    holder.init()

    holder.dbmgr = load_module(db_source, {
        skynet = { init = noop },
        ["skyext.config"] = {
            get_table = function()
                return { [dbname] = { collections = { role = {} } } }
            end,
            get_number = function()
                return 3600
            end,
        },
        ["skyext.log"] = log,
        ["skyext.mongo_conn"] = {
            get_collection = function()
                return {
                    find_and_modify = function(_, opts)
                        return h.collection:findAndModify(opts)
                    end,
                    safe_update = function(_, ...)
                        return h.collection:safe_update(...)
                    end,
                    find_one = function(_, ...)
                        return h.collection:findOne(...)
                    end,
                }
            end,
        },
        ["skyext.distributed_lock"] = holder.lock,
        -- 集成测试只验证落库语义，不需要真的转起回存轮
        ["skyext.save_wheel"] = {
            new = function()
                return { add = noop, remove = noop }
            end,
        },
        ["game.orm.schema"] = schema,
    })
    return holder
end

t.describe("MongoDB and etcd fencing integration", function()
    t.before_all(function()
        local etcd_config = {
            http_host = os.getenv("ETCD_ENDPOINTS") or "http://127.0.0.1:2379",
            key_prefix = "/skyext-integration/" .. unique .. "/",
        }
        h.etcd = assert(require("skyext.etcd").new(etcd_config))
        local mongo_host = os.getenv("MONGO_HOST") or "127.0.0.1"
        local client = mongo.client({ host = mongo_host, port = tonumber(os.getenv("MONGO_PORT")) or 27017 })
        h.db = client[dbname]
        local existing = h.db:runCommand("listCollections", 1)
        t.expect(existing.ok).to.equal(1)
        t.expect(#existing.cursor.firstBatch).to.equal(0)
        h.isolated_db = true
        h.collection = h.db.role
        h.first = new_holder(etcd_config)
        h.second = new_holder(etcd_config)
    end)

    t.after_all(function()
        if h.first_handle and h.first.lock.is_valid(h.first_handle) then
            h.first.lock.unlock(h.lock_key, h.first_handle)
        end
        if h.second_handle and h.second.lock.is_valid(h.second_handle) then
            h.second.lock.unlock(h.lock_key, h.second_handle)
        end
        if h.isolated_db then
            local result = h.db:runCommand("dropDatabase", 1)
            t.expect(result.ok).to.equal(1)
        end
    end)

    t.it("rejects the revoked holder's writes and protects the successor's state", function()
        h.lock_key = "entity/role/7"
        local acquired, first = h.first.lock.try_lock(h.lock_key, "node-1")
        t.expect(acquired).to.equal(true)
        t.expect(first.fence).to.be_gt(0)
        local lease_info = h.etcd:timetolive(first.lease)
        t.expect(lease_info.status).to.equal(200)
        t.expect(tonumber(lease_info.body.TTL)).to.be_gt(0)
        h.first_handle = first
        local other_acquired, reason, owner = h.second.lock.try_lock(h.lock_key, "node-2")
        t.expect(other_acquired).to.equal(false)
        t.expect(reason).to.equal("lock held")
        t.expect(owner).to.equal("node-1")

        local doc = assert(
            h.first.dbmgr.load(dbname, "role", "rid", 7, first, { create = true, default = { name = "initial" } })
        )
        doc.name = "updated"
        t.expect(h.first.dbmgr.save(dbname, "role", "rid", 7)).to.equal(true)
        local stored = h.collection:findOne({ rid = 7 })
        t.expect(stored.name).to.equal("updated")
        t.expect(stored._version).to.equal(1)
        t.expect(stored._fence).to.equal(first.fence)

        local revoked = h.etcd:revoke(first.lease)
        t.expect(revoked.status).to.equal(200)
        h.first.heartbeat()
        t.expect(h.first.lock.is_valid(first)).to.equal(false)
        t.expect(h.first.dbmgr.save(dbname, "role", "rid", 7)).to.equal(false)
        t.expect(h.first.dbmgr.discard_clean(dbname, "role", 7, first)).to.equal(true)
        local acquired_next, next_handle = h.second.lock.try_lock(h.lock_key, "node-2")
        t.expect(acquired_next).to.equal(true)
        t.expect(next_handle.fence).to.be_gt(first.fence)
        h.second_handle = next_handle
        t.expect(h.first.lock.unlock(h.lock_key, first)).to.equal(false)
        t.expect(h.second.lock.is_valid(next_handle)).to.equal(true)
        local next_doc = assert(h.second.dbmgr.load(dbname, "role", "rid", 7, next_handle, { create = true }))
        next_doc.name = "successor"
        t.expect(h.second.dbmgr.save(dbname, "role", "rid", 7)).to.equal(true)

        local ok, _, stale = h.collection:safe_update({ rid = 7, _version = 2, _fence = first.fence }, {
            ["$set"] = { name = "stale", _version = 3 },
        }, false)
        t.expect(ok).to.equal(true)
        t.expect(stale.n).to.equal(0)
        t.expect(h.collection:findOne({ rid = 7 }).name).to.equal("successor")
        t.expect(h.second.dbmgr.unload(dbname, "role", "rid", 7)).to.equal(true)
        t.expect(h.second.lock.unlock(h.lock_key, next_handle)).to.equal(true)
        h.second_handle = nil
    end)

    t.it("hands the successor the row state that its own fence claim observed", function()
        local key = "entity/role/8"
        h.second.heartbeat()
        local acquired, first = h.second.lock.try_lock(key, "node-2")
        t.expect(acquired).to.equal(true)
        local doc = assert(
            h.second.dbmgr.load(dbname, "role", "rid", 8, first, { create = true, default = { name = "initial" } })
        )
        doc.name = "updated"
        t.expect(h.second.dbmgr.save(dbname, "role", "rid", 8)).to.equal(true)

        -- 模拟旧持有者最后一笔“还在飞”的写入：它带着自己的 fence 直接落库，
        -- 缓存与数据库从此不同步（_version 被抬到 2）。
        local ok, _, reply = h.collection:safe_update({ rid = 8, _version = 1, _fence = first.fence }, {
            ["$set"] = { name = "in-flight", _version = 2 },
        }, false)
        t.expect(ok).to.equal(true)
        t.expect(reply.n).to.equal(1)
        t.expect(h.second.dbmgr.discard_clean(dbname, "role", 8, first)).to.equal(true)
        t.expect(h.second.lock.unlock(key, first)).to.equal(true)

        -- 后继者必须拿到“认领那一刻”的最新文档，而不是认领之前读到的快照
        h.first.heartbeat()
        local acquired_next, next_handle = h.first.lock.try_lock(key, "node-1")
        t.expect(acquired_next).to.equal(true)
        t.expect(next_handle.fence).to.be_gt(first.fence)
        local next_doc = assert(h.first.dbmgr.load(dbname, "role", "rid", 8, next_handle, { create = true }))
        t.expect(next_doc.name).to.equal("in-flight")
        t.expect(next_doc._version).to.equal(2)
        t.expect(rawget(next_doc, "_fence")).to.be_nil()
        t.expect(h.collection:findOne({ rid = 8 })._fence).to.equal(next_handle.fence)

        next_doc.name = "successor"
        t.expect(h.first.dbmgr.save(dbname, "role", "rid", 8)).to.equal(true)
        local stored = h.collection:findOne({ rid = 8 })
        t.expect(stored.name).to.equal("successor")
        t.expect(stored._version).to.equal(3)

        -- 旧 fence 的写入一律被拒
        local stale_ok, _, stale = h.collection:safe_update({ rid = 8, _version = 3, _fence = first.fence }, {
            ["$set"] = { name = "stale", _version = 4 },
        }, false)
        t.expect(stale_ok).to.equal(true)
        t.expect(stale.n).to.equal(0)
        t.expect(h.first.dbmgr.unload(dbname, "role", "rid", 8)).to.equal(true)
        t.expect(h.first.lock.unlock(key, next_handle)).to.equal(true)
    end)

    t.it("refuses to claim a row owned by a higher fence and never inserts a duplicate", function()
        local key = "entity/role/9"
        h.second.heartbeat()
        local acquired, handle = h.second.lock.try_lock(key, "node-2")
        t.expect(acquired).to.equal(true)
        local winner = handle.fence + 1000
        local ok = h.collection:safe_update({ rid = 9 }, {
            ["$set"] = { rid = 9, _version = 0, name = "owned", _fence = winner },
        }, true)
        t.expect(ok).to.equal(true)

        local doc, err =
            h.second.dbmgr.load(dbname, "role", "rid", 9, handle, { create = true, default = { name = "loser" } })
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("fence superseded")
        -- 关键：带 fence 约束的查询不匹配时绝不能 upsert 出第二条同 key 文档
        t.expect(h.collection:find({ rid = 9 }):count()).to.equal(1)
        local stored = h.collection:findOne({ rid = 9 })
        t.expect(stored.name).to.equal("owned")
        t.expect(stored._fence).to.equal(winner)
        t.expect(stored._version).to.equal(0)
        t.expect(h.second.lock.unlock(key, handle)).to.equal(true)
    end)

    t.it("creates a missing row with the claiming fence already stamped on it", function()
        local key = "entity/role/10"
        h.second.heartbeat()
        local acquired, handle = h.second.lock.try_lock(key, "node-2")
        t.expect(acquired).to.equal(true)
        t.expect(h.collection:find({ rid = 10 }):count()).to.equal(0)

        local doc = assert(
            h.second.dbmgr.load(dbname, "role", "rid", 10, handle, { create = true, default = { name = "created" } })
        )
        t.expect(doc.name).to.equal("created")
        t.expect(doc._version).to.equal(0)
        t.expect(rawget(doc, "_fence")).to.be_nil()
        t.expect(h.collection:find({ rid = 10 }):count()).to.equal(1)
        local stored = h.collection:findOne({ rid = 10 })
        t.expect(stored.rid).to.equal(10)
        t.expect(stored._version).to.equal(0)
        t.expect(stored._fence).to.equal(handle.fence)
        t.expect(h.second.dbmgr.unload(dbname, "role", "rid", 10)).to.equal(true)
        t.expect(h.second.lock.unlock(key, handle)).to.equal(true)
    end)

    t.it("never inserts a row for an unknown id when create is off", function()
        local key = "entity/role/11"
        h.second.heartbeat()
        local acquired, handle = h.second.lock.try_lock(key, "node-2")
        t.expect(acquired).to.equal(true)

        local doc, err = h.second.dbmgr.load(dbname, "role", "rid", 11, handle)
        t.expect(doc).to.be_nil()
        t.expect(err).to.equal("not found")
        t.expect(h.collection:find({ rid = 11 }):count()).to.equal(0)
        t.expect(h.second.lock.unlock(key, handle)).to.equal(true)
    end)
end)
