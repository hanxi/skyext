local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/entitymgr.lua")

local function harness(opts)
    opts = opts or {}
    local h = {
        events = {},
        handles = {},
        jobs = {},
        pending = {},
        timers = {},
        cache = {},
        kicked = {},
        dirty = false,
    }
    local function record(event)
        h.events[#h.events + 1] = event
    end

    local fake_lock = {}
    function fake_lock.try_lock(key, value, expired_cb)
        record("lock")
        h.lock_key = key
        h.lock_value = value
        if h.owner then
            return false, "lock held", h.owner
        end
        local handle = { key = key, valid = true, fence = #h.handles + 1 }
        h.handles[#h.handles + 1] = handle
        h.expired_cb = expired_cb
        return true, handle
    end
    function fake_lock.is_valid(handle)
        return handle and handle.valid or false
    end
    function fake_lock.unlock(key, handle)
        record("unlock")
        t.expect(key).to.equal(handle.key)
        -- 永远不允许用已经失效的 handle 去解锁
        t.expect(handle.valid).to.equal(true)
        if h.unlock_fail == "lease_lost" then
            -- 真实实现：etcd 事务失败会作废 handle 并触发过期回调
            handle.valid = false
            h.expired_cb(handle)
            return false, "lock no longer owned"
        elseif h.unlock_fail then
            -- 可重试的失败：handle 仍然有效
            return false, "unlock not confirmed"
        end
        handle.valid = false
        return true
    end

    local fake_db = {}
    function fake_db.load(dbname, collection, key, id, default, handle)
        record("load")
        h.load_handle = handle
        h.loads = (h.loads or 0) + 1
        h.cache[id] = handle
        if h.on_load then
            h.on_load()
        end
        return { rid = id, name = "before" }
    end
    function fake_db.save()
        record("save")
        if h.on_save then
            h.on_save()
        end
        return h.save_ok ~= false
    end
    function fake_db.unload(_, _, _, id)
        record("persist")
        if h.on_unload then
            h.on_unload()
        end
        if h.unload_ok == false then
            return false
        end
        h.cache[id] = nil
        return true
    end
    function fake_db.discard_clean(_, _, id, handle)
        record("discard")
        -- 真实实现：没有缓存、脏数据、handle 不匹配都不允许丢弃
        if not h.cache[id] or h.dirty or h.cache[id] ~= handle then
            return false
        end
        -- 仅在租约已经失效时才会走到丢弃分支
        t.expect(handle.valid).to.equal(false)
        h.cache[id] = nil
        return true
    end

    local fake_msg = { DEFAULT_PAGE_SIZE = 200 }
    function fake_msg.load_pending(_, _, opts)
        record("pending")
        if h.load_error then
            error(h.load_error)
        end
        local result = {}
        for _, msg in ipairs(h.pending) do
            if not msg.delivered and #result < opts.max_count then
                result[#result + 1] = msg
            end
        end
        return result
    end
    function fake_msg.mark_delivered(id)
        record("ack:" .. id)
        if h.ack_error then
            return false, h.ack_error
        end
        for _, msg in ipairs(h.pending) do
            if msg.msg_id == id then
                msg.delivered = true
                return true
            end
        end
        error("unknown message " .. tostring(id))
    end

    local fake_client = {}
    function fake_client.unbind_kick(fd, expected_entity)
        record("kick:" .. tostring(fd))
        h.kicked[#h.kicked + 1] = fd
        h.kicked_entity = expected_entity
        if h.kick_error then
            error(h.kick_error)
        end
    end

    local fake_timer = {}
    function fake_timer.timeout(name, _, callback)
        local timer = {
            cancelled = false,
            fire = callback,
            cancel = function(self)
                self.cancelled = true
            end,
        }
        h.timers[name] = timer
        return timer
    end
    local noop = function() end
    local fake_skynet = setmetatable({
        fork = function(fn)
            h.jobs[#h.jobs + 1] = fn
        end,
    }, { __index = skynet })
    local imports = {
        skynet = fake_skynet,
        ["skyext.dbmgr"] = fake_db,
        ["skyext.distributed_lock"] = fake_lock,
        ["skyext.timer"] = fake_timer,
        ["skyext.log"] = { info = noop, warn = noop, error = noop },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return "node-a"
            end,
        },
        ["skyext.entity.reliable_msg"] = fake_msg,
        ["skyext.entity.client_ext"] = fake_client,
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    local entitymgr = assert(loadfile(source, "t", env))()
    h.handler = { handlers = {} }
    local modules = opts.modules
        or (opts.no_modules and {})
        or {
            trace = {
                new = function()
                    return {}
                end,
            },
        }
    h.mgr = entitymgr.new("role", { db_name = "demo", db_coll = "role", id_field = "rid" }, h.handler, modules)
    function h:run_jobs()
        while #self.jobs > 0 do
            table.remove(self.jobs, 1)()
        end
    end
    function h:expire()
        local handle = self.handles[#self.handles]
        handle.valid = false
        self.expired_cb(handle)
    end
    return h
end

local function index_of(events, value)
    for i, event in ipairs(events) do
        if event == value then
            return i
        end
    end
end

local function count_of(events, value)
    local count = 0
    for _, event in ipairs(events) do
        if event == value then
            count = count + 1
        end
    end
    return count
end

t.describe("entitymgr lease and delivery", function()
    t.it("loads and unloads entities without data modules", function()
        local h = harness({ no_modules = true })
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.mgr:unload(7)).to.equal(true)
        t.expect(h.mgr:get(7)).to.be_nil()
    end)

    t.it("loads under a fenced handle and reports only a genuine remote holder", function()
        local h = harness()
        h.owner = "node-b"
        local ok, reason, node = h.mgr:try_ensure_loaded(7)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("lock held")
        t.expect(node).to.equal("node-b")
        t.expect(h.loads).to.be_nil()
        h.owner = nil
        local acquired, entity = h.mgr:ensure_loaded(7)
        t.expect(acquired).to.equal(true)
        t.expect(h.lock_key).to.equal("entity/role/7")
        t.expect(h.lock_value).to.equal("node-a")
        t.expect(h.load_handle).to.equal(entity.handle)
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.loads).to.equal(1)
        t.expect(#h.handles).to.equal(1)
    end)

    t.it("serializes handlers with unload and releases the lock only after persistence", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.events = {}
        local entered, finished = false, 0
        local results = {}
        skynet.fork(function()
            results.call = h.mgr:with_entity(7, function(entity)
                entered = true
                h.events[#h.events + 1] = "handler-start"
                skynet.sleep(5)
                entity.data.name = "after"
                h.events[#h.events + 1] = "handler-end"
                return "response"
            end)
            finished = finished + 1
        end)
        for _ = 1, 20 do
            if entered then
                break
            end
            skynet.sleep(1)
        end
        t.expect(entered).to.equal(true)
        skynet.fork(function()
            results.unload = h.mgr:unload(7)
            finished = finished + 1
        end)
        skynet.sleep(1)
        t.expect(index_of(h.events, "persist")).to.be_nil()
        for _ = 1, 30 do
            if finished == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(finished).to.equal(2)
        t.expect(results.call).to.equal(true)
        t.expect(results.unload).to.equal(true)
        t.expect(index_of(h.events, "handler-end")).to.be_lt(index_of(h.events, "persist"))
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
        t.expect(h.mgr:get(7)).to.be_nil()
    end)

    t.it("quarantines a lost lease, never writes or unlocks it, and discards only clean state", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        h:expire()
        t.expect(h.mgr:get(7)).to.be_nil()
        t.expect(h.mgr:with_entity(7, function() end)).to.equal(false)
        h:run_jobs()
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "discard")).to.be_type("number")
        t.expect(index_of(h.events, "persist")).to.be_nil()
        t.expect(index_of(h.events, "unlock")).to.be_nil()
        t.expect(entity.handle.valid).to.equal(false)
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.handles[2].fence).to.be_gt(entity.handle.fence)
    end)

    t.it("retains dirty quarantine when its lease expires", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        h.dirty = true
        h:expire()
        h:run_jobs()
        t.expect(h.mgr.entities[7]).to.equal(entity)
        t.expect(h.mgr:get(7)).to.be_nil()
        t.expect(h.mgr:ensure_loaded(7)).to.equal(false)
        t.expect(index_of(h.events, "unlock")).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_nil()
    end)

    t.it("persists each message before ack, preserving seq and passing msg_id to handlers", function()
        local h = harness()
        local seen = {}
        h.handler.handlers.change = function(entity, name, msg_id)
            seen[#seen + 1] = { name = name, id = msg_id }
            entity.data.name = name
        end
        h.pending = {
            { msg_id = 11, seq = 1, cmd = "change", args = { "first" } },
            { msg_id = 12, seq = 2, cmd = "change", args = { "second" } },
        }
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(seen).to.equal({ { name = "first", id = 11 }, { name = "second", id = 12 } })
        t.expect(index_of(h.events, "save")).to.be_lt(index_of(h.events, "ack:11"))
        t.expect(index_of(h.events, "ack:11")).to.be_lt(index_of(h.events, "ack:12"))
        t.expect(h.pending[1].delivered).to.equal(true)
        t.expect(h.pending[2].delivered).to.equal(true)
    end)

    t.it("retains failed handler and stops before acknowledging later messages", function()
        local h = harness()
        h.pending = {
            { msg_id = 11, cmd = "change", args = {} },
            { msg_id = 12, cmd = "change", args = {} },
        }
        h.handler.handlers.change = function()
            error("handler rejected")
        end
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("handler rejected")
        t.expect(index_of(h.events, "save")).to.be_nil()
        t.expect(index_of(h.events, "ack:11")).to.be_nil()
        t.expect(h.timers["reliable_retry:7"]).to.be_type("table")
        t.expect(h.pending[2].delivered).to.be_nil()
    end)

    t.it("does not ack an unpersisted change; retries after persistence recovers", function()
        local h = harness()
        h.handler.handlers.change = function(entity, name)
            entity.data.name = name
        end
        h.pending = { { msg_id = 11, cmd = "change", args = { "new" } } }
        h.save_ok = false
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("entity persistence failed")
        t.expect(h.pending[1].delivered).to.be_nil()
        t.expect(index_of(h.events, "ack:11")).to.be_nil()
        h.save_ok = true
        h.timers["reliable_retry:7"].fire()
        t.expect(h.pending[1].delivered).to.equal(true)
        t.expect(index_of(h.events, "save")).to.be_lt(index_of(h.events, "ack:11"))
    end)

    t.it("does not acknowledge when a handler loses its lease during execution", function()
        local h = harness()
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.handler.handlers.change = function(entity)
            entity.data.name = "new"
            h:expire()
        end
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("lease expired")
        t.expect(h.pending[1].delivered).to.be_nil()
        t.expect(index_of(h.events, "save")).to.be_nil()
        t.expect(index_of(h.events, "ack:11")).to.be_nil()
        t.expect(h.mgr:get(7)).to.be_nil()
    end)

    t.it("keeps unknown commands pending instead of acknowledging them", function()
        local h = harness()
        h.pending = { { msg_id = 11, cmd = "missing", args = {} } }
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("message handler missing")
        t.expect(h.pending[1].delivered).to.be_nil()
        t.expect(index_of(h.events, "ack:11")).to.be_nil()
    end)

    t.it("does not release a lock when the final persistence fails", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.unload_ok = false
        t.expect(h.mgr:unload(7)).to.equal(false)
        t.expect(h.mgr.entities[7]).to.be_type("table")
        t.expect(h.mgr:get(7)).to.be_nil()
        t.expect(index_of(h.events, "unlock")).to.be_nil()
        h.unload_ok = true
        t.expect(h.mgr:unload(7)).to.equal(true)
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
    end)

    t.it("retries database read exceptions without executing a handler or acknowledging", function()
        local h = harness()
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.handler.handlers.change = function()
            error("should not execute")
        end
        h.load_error = "mongo offline"
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("mongo offline")
        t.expect(index_of(h.events, "ack:11")).to.be_nil()
        t.expect(h.timers["reliable_retry:7"]).to.be_type("table")
    end)

    t.it("ack failure keeps the message pending and schedules a retry", function()
        local h = harness()
        h.handler.handlers.change = function() end
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.ack_error = "mongo down"
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("mongo down")
        t.expect(h.pending[1].delivered).to.be_nil()
        t.expect(h.timers["reliable_retry:7"]).to.be_type("table")
        h.ack_error = nil
        h.timers["reliable_retry:7"].fire()
        t.expect(h.pending[1].delivered).to.equal(true)
    end)
end)

t.describe("entitymgr unload failure recovery", function()
    t.it("disconnects a bound client when an entity is successfully unloaded", function()
        local h = harness({ no_modules = true })
        local _, entity = h.mgr:ensure_loaded(7)
        entity.fd = 42

        t.expect(h.mgr:unload(7)).to.equal(true)
        t.expect(entity.fd).to.be_nil()
        t.expect(h.mgr.entities[7]).to.be_nil()
        h:run_jobs()
        t.expect(h.kicked).to.equal({ 42 })
        t.expect(h.kicked_entity).to.equal(entity)
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
    end)

    t.it("retries a failed unload hook and keeps the entity out of service meanwhile", function()
        local h = harness({ no_modules = true })
        local calls = 0
        h.handler.on_unload = function()
            calls = calls + 1
            if calls == 1 then
                error("hook refused")
            end
        end
        h.mgr:ensure_loaded(7)
        t.expect(h.mgr:unload(7)).to.equal(false)
        t.expect(h.mgr.entities[7]).to.be_type("table")
        t.expect(h.mgr:get(7)).to.be_nil()
        local ready, reason = h.mgr:ensure_loaded(7)
        t.expect(ready).to.equal(false)
        t.expect(reason).to.equal("entity unloading")
        t.expect(index_of(h.events, "persist")).to.be_nil()
        t.expect(index_of(h.events, "unlock")).to.be_nil()

        local retry = h.timers["entity_unload_retry:7"]
        t.expect(retry).to.be_type("table")
        t.expect(retry.cancelled).to.equal(false)
        retry.fire()
        t.expect(calls).to.equal(2)
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
    end)

    t.it("disconnects a bound client and still retries when the unload write fails", function()
        local h = harness({ no_modules = true })
        local _, entity = h.mgr:ensure_loaded(7)
        entity.fd = 42
        h.unload_ok = false

        t.expect(h.mgr:unload(7)).to.equal(false)
        t.expect(entity.fd).to.be_nil()
        h:run_jobs()
        t.expect(h.kicked).to.equal({ 42 })
        t.expect(index_of(h.events, "unlock")).to.be_nil()
        t.expect(h.mgr:get(7)).to.be_nil()

        local retry = h.timers["entity_unload_retry:7"]
        t.expect(retry).to.be_type("table")
        t.expect(retry.cancelled).to.equal(false)
        h.unload_ok = true
        retry.fire()
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
        t.expect(count_of(h.events, "discard")).to.equal(0)
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
    end)

    t.it("keeps the handle and releases the lock on retry when unlock is not confirmed", function()
        local h = harness({ no_modules = true })
        local _, entity = h.mgr:ensure_loaded(7)
        entity.fd = 42
        h.unlock_fail = "retryable"

        t.expect(h.mgr:unload(7)).to.equal(false)
        t.expect(entity.fd).to.be_nil()
        h:run_jobs()
        t.expect(h.kicked).to.equal({ 42 })
        t.expect(h.kicked_entity).to.equal(entity)
        t.expect(h.mgr.entities[7]).to.equal(entity)
        t.expect(entity.handle.valid).to.equal(true)
        t.expect(count_of(h.events, "persist")).to.equal(1)

        local retry = h.timers["entity_unload_retry:7"]
        t.expect(retry).to.be_type("table")
        h.unlock_fail = nil
        retry.fire()
        t.expect(h.mgr.entities[7]).to.be_nil()
        -- 重试只补解锁，不会再落一次库，也不会丢弃任何状态
        t.expect(count_of(h.events, "persist")).to.equal(1)
        t.expect(count_of(h.events, "unlock")).to.equal(2)
        t.expect(count_of(h.events, "discard")).to.equal(0)
    end)

    t.it("drops a persisted entity when the lease dies while releasing the lock", function()
        local h = harness({ no_modules = true })
        local _, entity = h.mgr:ensure_loaded(7)
        entity.fd = 42
        h.unlock_fail = "lease_lost"

        t.expect(h.mgr:unload(7)).to.equal(false)
        -- 解锁没确认之前不能丢掉实体，否则 handle 就没人能再用了
        t.expect(h.mgr.entities[7]).to.equal(entity)
        h:run_jobs()
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.kicked).to.equal({ 42 })
        t.expect(count_of(h.events, "persist")).to.equal(1)
        t.expect(count_of(h.events, "unlock")).to.equal(1)
        -- 缓存已经随落库清掉，重试路径不能再依赖 discard_clean
        t.expect(count_of(h.events, "discard")).to.equal(0)
        t.expect(h.timers["entity_unload_retry:7"].cancelled).to.equal(true)
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
    end)

    t.it("does not re-run unload hooks that already succeeded", function()
        local calls = { handler = 0, module = 0 }
        local h = harness({
            modules = {
                alpha = {
                    new = function()
                        return {
                            on_unload = function()
                                calls.module = calls.module + 1
                                if calls.module == 1 then
                                    error("module refused")
                                end
                            end,
                        }
                    end,
                },
            },
        })
        h.handler.on_unload = function()
            calls.handler = calls.handler + 1
        end
        h.mgr:ensure_loaded(7)

        t.expect(h.mgr:unload(7)).to.equal(false)
        t.expect(calls).to.equal({ handler = 1, module = 1 })
        h.timers["entity_unload_retry:7"].fire()
        t.expect(calls).to.equal({ handler = 1, module = 2 })
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
    end)
end)

t.describe("entitymgr load failure recovery", function()
    t.it("discards the fresh cache and never unlocks when the lease dies during load", function()
        local h = harness({ no_modules = true })
        h.on_load = function()
            h:expire()
        end
        local ok, err = h.mgr:ensure_loaded(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("lease expired during load")
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.cache[7]).to.be_nil()
        t.expect(index_of(h.events, "discard")).to.be_type("number")
        t.expect(index_of(h.events, "persist")).to.be_nil()
        t.expect(index_of(h.events, "unlock")).to.be_nil()
    end)

    t.it("persists and releases after a failed initialization without running unload hooks", function()
        local h = harness({ no_modules = true })
        local unload_hooks = 0
        h.handler.on_unload = function()
            unload_hooks = unload_hooks + 1
        end
        h.handler.on_load = function()
            error("init refused")
        end
        local ok, err = h.mgr:ensure_loaded(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("init refused")
        t.expect(unload_hooks).to.equal(0)
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
        t.expect(index_of(h.events, "discard")).to.be_nil()

        h.handler.on_load = nil
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.handles[2].fence).to.be_gt(h.handles[1].fence)
    end)

    t.it("keeps a failed initialization retryable instead of quarantining it forever", function()
        local h = harness({ no_modules = true })
        h.handler.on_load = function()
            error("init refused")
        end
        h.unload_ok = false
        t.expect(h.mgr:ensure_loaded(7)).to.equal(false)
        local entity = h.mgr.entities[7]
        t.expect(entity).to.be_type("table")
        -- 租约还在，实体不该被标记成失效，否则永远只能报 lease expired
        t.expect(entity.invalid).to.be_nil()
        t.expect(entity.handle.valid).to.equal(true)
        local ready, reason = h.mgr:ensure_loaded(7)
        t.expect(ready).to.equal(false)
        t.expect(reason).to.equal("entity unloading")
        t.expect(index_of(h.events, "unlock")).to.be_nil()

        local retry = h.timers["entity_unload_retry:7"]
        t.expect(retry).to.be_type("table")
        h.unload_ok = true
        h.handler.on_load = nil
        retry.fire()
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.loads).to.equal(2)
    end)

    t.it("only discards clean state when the lease dies during initialization", function()
        local h = harness({ no_modules = true })
        h.handler.on_load = function()
            h:expire()
        end
        local ok, err = h.mgr:ensure_loaded(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("lease expired during initialization")
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_nil()
        t.expect(index_of(h.events, "unlock")).to.be_nil()
        t.expect(index_of(h.events, "discard")).to.be_type("number")
        h:run_jobs()
        t.expect(h.mgr.entities[7]).to.be_nil()
    end)

    t.it("retains a dirty entity whose lease dies during initialization", function()
        local h = harness({ no_modules = true })
        h.handler.on_load = function()
            h.dirty = true
            h:expire()
        end
        t.expect(h.mgr:ensure_loaded(7)).to.equal(false)
        local entity = h.mgr.entities[7]
        t.expect(entity).to.be_type("table")
        t.expect(entity.invalid).to.equal(true)
        t.expect(index_of(h.events, "persist")).to.be_nil()
        t.expect(index_of(h.events, "unlock")).to.be_nil()
        -- 脏数据不能在失去租约后被丢弃，也不能有重试去偷偷扔掉它
        t.expect(h.timers["entity_unload_retry:7"]).to.be_nil()
    end)
end)
