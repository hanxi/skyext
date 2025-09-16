local skynet = require "skynet"
local cmd_api = require "cmd_api"
local client = require "client"
local modules = require "modules"
local rolemgr = require "rolemgr"
local global = require "global"
local distributed_lock = require "distributed_lock"
local gamenode_api = require "gamenode_api"
local errcode = require "errcode"
local roleagent_api = require "roleagent_api"
local cluster_discovery = require "cluster_discovery"
local cluster = require "skynet.cluster"
local log = require "log"

local g_roleagent_index = ...
local g_agent_name = roleagent_api.format_agent_name(g_roleagent_index)
local g_agent_service_name = roleagent_api.format_agent_service_name(g_roleagent_index)

log.config {
    name = g_agent_name,
}

local CMD = {}

local function lockkey(rid)
    return "roleagent/" .. rid
end

local function lock_expired_cb(lock_info)
    local value = lock_info.value
    local rid = value.rid
    rolemgr.unload_role(rid)
    log.info("lock expired", "rid", rid, "node", value.gamenode)
end

function CMD.load_bind_role(rid, fd)
    log.info("load_bind_role begin", "rid", rid, "fd", fd)

    -- 检查 rid 是否应该在本节点
    local gamenode = gamenode_api.calc_gamenode(rid)
    if gamenode ~= gamenode_api.self_gamenode() then
        log.warn("role not on this node", "rid", rid, "node", gamenode)
        return ercode.NOT_THIS_GAME, gamenode
    end
    -- 加锁
    local ok, lockvalue = distributed_lock.try_lock(lockkey(rid), { gamenode = gamenode, rid = rid }, lock_expired_cb)
    if not ok then
        if not lockvalue then
            log.warn("failed to lock lockvalue is nil", "rid", rid)
            return errcode.LOCAK_FAILED
        end

        log.info("role locked other node", "rid", rid, "node", lockvalue.gamenode)
        -- 通知对方卸载角色
        local agent_name = roleagent_api.calc_agent_name(rid)
        local ret = cluster.call(lockvalue.gamenode, agent_name, "unload_role", rid)
        if not ret then
            log.error("other node failed to unload role", "rid", rid, "node", lockvalue.gamenode)
            return errcode.IN_OTHER_GAME
        end
        -- 再次尝试获取锁
        ok, lockvalue = distributed_lock.try_lock(lockkey(rid), { gamenode = gamenode, rid = rid }, lock_expired_cb)
        if not ok then
            if not lockvalue then
                log.warn("failed to lock again", "rid", rid)
                return errcode.LOCAK_FAILED
            end

            log.error("role still in other game", "rid", rid, "game", lockvalue.gamenode)
            return errcode.IN_OTHER_GAME
        end
    end
    local role_obj = rolemgr.load_role(rid)
    if role_obj.fd then
        log.info("role already bound", "rid", rid, "fd", role_obj.fd)
        client.unbind_kick(role_obj.fd)
    end
    client.bind(fd, role_obj)
    skynet.call(global.watchdog_service, "lua", "forward", fd, skynet.self())
    return 0
end

function CMD.unload_role(rid)
    rolemgr.unload_role(rid)
    return true
end

function CMD.disconnect(fd)
    log.info("closing client", "fd", fd)
    client.unbind(fd)
end

function CMD.start(conf)
    global.watchdog_service = conf.watchdog
    global.roleagentmgr_service = conf.roleagentmgr
    log.info("roleagent service started", "agent", g_agent_name)
end

skynet.start(function()
    modules.init(client)
    cmd_api.dispatch(CMD)
    cluster_discovery.register({ g_agent_service_name })
    log.info("roleagent service init", "agent", g_agent_service_name)
    skynet.register(g_agent_service_name)
end)
