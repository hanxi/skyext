local skynet = require "skynet"
local dbmgr = require "skyext.dbmgr"
local distributed_lock = require "skyext.distributed_lock"
local timer = require "skyext.timer"
local log = require "skyext.log"
local config = require "skyext.config"
local queue = require "skynet.queue"

local M = {}
M.__index = M

-- reliable_msg 会连上 mongo，加载期 require 会把尚未配置好的连接固化下来，
-- 因此推迟到首次投递时再取
local g_reliable_msg
local function reliable_msg()
    if not g_reliable_msg then
        g_reliable_msg = require "skyext.entity.reliable_msg"
    end
    return g_reliable_msg
end

-- 卸载失败后的重试间隔（秒），可按实体类型用 unload_retry_delay 覆盖
local UNLOAD_RETRY_DELAY = 5
-- 退避上限，避免数据库/etcd 长时间故障时持续重试刷日志
local UNLOAD_RETRY_MAX_DELAY = 300

function M.new(type_name, type_config, handler, data_modules)
    local self = setmetatable({
        type_name = type_name,
        type_config = type_config,
        handler = handler,
        data_modules = data_modules or {},
        entities = {},
        gates = {},
    }, M)
    return self
end

local function make_lock_key(type_name, entity_id)
    return string.format("entity/%s/%s", type_name, tostring(entity_id))
end

local function make_lock_value()
    return config.get("cluster_node_name") or "unknown"
end

function M:_init_modules(entity)
    if not next(self.data_modules) then
        return
    end
    if entity.data.modules == nil then
        entity.data.modules = {}
    end
    entity.modules = {}
    -- on_load 已经跑完的模块；初始化中途失败时只有这些模块需要补 on_unload
    entity.loaded_modules = {}
    for name, mod in pairs(self.data_modules) do
        if entity.data.modules[name] == nil then
            entity.data.modules[name] = {}
        end
        entity.modules[name] = mod.new(entity, entity.data.modules[name])
    end
end

function M:_call_modules_on_load(entity)
    if not entity.modules then
        return true
    end
    for name, mod_inst in pairs(entity.modules) do
        if mod_inst.on_load then
            local ok, err = xpcall(mod_inst.on_load, debug.traceback, mod_inst)
            if not ok then
                log.error("module on_load failed", "type", self.type_name, "id", entity.id, "module", name, "err", err)
                return false, err
            end
        end
        -- 记下已经加载完成的模块：初始化在中途失败时，这些模块的 on_unload 仍然要跑
        entity.loaded_modules[name] = true
    end
    return true
end

-- only_loaded: 只卸载 on_load 已经跑完的模块。初始化中途失败时必须这样，
-- 否则 on_load 没跑过的模块会被 on_unload 拆一遍不存在的状态
function M:_call_modules_on_unload(entity, only_loaded)
    if not entity.modules then
        return true
    end
    -- 卸载失败会重试，已经完成的模块不能再跑一次 on_unload
    local done = entity.unloaded_modules
    if not done then
        done = {}
        entity.unloaded_modules = done
    end
    local loaded = entity.loaded_modules
    for name, mod_inst in pairs(entity.modules) do
        local need_unload = mod_inst.on_unload ~= nil and not done[name]
        if need_unload and only_loaded then
            need_unload = loaded ~= nil and loaded[name] == true
        end
        if need_unload then
            local ok, err = xpcall(mod_inst.on_unload, debug.traceback, mod_inst)
            if not ok then
                log.error(
                    "module on_unload failed",
                    "type",
                    self.type_name,
                    "id",
                    entity.id,
                    "module",
                    name,
                    "err",
                    err
                )
                return false, err
            end
            done[name] = true
        end
    end
    return true
end

