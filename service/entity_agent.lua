local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local types = require "skyext.entity.types"
local entitymgr_mod = require "skyext.entity.entitymgr"
local log = require "skyext.log"
local errcode = require "skyext.errcode"

local type_name, agent_index = ...
agent_index = tonumber(agent_index)

local type_config = types.get(type_name)
local handler
local entitymgr
local client_ext
local g_data_modules = {}
local g_watchdog

local CMD = {}

function CMD.entity_call(entity_id, cmd, ...)
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        error(string.format("unknown entity command: %s.%s", type_name, cmd))
    end
    local args = table.pack(...)
    local result = table.pack(entitymgr:with_entity(entity_id, function(entity)
        return handler_func(entity, table.unpack(args, 1, args.n))
    end))
    if not result[1] then
        return errcode.LOCK_FAILED
    end
    return table.unpack(result, 2, result.n)
end

function CMD.entity_send(entity_id, cmd, ...)
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        log.error("unknown entity command", "type", type_name, "cmd", cmd)
        return
    end
    local args = table.pack(...)
    local ok, err = entitymgr:with_entity(entity_id, function(entity)
        handler_func(entity, table.unpack(args, 1, args.n))
    end)
    if not ok then
        log.error("entity_send failed", "type", type_name, "id", entity_id, "err", err)
    end
end

function CMD.__deliver_reliable(entity_id)
    local ok, err = entitymgr:deliver_pending(entity_id)
    if not ok then
        log.error("reliable delivery deferred", "type", type_name, "id", entity_id, "err", err)
    end
    return ok
end

function CMD.unload_entity(entity_id)
    return entitymgr:unload(entity_id)
end

function CMD.bind_client(entity_id, fd)
    local ok, reason, holder_node = entitymgr:try_ensure_loaded(entity_id)
    if not ok then
        if reason ~= "lock held" or not holder_node then
            return errcode.LOCK_FAILED
        end
        local cluster = require "skynet.cluster"
        local holder_agent = types.format_agent_service_name(type_name, types.calc_agent_index(type_name, entity_id))
        local called, released = pcall(cluster.call, holder_node, holder_agent, "unload_entity", entity_id)
        if not called or not released then
            return errcode.IN_OTHER_NODE
        end
    end

    local bound, result = entitymgr:with_entity(entity_id, function(entity)
        if entity.fd then
            client_ext.unbind_kick(entity.fd, entity)
        end
        client_ext.bind(fd, entity)
        if g_watchdog then
            skynet.call(g_watchdog, "lua", "forward", fd, skynet.self())
        end
        if handler.on_bind_client then
            handler.on_bind_client(entity, fd)
        end
        return errcode.OK
    end)
    if not bound then
        log.error("bind_client failed", "type", type_name, "id", entity_id, "err", result)
        return errcode.LOCK_FAILED
    end
    return result
end

function CMD.disconnect(fd)
    if not client_ext then
        return
    end
    local entity = client_ext.get_entity(fd)
    if not entity then
        return
    end
    local ok = entitymgr:with_loaded_entity(entity.id, function(active)
        if active ~= entity or client_ext.get_entity(fd) ~= active then
            return
        end
        client_ext.unbind(fd)
        if handler.on_unbind_client then
            handler.on_unbind_client(active)
        end
    end)
    if not ok and client_ext.get_entity(fd) == entity then
        client_ext.unbind(fd)
    end
end

function CMD.start(conf)
    local modules_path = conf.modules_path
    g_watchdog = conf.watchdog

    for _, name in ipairs(conf.modules) do
        local mod_path = modules_path .. "." .. name

        local ok, mod = pcall(require, mod_path)
        if ok and type(mod) == "table" and mod.new then
            g_data_modules[name] = mod
        end

        if type_config.client_enabled then
            local ok2, request = pcall(require, mod_path .. ".request")
            if ok2 and type(request) == "table" and next(request) then
                local sproto_api = require "skyext.sproto_api"
                sproto_api.register_module(name, client_ext, request)
            end
        end
    end

    handler = require("entity_handler." .. type_name)
    entitymgr = entitymgr_mod.new(type_name, type_config, handler, g_data_modules)

    if client_ext then
        client_ext.init(entitymgr)
    end

    log.info("entity_agent started", "type", type_name, "index", agent_index, "modules", conf.modules)
end

skynet.start(function()
    skynet.register(types.format_agent_service_name(type_name, agent_index))

    if type_config.client_enabled then
        client_ext = require "skyext.entity.client_ext"
    end

    cmd_api.dispatch(CMD)
end)
