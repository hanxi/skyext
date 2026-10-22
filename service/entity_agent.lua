local skynet = require "skynet"
local cluster = require "skynet.cluster"
local cmd_api = require "skyext.cmd_api"
local types = require "skyext.entity.types"
local entitymgr_mod = require "skyext.entity.entitymgr"
local distributed_lock = require "skyext.distributed_lock"
local log = require "skyext.log"
local errcode = require "skyext.errcode"
local config = require "skyext.config"

local type_name, agent_index = ...
agent_index = tonumber(agent_index)

local type_config = types.get(type_name)
local handler
local entitymgr
local session
local g_data_modules = {}

local CMD = {}

local function module_names(modules)
    local names = {}
    for i, mod in ipairs(modules) do
        names[i] = mod.name
    end
    return names
end

local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = config.get("cluster_node_name")
    end
    return g_self_node
end

local function agent_name(entity_id)
    return types.format_agent_service_name(type_name, types.calc_agent_index(type_name, entity_id))
end

-- 客户端重新登录时向持锁节点要回实体：对方卸载（顺带踢掉旧连接）后本地再加载。
-- 只要一次：两边成员视图短暂分歧时，无限重试会变成互相抢
local function request_handoff(entity_id, holder_node)
    if not holder_node then
        return false
    end
    local called, released = pcall(cluster.call, holder_node, agent_name(entity_id), "unload_entity", entity_id)
    if not called or not released then
        log.warn("entity handoff failed", "type", type_name, "id", entity_id, "holder", holder_node)
        return false
    end
    log.info("entity handed off", "type", type_name, "id", entity_id, "holder", holder_node)
    return true
end

-- 本地执行失败是因为锁在另一个节点手里时，返回那个节点。
-- 持锁的是本节点名，说明是上一次进程留下的租约还没过期，转给自己没有意义，只能等它过期
local function remote_holder(result)
    if result[1] or result[2] ~= "lock held" then
        return nil
    end
    local holder = result[3]
    if not holder or holder == self_node() then
        return nil
    end
    return holder
end

-- 粘性路由：路由跟着集群成员走，节点进出后实体的目标节点会变，但已经加载的实体
-- 还留在上一个节点上。这时把请求转给持锁节点执行，而不是让它卸载——卸载会把在线
-- 玩家踢下线，两边成员视图不一致时实体还会被来回搬。实体在旧节点自然卸载后，
-- 下一次加载才落到新节点。
--
-- run_local 返回 true, ... 或 false, reason, owner；forward_cmd 在持锁节点上只处理
-- 已加载的实体，没加载时回 NOT_LOADED，表示什么都没执行，可以回到本地再试一次。
-- 转发本身抛错时不能重试：分不清是没送到，还是对方的 handler 执行到一半出错了。
-- 返回打包的结果，以及转发出错时的错误
local function sticky(entity_id, run_local, forward_cmd, args)
    local result = table.pack(run_local())
    local holder = remote_holder(result)
    if not holder then
        return result
    end
    local called, forwarded = pcall(function()
        return table.pack(
            cluster.call(holder, agent_name(entity_id), forward_cmd, entity_id, table.unpack(args, 1, args.n))
        )
    end)
    if not called then
        log.warn("entity forward failed", "type", type_name, "id", entity_id, "holder", holder, "err", forwarded)
        return nil, forwarded
    end
    if forwarded[1] or forwarded[2] ~= entitymgr_mod.NOT_LOADED then
        return forwarded
    end
    -- 持锁节点已经卸掉了实体，锁多半已经空出来
    return table.pack(run_local())
end

local function handler_of(cmd)
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        error(string.format("unknown entity command: %s.%s", type_name, cmd))
    end
    return handler_func
end

-- 返回 true, handler 的返回值... 或 false, reason（实体不可用，handler 没有执行）。
-- handler 抛错照常抛给调用方
function CMD.entity_call(entity_id, cmd, ...)
    local handler_func = handler_of(cmd)
    local args = table.pack(...)
    local result, forward_err = sticky(entity_id, function()
        return entitymgr:with_entity(entity_id, function(entity)
            return handler_func(entity, table.unpack(args, 1, args.n))
        end)
    end, "entity_call_loaded", table.pack(cmd, ...))
    if not result then
        error(forward_err, 0)
    end
    if not result[1] then
        return false, result[2]
    end
    return table.unpack(result, 1, result.n)
end

-- 持锁节点上执行转发过来的请求：只用已经加载的实体，绝不为它加载
function CMD.entity_call_loaded(entity_id, cmd, ...)
    local handler_func = handler_of(cmd)
    local args = table.pack(...)
    return entitymgr:with_loaded_entity(entity_id, function(entity)
        return handler_func(entity, table.unpack(args, 1, args.n))
    end)
end