-- 投递一条消息。返回 ok, reason, message_fault。
-- message_fault 为 true 表示错在消息本身（没有对应 handler、handler 抛错），
-- 重投多少次结果都一样，要计入毒消息次数；为 false 表示环境问题
-- （租约失效、落库失败、ack 写库失败），换个时间重投就能成功，不计数。
function M:_deliver_one(entity, msg)
    local handler_func = self.handler.handlers and self.handler.handlers[msg.cmd]
    if not handler_func then
        return false, string.format("no handler for command %s", tostring(msg.cmd)), true
    end
    local args = table.pack(table.unpack(msg.args or {}))
    args.n = args.n + 1
    args[args.n] = msg.msg_id
    local ok, err = xpcall(handler_func, debug.traceback, entity, table.unpack(args, 1, args.n))
    if not ok then
        return false, err, true
    end
    if entity.invalid or not distributed_lock.is_valid(entity.handle) then
        return false, "lease expired during handler", false
    end
    local tc = self.type_config
    if not dbmgr.save(tc.db_name, tc.db_coll, tc.id_field, entity.id) then
        return false, "entity persistence failed", false
    end
    if entity.invalid or not distributed_lock.is_valid(entity.handle) then
        return false, "lease expired during persistence", false
    end
    local acked, reason = reliable_msg().mark_delivered(msg.msg_id)
    if not acked and reason ~= "already_delivered" then
        return false, reason, false
    end
    return true
end

-- 累计一条消息的投递失败次数，到上限则移入死信队列。
-- 返回 true 表示消息已被隔离，调用方可以跳过它继续处理后面的消息；
-- 返回 false 表示它还留在队列头部，整批投递必须停下来重试。
function M:_quarantine(entity, msg, reason)
    local rmsg = reliable_msg()
    local attempts, record_err = rmsg.record_failure(msg.msg_id, reason)
    if not attempts then
        -- 次数记不上就不能判死：宁可继续重投，也不能凭未知次数把消息误隔离
        log.error(
            "reliable message attempt count failed",
            "type",
            self.type_name,
            "id",
            entity.id,
            "msg_id",
            msg.msg_id,
            "err",
            record_err
        )
        return false
    end
    local max_attempts = rmsg.max_attempts()
    if attempts < max_attempts then
        log.error(
            "reliable message delivery failed",
            "type",
            self.type_name,
            "id",
            entity.id,
            "cmd",
            msg.cmd,
            "msg_id",
            msg.msg_id,
            "attempts",
            attempts,
            "max_attempts",
            max_attempts,
            "err",
            reason
        )
        return false
    end
    if not rmsg.mark_dead(msg.msg_id, reason) then
        return false
    end
    log.error(
        "reliable message moved to dead letter queue",
        "type",
        self.type_name,
        "id",
        entity.id,
        "cmd",
        msg.cmd,
        "msg_id",
        msg.msg_id,
        "attempts",
        attempts,
        "err",
        reason
    )
    return true
end

function M:_deliver_pending_msgs(entity)
    local rmsg = reliable_msg()
    local msgs = rmsg.load_pending(self.type_name, entity.id, { max_count = rmsg.DEFAULT_PAGE_SIZE })
    local quarantined = 0
    for _, msg in ipairs(msgs) do
        if entity.invalid or not distributed_lock.is_valid(entity.handle) then
            return false, "lease expired"
        end
        local ok, reason, message_fault = self:_deliver_one(entity, msg)
        if not ok then
            if not message_fault then
                log.error(
                    "reliable message delivery deferred",
                    "type",
                    self.type_name,
                    "id",
                    entity.id,
                    "msg_id",
                    msg.msg_id,
                    "err",
                    reason
                )
                return false, reason
            end
            -- 毒消息没达到上限时仍然卡在队首：消息之间可能有先后依赖，
            -- 不能为了让队列往前走就跳过一条还可能成功的消息
            if not self:_quarantine(entity, msg, reason) then
                return false, reason
            end
            quarantined = quarantined + 1
        end
    end
    if quarantined > 0 or #msgs == rmsg.DEFAULT_PAGE_SIZE then
        -- 隔离掉毒消息后被它挡住的消息已经可以投递了，立刻再跑一轮
        skynet.fork(function()
            self:deliver_pending(entity.id)
        end)
    end
    return true
end

function M:_start_unload_timer(entity)
    local delay = self.type_config.unload_delay or 600
    if entity.unload_timer then
        entity.unload_timer:cancel()
    end
    entity.unload_timer = timer.timeout("entity_unload:" .. tostring(entity.id), delay, function()
        entity.unload_timer = nil
        self:unload(entity.id)
    end)
end

function M:_cancel_unload_timer(entity)
    if entity.unload_timer then
        entity.unload_timer:cancel()
        entity.unload_timer = nil
    end
end

