local skynet = require "skynet"
local cluster = require "skynet.cluster"
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

local function module_names(modules)
    local names = {}
    for i, mod in ipairs(modules) do
        names[i] = mod.name
    end
    return names
end

-- 路由跟着集群成员走，实体会换节点，而上一个节点可能还持有着它的分布式锁。
-- 向持有者要一次卸载再重试；只要一次：两边的成员视图短暂分歧时，无限重试会变成互相抢。
local function request_handoff(entity_id, holder_node)
    if not holder_node then
        return false
    end
    local holder_agent = types.format_agent_service_name(type_name, types.calc_agent_index(type_name, entity_id))
    local called, released = pcall(cluster.call, holder_node, holder_agent, "unload_entity", entity_id)
    if not called or not released then
        log.warn("entity handoff failed", "type", type_name, "id", entity_id, "holder", holder_node)
        return false
    end
    log.info("entity handed off", "type", type_name, "id", entity_id, "holder", holder_node)
    return true
end

-- 锁被别的节点占着时先要一次实体再重试；f 在抢锁阶段还没跑过，重试不会重复副作用
local function with_entity(entity_id, f)
    local result = table.pack(entitymgr:with_entity(entity_id, f))
    if result[1] or result[2] ~= "lock held" then
        return table.unpack(result, 1, result.n)
    end
    if not request_handoff(entity_id, result[3]) then
        return table.unpack(result, 1, result.n)
    end
    return entitymgr:with_entity(entity_id, f)
end

function CMD.entity_call(entity_id, cmd, ...)
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        error(string.format("unknown entity command: %s.%s", type_name, cmd))
    end
    local args = table.pack(...)
    local result = table.pack(with_entity(entity_id, function(entity)
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
    local ok, err = with_entity(entity_id, function(entity)
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
        if not request_handoff(entity_id, holder_node) then
            return errcode.IN_OTHER_NODE
        end
    end

    local bound, result = with_entity(entity_id, function(entity)
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

    -- conf.modules 是 entity_agentmgr 扫磁盘得到的，文件一定存在。
    -- 这里不能吞 require 失败：漏掉一个 request 模块，它的所有协议都不会注册，
    -- 客户端发过来的包会被 skynet 当未知协议丢掉，两端都没有日志，只剩超时。
    for _, mod in ipairs(conf.modules) do
        local mod_path = modules_path .. "." .. mod.name

        if mod.init then
            local data_mod = require(mod_path)
            if type(data_mod) == "table" and data_mod.new then
                g_data_modules[mod.name] = data_mod
            end
        end

        if mod.request and type_config.client_enabled then
            local request = require(mod_path .. ".request")
            assert(type(request) == "table", mod_path .. ".request must return a table")
            local sproto_api = require "skyext.sproto_api"
            sproto_api.register_module(mod.name, client_ext, request)
        end
    end

    handler = require("entity_handler." .. type_name)
    entitymgr = entitymgr_mod.new(type_name, type_config, handler, g_data_modules)

    if client_ext then
        client_ext.init(entitymgr)
    end

    log.info("entity_agent started", "type", type_name, "index", agent_index, "modules", module_names(conf.modules))
end

skynet.start(function()
    skynet.register(types.format_agent_service_name(type_name, agent_index))

    if type_config.client_enabled then
        client_ext = require "skyext.entity.client_ext"
    end

    cmd_api.dispatch(CMD)
end)
