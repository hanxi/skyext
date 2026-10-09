local skynet = require "skynet"
local dbmgr = require "skyext.dbmgr"
local distributed_lock = require "skyext.distributed_lock"
local timer = require "skyext.timer"
local log = require "skyext.log"
local config = require "skyext.config"

local M = {}
M.__index = M

function M.new(type_name, type_config, handler, data_modules)
    local self = setmetatable({
        type_name = type_name,
        type_config = type_config,
        handler = handler,
        data_modules = data_modules or {},
        entities = {},
    }, M)
    return self
end

local function make_lock_key(type_name, entity_id)
    return string.format("entity/%s/%s", type_name, tostring(entity_id))
end

local function make_lock_value(type_name)
    local node = config.get("cluster_node_name") or "unknown"
    return string.format("%s/%s", node, type_name)
end

function M:_init_modules(entity)
    if not next(self.data_modules) then
        return
    end
    if entity.data.modules == nil then
        entity.data.modules = {}
    end
    entity.modules = {}
    for name, mod in pairs(self.data_modules) do
        if entity.data.modules[name] == nil then
            entity.data.modules[name] = {}
        end
        entity.modules[name] = mod.new(entity, entity.data.modules[name])
    end
end

function M:_call_modules_on_load(entity)
    if not entity.modules then
        return
    end
    for name, mod_inst in pairs(entity.modules) do
        if mod_inst.on_load then
            local ok, err = xpcall(mod_inst.on_load, debug.traceback, mod_inst)
            if not ok then
                log.error("module on_load failed", "type", self.type_name, "id", entity.id,
                    "module", name, "err", err)
            end
        end
    end
end

function M:_call_modules_on_unload(entity)
    if not entity.modules then
        return
    end
    for name, mod_inst in pairs(entity.modules) do
        if mod_inst.on_unload then
            local ok, err = xpcall(mod_inst.on_unload, debug.traceback, mod_inst)
            if not ok then
                log.error("module on_unload failed", "type", self.type_name, "id", entity.id,
                    "module", name, "err", err)
            end
        end
    end
end

function M:_deliver_pending_msgs(entity)
    local reliable_msg = require "skyext.entity.reliable_msg"
    local msgs = reliable_msg.load_pending(self.type_name, entity.id)
    for _, msg in ipairs(msgs) do
        local handler_func = self.handler.handlers and self.handler.handlers[msg.cmd]
        if handler_func then
            local ok, err = xpcall(handler_func, debug.traceback, entity, table.unpack(msg.args or {}))
            if ok then
                reliable_msg.mark_delivered(msg.msg_id)
                log.info("delivered pending reliable msg", "type", self.type_name,
                    "id", entity.id, "cmd", msg.cmd, "msg_id", msg.msg_id)
            else
                log.error("deliver pending reliable msg failed", "type", self.type_name,
                    "id", entity.id, "cmd", msg.cmd, "msg_id", msg.msg_id, "err", err)
            end
        else
            log.warn("no handler for pending reliable msg", "type", self.type_name,
                "id", entity.id, "cmd", msg.cmd, "msg_id", msg.msg_id)
            reliable_msg.mark_delivered(msg.msg_id)
        end
    end
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

function M:ensure_loaded(entity_id)
    local entity = self.entities[entity_id]
    if entity then
        self:touch(entity_id)
        return true, entity
    end

    local tc = self.type_config
    local lock_key = make_lock_key(self.type_name, entity_id)
    local lock_value = make_lock_value(self.type_name)

    local ok, lock_info = distributed_lock.try_lock(lock_key, lock_value)
    if not ok then
        return false, lock_info
    end

    local data = dbmgr.load(tc.db_name, tc.db_coll, tc.id_field, entity_id)
    if not data then
        distributed_lock.unlock(lock_key)
        return false, "db load failed"
    end

    entity = {
        type_name = self.type_name,
        id = entity_id,
        data = data,
        entity_mgr = self,
        unload_timer = nil,
    }
    self.entities[entity_id] = entity

    self:_init_modules(entity)
    self:_call_modules_on_load(entity)

    if self.handler.on_load then
        local ok2, err = xpcall(self.handler.on_load, debug.traceback, entity)
        if not ok2 then
            log.error("handler on_load failed", "type", self.type_name, "id", entity_id, "err", err)
        end
    end

    skynet.fork(function()
        self:_deliver_pending_msgs(entity)
    end)

    self:_start_unload_timer(entity)

    log.info("entity loaded", "type", self.type_name, "id", entity_id)
    return true, entity
end

function M:try_ensure_loaded(entity_id)
    return self:ensure_loaded(entity_id)
end

function M:unload(entity_id)
    local entity = self.entities[entity_id]
    if not entity then
        return
    end

    self:_cancel_unload_timer(entity)

    if self.handler.on_unload then
        local ok, err = xpcall(self.handler.on_unload, debug.traceback, entity)
        if not ok then
            log.error("handler on_unload failed", "type", self.type_name, "id", entity_id, "err", err)
        end
    end

    self:_call_modules_on_unload(entity)

    local tc = self.type_config
    local lock_key = make_lock_key(self.type_name, entity_id)
    distributed_lock.unlock(lock_key)
    dbmgr.unload(tc.db_name, tc.db_coll, tc.id_field, entity_id)

    self.entities[entity_id] = nil
    log.info("entity unloaded", "type", self.type_name, "id", entity_id)
end

function M:touch(entity_id)
    local entity = self.entities[entity_id]
    if entity then
        if entity.fd then
            return
        end
        self:_start_unload_timer(entity)
    end
end

function M:get(entity_id)
    return self.entities[entity_id]
end

return M