function M:_cancel_unload_retry(entity)
    if entity.unload_retry then
        entity.unload_retry:cancel()
        entity.unload_retry = nil
    end
end

-- 卸载中途失败时安排重试：实体已经处于半卸载状态，必须由重试把它彻底卸载掉，
-- 否则 unloading 会永久挂住，实体既不服务请求也不释放锁。
function M:_schedule_unload_retry(entity)
    if entity.unload_retry or self.entities[entity.id] ~= entity then
        return
    end
    local base = self.type_config.unload_retry_delay or UNLOAD_RETRY_DELAY
    local attempts = (entity.unload_retries or 0) + 1
    entity.unload_retries = attempts
    local delay = math.min(base * (1 << math.min(attempts - 1, 6)), UNLOAD_RETRY_MAX_DELAY)
    entity.unload_retry = timer.timeout("entity_unload_retry:" .. tostring(entity.id), delay, function()
        entity.unload_retry = nil
        if not self:unload(entity.id) then
            log.warn("entity unload retry failed", "type", self.type_name, "id", entity.id)
        end
    end)
end

-- 实体不再能服务请求时断开客户端，避免客户端继续向半卸载/失效的实体发请求
function M:_kick_client(entity, reason)
    local fd = entity.fd
    if not fd then
        return
    end
    entity.fd = nil
    skynet.fork(function()
        local client_ext = require "skyext.entity.client_ext"
        local ok, err = pcall(client_ext.unbind_kick, fd, entity)
        if not ok then
            log.error(
                "failed to disconnect entity",
                "type",
                self.type_name,
                "id",
                entity.id,
                "reason",
                reason,
                "err",
                err
            )
        end
    end)
end

function M:_forget_entity(entity)
    self:_cancel_unload_timer(entity)
    self:_cancel_delivery_retry(entity)
    self:_cancel_unload_retry(entity)
    if self.entities[entity.id] == entity then
        self.entities[entity.id] = nil
    end
end

function M:_cancel_delivery_retry(entity)
    if entity.delivery_retry then
        entity.delivery_retry:cancel()
        entity.delivery_retry = nil
    end
end

function M:_schedule_delivery_retry(entity)
    if entity.delivery_retry or entity.invalid or entity.unloading or not distributed_lock.is_valid(entity.handle) then
        return
    end
    entity.delivery_retry = timer.timeout("reliable_retry:" .. tostring(entity.id), 5, function()
        entity.delivery_retry = nil
        local ok, err = self:deliver_pending(entity.id)
        if not ok then
            log.warn("reliable delivery retry failed", "id", entity.id, "err", err)
        end
    end)
end

function M:_with_gate(entity_id, f)
    local gate = self.gates[entity_id]
    if not gate then
        gate = { run = queue(), users = 0 }
        self.gates[entity_id] = gate
    end
    gate.users = gate.users + 1
    local result = table.pack(pcall(gate.run, f))
    gate.users = gate.users - 1
    if gate.users == 0 then
        self.gates[entity_id] = nil
    end
    if not result[1] then
        error(result[2], 0)
    end
    return table.unpack(result, 2, result.n)
end

function M:_on_lock_expired(entity_id, handle)
    local entity = self.entities[entity_id]
    if not entity or entity.handle ~= handle or entity.invalid then
        return
    end
    entity.invalid = true
    self:_cancel_unload_timer(entity)
    self:_cancel_delivery_retry(entity)
    self:_cancel_unload_retry(entity)
    self:_kick_client(entity, "lease lost")
    log.error("entity quarantined after lease loss", "type", self.type_name, "id", entity_id)
    skynet.fork(function()
        self:unload(entity_id)
    end)
end

