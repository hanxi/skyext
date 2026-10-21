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
    function fake_db.load(dbname, collection, key, id, handle, opts)
        record("load")
        h.load_handle = handle
        h.load_opts = opts
        h.loads = (h.loads or 0) + 1
        if h.missing then
            return nil, "not found"
        end
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
    function fake_db.quarantine(_, _, id, handle)
        record("quarantine")
        return h.cache[id] ~= nil and h.cache[id] == handle
    end
    -- 强制丢弃：调用方已经确认这份改动再也写不回去了
    function fake_db.discard(_, _, id, handle)
        record("force_discard")
        if h.cache[id] ~= handle then
            return false
        end
        h.cache[id] = nil
        h.dirty = false
        return true
    end
    -- 真实实现：成功和 superseded 都会清掉缓存，其余失败保留缓存等下一轮重试
    function fake_db.recover(_, _, _, id, old_handle, new_handle)
        record("recover")
        if h.cache[id] ~= old_handle then
            return false, "cache replaced"
        end
        -- 恢复必须拿着一把有效的新租约，否则写入照样会被 fence 拒绝
        t.expect(new_handle.valid).to.equal(true)
        t.expect(new_handle.fence).to.be_gt(old_handle.fence)
        local result = h.recover_result or "ok"
        if result == "ok" then
            h.cache[id] = nil
            h.dirty = false
            return true
        end
        if result == "superseded" then
            h.cache[id] = nil
            h.dirty = false
            return false, "superseded"
        end
        return false, result
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
    local function find_msg(id)
        for _, msg in ipairs(h.pending) do
            if msg.msg_id == id then
                return msg
            end
        end
        error("unknown message " .. tostring(id))
    end
    function fake_msg.max_attempts()
        return h.max_attempts or 3
    end
    function fake_msg.record_failure(id, err)
        record("attempt:" .. id)
        h.last_error = err
        if h.record_failure_error then
            return nil, h.record_failure_error
        end
        local msg = find_msg(id)
        msg.attempts = (msg.attempts or 0) + 1
        return msg.attempts
    end
    function fake_msg.mark_dead(id, reason)
        record("dead:" .. id)
        if h.mark_dead_error then
            return false, h.mark_dead_error
        end
        local msg = find_msg(id)
        -- 真实实现把 status 从 pending 改走，消息不会再出现在 load_pending 里
        msg.delivered = true
        msg.dead = true
        msg.dead_reason = reason
        return true
    end

    local fake_session = {}
    function fake_session.unbind_kick(key, expected_entity)
        -- 对齐真实 session.unbind_kick 的幂等：会话已解绑（entity.session 被清掉）后不再踢。
        -- 停服/丢租约路径可能对同一实体调两次 _kick_client，第二次必须空手而归。
        if not expected_entity or not expected_entity.session or expected_entity.session.key ~= key then
            return false
        end
        record("kick:" .. tostring(key))
        h.kicked[#h.kicked + 1] = key
        h.kicked_entity = expected_entity
        expected_entity.session = nil
        if h.kick_error then
            error(h.kick_error)
        end
        return true
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
        ["skyext.entity.session"] = fake_session,
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
    h.entitymgr = entitymgr
    local type_config = opts.type_config or { db_name = "demo", db_coll = "role", id_field = "rid" }
    h.mgr = entitymgr.new("role", type_config, h.handler, modules)
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

    t.it("失租时把脏数据接到新租约上落库，然后正常卸载", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        local first_fence = h.handles[1].fence
        h.dirty = true
        h:expire()
        h:run_jobs()
        -- 先把条目从回存轮摘掉：旧租约已经失效，留着只会每轮重试一次注定失败的落库
        t.expect(index_of(h.events, "quarantine")).to.be_type("number")
        t.expect(index_of(h.events, "recover")).to.be_gt(index_of(h.events, "quarantine"))
        -- 接回来用的是重新抢到的租约，fence 必须更大
        t.expect(#h.handles).to.equal(2)
        t.expect(h.handles[2].fence).to.be_gt(first_fence)
        t.expect(index_of(h.events, "unlock")).to.be_type("number")
        -- 实体必须离开内存，而不是永远留在 entities 里砖化
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
    end)

    t.it("失租期间文档已被改过时丢弃脏数据并放掉实体", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.dirty = true
        h.recover_result = "superseded"
        h:expire()
        h:run_jobs()
        -- 写回去就是拿旧状态盖新状态，只能丢；但实体同样不能留在内存里
        t.expect(index_of(h.events, "recover")).to.be_type("number")
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
    end)

    t.it("抢不回锁时保留实体并安排重试，而不是直接丢掉改动", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        h.dirty = true
        h.owner = "other-node"
        h:expire()
        h:run_jobs()
        -- 锁在别人手上，这一轮接不回来：改动必须留着，等退避后再试
        t.expect(index_of(h.events, "recover")).to.be_nil()
        t.expect(index_of(h.events, "force_discard")).to.be_nil()
        t.expect(h.mgr.entities[7]).to.equal(entity)
        t.expect(h.cache[7]).to.equal(entity.handle)
        t.expect(entity.unload_retry).to.exist()
    end)

    t.it("重试到上限仍然抢不回锁就丢弃改动，不无限占着内存", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.dirty = true
        h.owner = "other-node"
        h:expire()
        h:run_jobs()
        -- 退避累计远超租约 TTL 还拿不到锁，说明实体已经被别的节点接管，
        -- 这份内存改动再接回去就是拿旧状态盖新状态
        for _ = 1, 16 do
            local retry = h.timers["entity_unload_retry:7"]
            if not retry or retry.cancelled then
                break
            end
            h.timers["entity_unload_retry:7"] = nil
            retry.fire()
            h:run_jobs()
        end
        t.expect(index_of(h.events, "force_discard")).to.be_type("number")
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.cache[7]).to.be_nil()
    end)

    t.it("恢复时落库失败保留缓存等下一轮，不丢改动", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        h.dirty = true
        h.recover_result = "save failed"
        h:expire()
        h:run_jobs()
        -- 这一轮没写进去，缓存必须原样留着，下一轮还能按旧 handle 找到它
        t.expect(h.mgr.entities[7]).to.equal(entity)
        t.expect(h.cache[7]).to.equal(entity.handle)
        t.expect(index_of(h.events, "force_discard")).to.be_nil()
        t.expect(entity.unload_retry).to.exist()
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
        t.expect(err).to.equal("no handler for command missing")
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
    t.it("disconnects a bound session when an entity is successfully unloaded", function()
        local h = harness({ no_modules = true })
        local _, entity = h.mgr:ensure_loaded(7)
        entity.session = { key = "node-a/42", gate_node = "node-a", fd = 42 }

        t.expect(h.mgr:unload(7)).to.equal(true)
        t.expect(h.mgr.entities[7]).to.be_nil()
        h:run_jobs()
        t.expect(entity.session).to.be_nil()
        t.expect(h.kicked).to.equal({ "node-a/42" })
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

    t.it("disconnects a bound session and still retries when the unload write fails", function()
        local h = harness({ no_modules = true })
        local _, entity = h.mgr:ensure_loaded(7)
        entity.session = { key = "node-a/42", gate_node = "node-a", fd = 42 }
        h.unload_ok = false

        t.expect(h.mgr:unload(7)).to.equal(false)
        h:run_jobs()
        t.expect(entity.session).to.be_nil()
        t.expect(h.kicked).to.equal({ "node-a/42" })
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
        entity.session = { key = "node-a/42", gate_node = "node-a", fd = 42 }
        h.unlock_fail = "retryable"

        t.expect(h.mgr:unload(7)).to.equal(false)
        h:run_jobs()
        t.expect(entity.session).to.be_nil()
        t.expect(h.kicked).to.equal({ "node-a/42" })
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
        entity.session = { key = "node-a/42", gate_node = "node-a", fd = 42 }
        h.unlock_fail = "lease_lost"

        t.expect(h.mgr:unload(7)).to.equal(false)
        -- 解锁没确认之前不能丢掉实体，否则 handle 就没人能再用了
        t.expect(h.mgr.entities[7]).to.equal(entity)
        h:run_jobs()
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.kicked).to.equal({ "node-a/42" })
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

    t.it("初始化途中失租的脏实体会被接回去落库并清出内存", function()
        local h = harness({ no_modules = true })
        h.handler.on_load = function()
            h.dirty = true
            h:expire()
        end
        t.expect(h.mgr:ensure_loaded(7)).to.equal(false)
        h:run_jobs()
        -- 半初始化的实体同样不能砖化：改动接到新租约上落库，实体离开内存
        t.expect(index_of(h.events, "recover")).to.be_type("number")
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(h.cache[7]).to.be_nil()
        h.handler.on_load = nil
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
    end)
end)

t.describe("entitymgr partial initialization", function()
    -- 构造一个可跟踪的数据模块：记录 on_load 是否跑完、on_unload 跑了几次
    local function track(calls, name, behavior)
        behavior = behavior or {}
        return {
            new = function(entity, data)
                return {
                    entity = entity,
                    data = data,
                    on_load = function(self)
                        local rec = calls[name] or {}
                        calls[name] = rec
                        if behavior.fail_load then
                            error(behavior.fail_load)
                        end
                        rec.loaded = true
                        t.expect(self.entity).to.equal(entity)
                    end,
                    on_unload = function()
                        local rec = calls[name] or {}
                        calls[name] = rec
                        rec.unloads = (rec.unloads or 0) + 1
                        if behavior.fail_unload and rec.unloads == 1 then
                            error(behavior.fail_unload)
                        end
                    end,
                }
            end,
        }
    end

    t.it("unloads every module that finished loading when the handler init fails", function()
        local calls = {}
        local handler_unloads = 0
        local h = harness({
            modules = {
                bag = track(calls, "bag"),
                mail = track(calls, "mail"),
            },
        })
        h.handler.on_load = function()
            error("init refused")
        end
        h.handler.on_unload = function()
            handler_unloads = handler_unloads + 1
        end

        local ok, err = h.mgr:ensure_loaded(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.match("init refused")
        -- 两个模块的 on_load 都跑完了，on_unload 就必须都跑到，
        -- 否则模块在 on_load 里申请的定时器/注册项会随实体一起泄漏
        t.expect(calls.bag.loaded).to.equal(true)
        t.expect(calls.mail.loaded).to.equal(true)
        t.expect(calls.bag.unloads).to.equal(1)
        t.expect(calls.mail.unloads).to.equal(1)
        -- handler.on_load 没跑完，对应的 handler.on_unload 不能跑
        t.expect(handler_unloads).to.equal(0)
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
    end)

    t.it("never unloads a module whose on_load did not complete", function()
        local calls = {}
        local h = harness({
            modules = {
                bag = track(calls, "bag"),
                mail = track(calls, "mail", { fail_load = "mail init refused" }),
            },
        })

        t.expect(h.mgr:ensure_loaded(7)).to.equal(false)
        -- 加载失败的模块没有建立任何状态，不能被 on_unload 拆一遍
        t.expect(calls.mail.loaded).to.be_nil()
        t.expect(calls.mail.unloads).to.be_nil()
        -- pairs 顺序不确定：mail 先失败时 bag 的 on_load 根本不会跑（calls.bag 为 nil），
        -- bag 先跑完时它的 on_unload 要补上一次。两种顺序下都不允许出现
        -- "没 load 过却被 unload" 的模块，所以这里断言的是这个不变量本身。
        for _, rec in pairs(calls) do
            if rec.unloads then
                t.expect(rec.loaded).to.equal(true)
            end
        end
        t.expect(h.mgr.entities[7]).to.be_nil()
    end)

    t.it("keeps skipping the handler hook while retrying a failed module unload", function()
        local calls = {}
        local handler_unloads = 0
        local h = harness({
            modules = {
                bag = track(calls, "bag", { fail_unload = "unload refused" }),
            },
        })
        h.handler.on_load = function()
            error("init refused")
        end
        h.handler.on_unload = function()
            handler_unloads = handler_unloads + 1
        end

        t.expect(h.mgr:ensure_loaded(7)).to.equal(false)
        t.expect(calls.bag.unloads).to.equal(1)
        local entity = h.mgr.entities[7]
        t.expect(entity).to.be_type("table")
        -- 初始化失败的标记要跨重试保留，否则重试时会把 handler.on_unload 补跑一遍
        t.expect(entity.init_failed).to.equal(true)
        t.expect(index_of(h.events, "unlock")).to.be_nil()

        local retry = h.timers["entity_unload_retry:7"]
        t.expect(retry).to.be_type("table")
        retry.fire()
        t.expect(calls.bag.unloads).to.equal(2)
        t.expect(handler_unloads).to.equal(0)
        t.expect(h.mgr.entities[7]).to.be_nil()
        t.expect(index_of(h.events, "persist")).to.be_lt(index_of(h.events, "unlock"))
    end)

    t.it("still runs every module hook on a normal unload after a successful init", function()
        local calls = {}
        local handler_unloads = 0
        local h = harness({
            modules = {
                bag = track(calls, "bag"),
                mail = track(calls, "mail"),
            },
        })
        h.handler.on_unload = function()
            handler_unloads = handler_unloads + 1
        end

        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.mgr:unload(7)).to.equal(true)
        t.expect(calls.bag.unloads).to.equal(1)
        t.expect(calls.mail.unloads).to.equal(1)
        t.expect(handler_unloads).to.equal(1)
    end)
end)

t.describe("毒消息隔离", function()
    t.it("handler 持续抛错达到上限后把消息移入死信队列", function()
        local h = harness()
        h.max_attempts = 3
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.handler.handlers.change = function()
            error("always broken")
        end
        for i = 1, 2 do
            local ok = h.mgr:deliver_pending(7)
            t.expect(ok).to.equal(false)
            t.expect(h.pending[1].attempts).to.equal(i)
            t.expect(index_of(h.events, "dead:11")).to.be_nil()
        end
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(h.pending[1].attempts).to.equal(3)
        t.expect(h.pending[1].dead).to.equal(true)
        t.expect(h.pending[1].dead_reason).to.match("always broken")
        t.expect(index_of(h.events, "ack:11")).to.be_nil()
    end)

    t.it("隔离毒消息后后续消息不再被队首挡住", function()
        local h = harness()
        h.max_attempts = 1
        local seen = {}
        h.pending = {
            { msg_id = 11, seq = 1, cmd = "poison", args = {} },
            { msg_id = 12, seq = 2, cmd = "change", args = { "ok" } },
        }
        h.handler.handlers.poison = function()
            error("poison")
        end
        h.handler.handlers.change = function(entity, name)
            seen[#seen + 1] = name
            entity.data.name = name
        end
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(h.pending[1].dead).to.equal(true)
        t.expect(seen).to.equal({ "ok" })
        t.expect(h.pending[2].delivered).to.equal(true)
        t.expect(index_of(h.events, "dead:11")).to.be_lt(index_of(h.events, "ack:12"))
    end)

    t.it("没有对应 handler 的消息同样会被隔离", function()
        local h = harness()
        h.max_attempts = 2
        h.pending = { { msg_id = 11, cmd = "missing", args = {} } }
        t.expect(h.mgr:deliver_pending(7)).to.equal(false)
        t.expect(h.pending[1].dead).to.be_nil()
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(h.pending[1].dead).to.equal(true)
        t.expect(h.pending[1].dead_reason).to.equal("no handler for command missing")
    end)

    t.it("隔离一条之后立刻补跑一轮投递", function()
        local h = harness()
        h.max_attempts = 1
        h.mgr:ensure_loaded(7)
        -- 加载本身会 fork 一次首轮投递，先清掉再测隔离补跑的那一次
        h.jobs = {}
        h.pending = { { msg_id = 11, cmd = "missing", args = {} } }
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(#h.jobs).to.equal(1)
    end)

    t.it("全部投递成功时不会多跑一轮", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.jobs = {}
        h.handler.handlers.change = function() end
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(#h.jobs).to.equal(0)
    end)

    -- 环境问题重投一次就可能成功，计进毒消息次数等于把数据库抖动变成消息丢失
    t.it("落库失败不计入毒消息次数", function()
        local h = harness()
        h.max_attempts = 1
        h.handler.handlers.change = function(entity)
            entity.data.name = "new"
        end
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.save_ok = false
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("entity persistence failed")
        t.expect(index_of(h.events, "attempt:11")).to.be_nil()
        t.expect(h.pending[1].dead).to.be_nil()
    end)

    t.it("ack 写库失败不计入毒消息次数", function()
        local h = harness()
        h.max_attempts = 1
        h.handler.handlers.change = function() end
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.ack_error = "mongo down"
        t.expect(h.mgr:deliver_pending(7)).to.equal(false)
        t.expect(index_of(h.events, "attempt:11")).to.be_nil()
        t.expect(h.pending[1].dead).to.be_nil()
    end)

    t.it("租约在 handler 执行中失效不计入毒消息次数", function()
        local h = harness()
        h.max_attempts = 1
        h.pending = { { msg_id = 11, cmd = "change", args = {} } }
        h.handler.handlers.change = function()
            h:expire()
        end
        t.expect(h.mgr:deliver_pending(7)).to.equal(false)
        t.expect(index_of(h.events, "attempt:11")).to.be_nil()
        t.expect(h.pending[1].dead).to.be_nil()
    end)

    -- 次数记不上就不知道已经失败了几次，凭未知次数判死可能把正常消息误隔离
    t.it("计数写库失败时不判死，保持消息 pending 等重试", function()
        local h = harness()
        h.max_attempts = 1
        h.pending = { { msg_id = 11, cmd = "missing", args = {} } }
        h.record_failure_error = "mongo down"
        local ok, err = h.mgr:deliver_pending(7)
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("no handler for command missing")
        t.expect(index_of(h.events, "dead:11")).to.be_nil()
        t.expect(h.timers["reliable_retry:7"]).to.be_type("table")
    end)

    t.it("死信写库失败时消息留在队首并安排重试", function()
        local h = harness()
        h.max_attempts = 1
        h.pending = { { msg_id = 11, cmd = "missing", args = {} } }
        h.mark_dead_error = "mongo down"
        t.expect(h.mgr:deliver_pending(7)).to.equal(false)
        t.expect(h.pending[1].delivered).to.be_nil()
        t.expect(h.timers["reliable_retry:7"]).to.be_type("table")
    end)

    t.it("隔离之后重试定时器被取消", function()
        local h = harness()
        h.max_attempts = 2
        h.pending = { { msg_id = 11, cmd = "missing", args = {} } }
        t.expect(h.mgr:deliver_pending(7)).to.equal(false)
        local retry = h.timers["reliable_retry:7"]
        t.expect(retry).to.be_type("table")
        t.expect(h.mgr:deliver_pending(7)).to.equal(true)
        t.expect(retry.cancelled).to.equal(true)
    end)
end)

t.describe("entitymgr addressing", function()
    t.it("never creates a document unless the type opts into auto_create", function()
        local h = harness()
        t.expect(h.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(h.load_opts).to.equal({ create = false })

        local auto = harness({ type_config = { db_name = "demo", db_coll = "g", id_field = "id", auto_create = true } })
        t.expect(auto.mgr:ensure_loaded(7)).to.equal(true)
        t.expect(auto.load_opts).to.equal({ create = true })
    end)

    t.it("releases the lock and reports a missing document as not found", function()
        local h = harness()
        h.missing = true
        t.expect(table.pack(h.mgr:ensure_loaded(7))).to.equal({ false, "not found", n = 2 })
        t.expect(h.events).to.equal({ "lock", "load", "unlock" })
        t.expect(h.mgr:get(7)).to.be_nil()
    end)

    t.it("moves every pending message of a missing entity to the dead letter queue", function()
        local h = harness()
        h.missing = true
        for i = 1, 3 do
            h.pending[i] = { msg_id = i, cmd = "mail", args = {} }
        end
        t.expect(table.pack(h.mgr:deliver_pending(7))).to.equal({ false, "not found", n = 2 })
        for i = 1, 3 do
            t.expect(h.pending[i].dead).to.equal(true)
            t.expect(h.pending[i].dead_reason).to.equal("entity not found")
        end
        -- 没有加载出实体，也就不该挂投递重试
        t.expect(h.timers["reliable_retry:7"]).to.be_nil()
    end)

    t.it("keeps going when another worker already moved a message", function()
        local h = harness()
        h.missing = true
        h.pending[1] = { msg_id = 1, cmd = "mail", args = {} }
        h.pending[2] = { msg_id = 2, cmd = "mail", args = {} }
        h.mark_dead_error = "not_pending"
        h.mgr:deliver_pending(7)
        t.expect(count_of(h.events, "dead:1")).to.equal(1)
        t.expect(count_of(h.events, "dead:2")).to.equal(1)
    end)

    t.it("tells reliable delivery which node holds the lock", function()
        local h = harness()
        h.owner = "node-b"
        t.expect(table.pack(h.mgr:deliver_pending(7))).to.equal({ false, "lock held", "node-b", n = 3 })
        t.expect(h.loads).to.be_nil()
    end)

    t.it("delivers to loaded entities only when asked not to load", function()
        local h = harness()
        t.expect(table.pack(h.mgr:deliver_pending(7, { loaded_only = true }))).to.equal({
            false,
            h.entitymgr.NOT_LOADED,
            n = 3,
        })
        t.expect(h.loads).to.be_nil()
        h.mgr:ensure_loaded(7)
        t.expect(h.mgr:deliver_pending(7, { loaded_only = true })).to.equal(true)
    end)
end)

t.describe("entitymgr shutdown", function()
    -- unload_all 用 skynet.fork 并发卸载；harness 里 fork 只是排队，
    -- 所以在真协程里调它，再由测试手动跑队列
    local function unload_all(h)
        local box = {}
        skynet.fork(function()
            box.remaining = h.mgr:unload_all()
        end)
        skynet.sleep(0)
        h:run_jobs()
        for _ = 1, 10 do
            if box.remaining then
                break
            end
            skynet.sleep(1)
        end
        return box.remaining
    end

    t.it("unloads every entity and stops loading new ones", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.mgr:ensure_loaded(8)
        t.expect(unload_all(h)).to.equal(0)
        t.expect(h.mgr:get(7)).to.be_nil()
        t.expect(h.mgr:get(8)).to.be_nil()
        t.expect(count_of(h.events, "persist")).to.equal(2)
        t.expect(count_of(h.events, "unlock")).to.equal(2)
        t.expect(table.pack(h.mgr:ensure_loaded(9))).to.equal({ false, "node shutting down", n = 2 })
        t.expect(h.loads).to.equal(2)
    end)

    t.it("reports entities it could not unload so the caller can retry", function()
        local h = harness()
        h.mgr:ensure_loaded(7)
        h.unload_ok = false
        t.expect(unload_all(h)).to.equal(1)
        h.unload_ok = true
        t.expect(unload_all(h)).to.equal(0)
    end)

    t.it("returns immediately when nothing is loaded", function()
        local h = harness()
        t.expect(h.mgr:unload_all()).to.equal(0)
    end)
end)

t.describe("entitymgr resident entities and timers", function()
    local LABEL = "entity_timer:role:7:tick"

    t.it("never schedules an idle unload for a resident type", function()
        local h = harness({ type_config = { db_name = "demo", db_coll = "rank", id_field = "id", resident = true } })
        h.mgr:ensure_loaded(7)
        t.expect(h.timers["entity_unload:7"]).to.be_nil()
        h.mgr:touch(7)
        t.expect(h.timers["entity_unload:7"]).to.be_nil()
    end)

    t.it("runs a repeating timer inside the entity and re-arms it", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        local runs = {}
        entity:every("tick", 5, function(e)
            runs[#runs + 1] = e
        end)
        local first = h.timers[LABEL]
        first.fire()
        t.expect(runs).to.equal({ entity })
        t.expect(h.timers[LABEL] ~= first).to.equal(true)
        h.timers[LABEL].fire()
        t.expect(#runs).to.equal(2)
    end)

    t.it("keeps a repeating timer going after its callback fails", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        local runs = 0
        entity:every("tick", 5, function()
            runs = runs + 1
            error("boom")
        end)
        h.timers[LABEL].fire()
        h.timers[LABEL].fire()
        t.expect(runs).to.equal(2)
    end)

    t.it("fires a one-shot timer once", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        local runs = 0
        entity:after("tick", 5, function()
            runs = runs + 1
        end)
        local timer = h.timers[LABEL]
        timer.fire()
        t.expect(runs).to.equal(1)
        t.expect(h.timers[LABEL]).to.equal(timer)
        t.expect(entity.timers.tick).to.be_nil()
    end)

    t.it("stops when the callback cancels its own timer", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        entity:every("tick", 5, function(e)
            e:cancel_timer("tick")
        end)
        local timer = h.timers[LABEL]
        timer.fire()
        t.expect(h.timers[LABEL]).to.equal(timer)
    end)

    t.it("cancels every timer when the entity unloads or loses its lease", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        local runs = 0
        entity:every("tick", 5, function()
            runs = runs + 1
        end)
        local timer = h.timers[LABEL]
        h.mgr:unload(7)
        t.expect(timer.cancelled).to.equal(true)
        -- 已经排进定时器队列的那次也不能再跑
        timer.fire()
        t.expect(runs).to.equal(0)

        local _, again = h.mgr:ensure_loaded(7)
        again:every("tick", 5, function()
            runs = runs + 1
        end)
        local second = h.timers[LABEL]
        h:expire()
        t.expect(second.cancelled).to.equal(true)
    end)

    t.it("does not extend the life of the entity", function()
        local h = harness()
        local _, entity = h.mgr:ensure_loaded(7)
        local unload_timer = h.timers["entity_unload:7"]
        entity:every("tick", 5, function() end)
        h.timers[LABEL].fire()
        t.expect(h.timers["entity_unload:7"]).to.equal(unload_timer)
    end)
end)