function CMD.entity_send(entity_id, cmd, ...)
    local handler_func = handler.handlers[cmd]
    if not handler_func then
        log.error("unknown entity command", "type", type_name, "cmd", cmd)
        return
    end
    local args = table.pack(...)
    local ok, result, forward_err = pcall(sticky, entity_id, function()
        return entitymgr:with_entity(entity_id, function(entity)
            handler_func(entity, table.unpack(args, 1, args.n))
        end)
    end, "entity_call_loaded", table.pack(cmd, ...))
    if not ok then
        log.error("entity_send handler failed", "type", type_name, "id", entity_id, "cmd", cmd, "err", result)
    elseif not result then
        log.error("entity_send forward failed", "type", type_name, "id", entity_id, "cmd", cmd, "err", forward_err)
    elseif not result[1] then
        log.error("entity_send failed", "type", type_name, "id", entity_id, "cmd", cmd, "err", result[2])
    end
end

function CMD.__deliver_reliable(entity_id)
    local result, forward_err = sticky(entity_id, function()
        return entitymgr:deliver_pending(entity_id)
    end, "deliver_reliable_loaded", table.pack())
    if not result or not result[1] then
        -- 消息已经落库，实体下次加载或投递重试时会补上
        log.warn(
            "reliable delivery deferred",
            "type",
            type_name,
            "id",
            entity_id,
            "err",
            result and result[2] or forward_err
        )
        return false
    end
    return true
end

function CMD.deliver_reliable_loaded(entity_id)
    return entitymgr:deliver_pending(entity_id, { loaded_only = true })
end

-- 主动加载一个实体（常驻实体的预加载用）。返回 true，或 false, reason
function CMD.activate(entity_id)
    local ok, reason = entitymgr:ensure_loaded(entity_id)
    return ok == true, ok ~= true and reason or nil
end

function CMD.unload_entity(entity_id)
    return entitymgr:unload(entity_id)
end

-- 停服：不再加载新实体，卸载全部已加载的实体。返回还没卸掉的数量，调用方可以再调一次。
-- 卸干净之后本服务不再加锁。锁键真正从 etcd 消失是在 node_shutdown 撤销节点租约时，
-- 这里不撤——租约是节点级的，本节点别的服务还挂在上面。
function CMD.shutdown()
    local remaining = entitymgr:unload_all()
    if remaining == 0 then
        distributed_lock.shutdown()
    end
    return remaining
end

-- 把 gate 上的一个会话绑到实体上（玩家登录）。由登录服务经 router.bind_session 调用。
-- 实体还被别的节点持有着时向它要一次（重新登录的语义：对方卸载并踢掉旧连接）。
-- 返回错误码
function CMD.bind_session(entity_id, gate_node, fd)
    local ok, reason, holder_node = entitymgr:try_ensure_loaded(entity_id)
    if not ok then
        if reason == "not found" then
            return errcode.ENTITY_NOT_FOUND
        end
        if reason ~= "lock held" or not holder_node or holder_node == self_node() then
            return errcode.LOCK_FAILED
        end
        if not request_handoff(entity_id, holder_node) then
            return errcode.IN_OTHER_NODE
        end
    end

    local key = session.key(gate_node, fd)
    local bound, result = entitymgr:with_entity(entity_id, function(entity)
        local old = entity.session
        if old and old.key ~= key then
            session.unbind_kick(old.key, entity)
        end
        if not session.bind(gate_node, fd, entity, types.format_agent_service_name(type_name, agent_index)) then
            -- 排队期间客户端已经断开
            return errcode.SESSION_CLOSED
        end
        if handler.on_bind_client then
            handler.on_bind_client(entity, key)
        end
        return errcode.OK
    end)
    if not bound then
        log.error("bind_session failed", "type", type_name, "id", entity_id, "err", result)
        return errcode.LOCK_FAILED
    end
    return result
end

-- gate 转发来的上行包
function CMD.client_msg(gate_node, fd, data)
    if not session then
        return
    end
    require("skyext.sproto_api").dispatch_message(session.key(gate_node, fd), data)
end

-- gate 上的连接断开了
function CMD.session_closed(gate_node, fd)
    if not session then
        return
    end
    local key = session.key(gate_node, fd)
    local entity = session.get_entity(key)
    if not entity then
        return
    end
    local ok = entitymgr:with_loaded_entity(entity.id, function(active)
        if active ~= entity or session.get_entity(key) ~= active then
            return
        end
        session.unbind(key)
        if handler.on_unbind_client then
            handler.on_unbind_client(active)
        end
    end)
    if not ok and session.get_entity(key) == entity then
        session.unbind(key)
    end
end

function CMD.start(conf)
    local modules_path = conf.modules_path

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
            sproto_api.register_module(mod.name, session, request)
        end
    end

    handler = require("entity_handler." .. type_name)
    entitymgr = entitymgr_mod.new(type_name, type_config, handler, g_data_modules)

    if session then
        session.init(entitymgr)
    end

    log.info("entity_agent started", "type", type_name, "index", agent_index, "modules", module_names(conf.modules))
end

skynet.start(function()
    skynet.register(types.format_agent_service_name(type_name, agent_index))

    if type_config.client_enabled then
        session = require "skyext.entity.session"
    end

    cmd_api.dispatch(CMD)
end)