function M:_ensure_loaded(entity_id)
    local entity = self.entities[entity_id]
    if entity then
        if entity.invalid or not distributed_lock.is_valid(entity.handle) then
            self:_on_lock_expired(entity_id, entity.handle)
            return false, "entity lease expired"
        end
        if entity.unloading then
            return false, "entity unloading"
        end
        self:touch(entity_id)
        return true, entity
    end

    local tc = self.type_config
    local lock_key = make_lock_key(self.type_name, entity_id)
    local ok, handle, owner = distributed_lock.try_lock(lock_key, make_lock_value(), function(expired)
        self:_on_lock_expired(entity_id, expired)
    end)
    if not ok then
        return false, handle, owner
    end

    local loaded, data, err = pcall(dbmgr.load, tc.db_name, tc.db_coll, tc.id_field, entity_id, nil, handle)
    if not loaded or not data or not distributed_lock.is_valid(handle) then
        local reason
        if not loaded then
            reason = data
        elseif not data then
            reason = err or "entity load failed"
        else
            -- 数据读上来了但租约没了：dbmgr 里的缓存必须回收，否则定时保存会带着失效租约重试
            reason = "lease expired during load"
            if not dbmgr.discard_clean(tc.db_name, tc.db_coll, entity_id, handle) then
                log.error("loaded entity cache retained after lease loss", "type", self.type_name, "id", entity_id)
            end
        end
        if distributed_lock.is_valid(handle) then
            distributed_lock.unlock(lock_key, handle)
        end
        log.error("entity load failed", "type", self.type_name, "id", entity_id, "err", reason)
        return false, reason
    end

    entity = {
        type_name = self.type_name,
        id = entity_id,
        data = data,
        entity_mgr = self,
        handle = handle,
    }
    self.entities[entity_id] = entity

    local initialized, init_err = xpcall(function()
        self:_init_modules(entity)
        local hooks_ok, hook_err = self:_call_modules_on_load(entity)
        assert(hooks_ok, hook_err)
        if self.handler.on_load then
            self.handler.on_load(entity)
        end
    end, debug.traceback)
    if not initialized or not distributed_lock.is_valid(handle) then
        local reason = init_err or "lease expired during initialization"
        log.error("entity initialization failed", "type", self.type_name, "id", entity_id, "err", reason)
        -- handler.on_load 没有跑完，对应的 handler.on_unload 不能执行；
        -- 但 on_load 已经成功的数据模块必须补跑 on_unload（见 _call_modules_on_unload）。
        -- 其余交给统一的卸载流程：租约还在就落库后解锁，租约没了就只丢弃干净缓存，
        -- 失败则保持 unloading 并重试
        entity.init_failed = true
        if not self:_unload_entity(entity) then
            log.error("entity retained after failed initialization", "type", self.type_name, "id", entity_id)
        end
        return false, reason
    end

    self:_start_unload_timer(entity)
    skynet.fork(function()
        local delivered, deliver_err = self:deliver_pending(entity_id)
        if not delivered then
            log.warn("pending reliable messages retained", "id", entity_id, "err", deliver_err)
        end
    end)
    log.info("entity loaded", "type", self.type_name, "id", entity_id, "fence", handle.fence)
    return true, entity
end

function M:ensure_loaded(entity_id)
    return self:_with_gate(entity_id, function()
        return self:_ensure_loaded(entity_id)
    end)
end

function M:try_ensure_loaded(entity_id)
    return self:ensure_loaded(entity_id)
end

function M:with_entity(entity_id, f)
    return self:_with_gate(entity_id, function()
        local ok, entity = self:_ensure_loaded(entity_id)
        if not ok then
            return false, entity
        end
        local result = table.pack(pcall(f, entity))
        if entity.invalid or not distributed_lock.is_valid(entity.handle) then
            self:_on_lock_expired(entity_id, entity.handle)
            return false, "entity lease expired during handler"
        end
        if not result[1] then
            error(result[2], 0)
        end
        return true, table.unpack(result, 2, result.n)
    end)
end

function M:with_loaded_entity(entity_id, f)
    return self:_with_gate(entity_id, function()
        local entity = self:get(entity_id)
        if not entity then
            return false, "entity not loaded or lease expired"
        end
        local result = table.pack(pcall(f, entity))
        if not distributed_lock.is_valid(entity.handle) then
            self:_on_lock_expired(entity_id, entity.handle)
            return false, "entity lease expired during handler"
        end
        if not result[1] then
            error(result[2], 0)
        end
        return true, table.unpack(result, 2, result.n)
    end)
end

function M:deliver_pending(entity_id)
    local called, ready, delivered, reason = pcall(self.with_entity, self, entity_id, function(entity)
        return self:_deliver_pending_msgs(entity)
    end)
    if not called or not ready or not delivered then
        local entity = self.entities[entity_id]
        if entity then
            self:_schedule_delivery_retry(entity)
        end
        return false, (not called and ready) or (not ready and delivered) or reason
    end
    local entity = self.entities[entity_id]
    if entity then
        self:_cancel_delivery_retry(entity)
    end
    return true
