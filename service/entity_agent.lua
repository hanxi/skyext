local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local types = require "skyext.entity.types"
local entitymgr_mod = require "skyext.entity.entitymgr"
local reliable_msg = require "skyext.entity.reliable_msg"
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
    local ok, entity = entitymgr:ensure_loaded(entity_id)
    if not ok then
        return errcode.LOCAK_FAILED
    end
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        error(string.format("unknown entity command: %s.%s", type_name, cmd))
    end
    return handler_func(entity, ...)
end

function CMD.entity_send(entity_id, cmd, ...)
    local ok, entity = entitymgr:ensure_loaded(entity_id)
    if not ok then
        log.error("entity_send ensure_loaded failed", "type", type_name, "id", entity_id, "err", entity)
        return
    end
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        log.error("unknown entity command", "type", type_name, "cmd", cmd)
        return
    end
    handler_func(entity, ...)
end

function CMD.__deliver_reliable(entity_id, msg_id, cmd, args)
    local ok, entity = entitymgr:ensure_loaded(entity_id)
    if not ok then
        log.error("deliver_reliable ensure_loaded failed", "type", type_name, "id", entity_id)
        return
    end
    local handler_func = handler.handlers and handler.handlers[cmd]
    if handler_func then
        local ok2, err = xpcall(handler_func, debug.traceback, entity, table.unpack(args or {}))
        if ok2 then
            reliable_msg.mark_delivered(msg_id)
        else
            log.error("deliver_reliable handler failed", "type", type_name, "id", entity_id,
                "cmd", cmd, "msg_id", msg_id, "err", err)
        end
    else
        log.warn("deliver_reliable no handler", "type", type_name, "cmd", cmd)
        reliable_msg.mark_delivered(msg_id)
    end
end

function CMD.unload_entity(entity_id)
    entitymgr:unload(entity_id)
end

function CMD.bind_client(entity_id, fd)
    local ok, lock_info = entitymgr:try_ensure_loaded(entity_id)
    if not ok then
        if not lock_info then
            return errcode.LOCAK_FAILED
        end
        local cluster = require "skynet.cluster"
        local holder_node = lock_info
        local holder_agent = types.format_agent_service_name(type_name,
            types.calc_agent_index(type_name, entity_id))
        local ret = pcall(cluster.call, holder_node, holder_agent, "unload_entity", entity_id)
        if not ret then
            return errcode.IN_OTHER_NODE
        end
        ok, lock_info = entitymgr:try_ensure_loaded(entity_id)
        if not ok then
            return errcode.LOCAK_FAILED
        end
    end

    local entity = entitymgr:get(entity_id)

    if entity.fd then
        client_ext.unbind_kick(entity.fd)
    end

    client_ext.bind(fd, entity)

    if g_watchdog then
        skynet.call(g_watchdog, "lua", "forward", fd, skynet.self())
    end

    if handler.on_bind_client then
        handler.on_bind_client(entity, fd)
    end

    return errcode.OK
end

function CMD.disconnect(fd)
    if not client_ext then
        return
    end
    local entity = client_ext.get_entity(fd)
    if entity then
        client_ext.unbind(fd)
        if handler.on_unbind_client then
            handler.on_unbind_client(entity)
        end
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

    log.info("entity_agent started", "type", type_name, "index", agent_index,
        "modules", conf.modules)
end

skynet.start(function()
    skynet.register(types.format_agent_service_name(type_name, agent_index))

    if type_config.client_enabled then
        client_ext = require "skyext.entity.client_ext"
    end

    cmd_api.dispatch(CMD)
end)