end

-- 卸载中途失败：钩子可能已经拆掉了部分状态，实体必须继续拒绝请求，
-- 同时断开客户端并安排重试，直到卸载真正完成
function M:_abort_unload(entity, reason)
    self:_kick_client(entity, reason)
    self:_schedule_unload_retry(entity)
end

-- 数据已经落库、dbmgr 缓存也已清掉，只剩释放锁。失败时必须保留实体（handle 不能丢），
-- 否则没有人能再去释放这把锁。
function M:_release_lock(entity)
    local entity_id = entity.id
    self:_kick_client(entity, "entity unloaded")
    if not distributed_lock.is_valid(entity.handle) then
        -- 租约已经失效，key 会随租约被 etcd 回收，这里再持有实体没有意义，
        -- 数据此前已在有效租约下落库，直接丢掉内存对象是安全的
        log.error("entity persisted but lease was lost before release", "type", self.type_name, "id", entity_id)
        self:_forget_entity(entity)
        return true
    end
    if not distributed_lock.unlock(make_lock_key(self.type_name, entity_id), entity.handle) then
        log.error("entity persisted but lock release was not confirmed", "type", self.type_name, "id", entity_id)
        self:_schedule_unload_retry(entity)
        return false
    end
    self:_forget_entity(entity)
    log.info("entity unloaded", "type", self.type_name, "id", entity_id)
    return true
end

-- 卸载实体本体，调用者必须已经持有该实体的 gate
function M:_unload_entity(entity)
    local entity_id = entity.id
    local tc = self.type_config
    self:_cancel_unload_timer(entity)
    self:_cancel_delivery_retry(entity)
    self:_cancel_unload_retry(entity)
    entity.unloading = true

    if entity.persisted then
        -- 上一次卸载已经落库，只需要补上释放锁这一步，不能重复跑钩子和落库
        return self:_release_lock(entity)
    end

    if entity.invalid or not distributed_lock.is_valid(entity.handle) then
        entity.invalid = true
        self:_kick_client(entity, "lease lost")
        -- 失去租约后既不能写回，也不能丢弃脏数据，只能保留等待恢复流程
        if not dbmgr.discard_clean(tc.db_name, tc.db_coll, entity_id, entity.handle) then
            log.error("cannot unload quarantined dirty entity", "type", self.type_name, "id", entity_id)
            return false
        end
        self:_forget_entity(entity)
        return true
    end

    if not entity.unload_hooks_run then
        local init_failed = entity.init_failed
        local hooks_ok, hooks_err = xpcall(function()
            if not init_failed and self.handler.on_unload and not entity.handler_unloaded then
                self.handler.on_unload(entity)
                entity.handler_unloaded = true
            end
            local modules_ok, module_err = self:_call_modules_on_unload(entity, init_failed)
            assert(modules_ok, module_err)
        end, debug.traceback)
        if not hooks_ok then
            log.error("entity unload hook failed", "type", self.type_name, "id", entity_id, "err", hooks_err)
            self:_abort_unload(entity, "unload hook failed")
            return false
        end
        entity.unload_hooks_run = true
    end

    if not dbmgr.unload(tc.db_name, tc.db_coll, tc.id_field, entity_id) then
        log.error("entity save failed on unload", "type", self.type_name, "id", entity_id)
        self:_abort_unload(entity, "persistence failed")
        return false
    end
    entity.persisted = true
    return self:_release_lock(entity)
end

function M:unload(entity_id)
    return self:_with_gate(entity_id, function()
        local entity = self.entities[entity_id]
        if not entity then
            return true
        end
        return self:_unload_entity(entity)
    end)
end

function M:touch(entity_id)
    local entity = self.entities[entity_id]
    if
        entity
        and not entity.invalid
        and not entity.unloading
        and distributed_lock.is_valid(entity.handle)
        and not entity.fd
    then
        self:_start_unload_timer(entity)
    end
end

function M:get(entity_id)
    local entity = self.entities[entity_id]
    if entity and not entity.invalid and not entity.unloading and distributed_lock.is_valid(entity.handle) then
        return entity
    end
end

return M
