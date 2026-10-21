local skynet = require "skynet"
local cluster = require "skynet.cluster"
local config = require "skyext.config"
local types = require "skyext.entity.types"

local M = {}

local g_self_node = nil

local function self_node()
    if not g_self_node then
        g_self_node = config.get("cluster_node_name")
    end
    return g_self_node
end

local function get_target(type_name, entity_id)
    local node = types.calc_node(type_name, entity_id)
    local idx = types.calc_agent_index(type_name, entity_id)
    local service_name = types.format_agent_service_name(type_name, idx)
    return node, service_name
end

-- 返回 true, handler 的返回值...，或 false, reason（实体不可用，handler 没有执行）。
-- handler 抛错、目标节点不可达时照常抛错
function M.call(type_name, entity_id, cmd, ...)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return skynet.call(service_name, "lua", "entity_call", entity_id, cmd, ...)
    else
        return cluster.call(node, service_name, "entity_call", entity_id, cmd, ...)
    end
end

function M.send(type_name, entity_id, cmd, ...)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        skynet.send(service_name, "lua", "entity_send", entity_id, cmd, ...)
    else
        cluster.send(node, service_name, "entity_send", entity_id, cmd, ...)
    end
end

-- 唤醒目标实体去读取自己的 pending 消息。
-- 返回是否成功投出唤醒；失败不代表消息丢了——消息已经落库，
-- 实体下次加载或重试定时器会补上。
function M.poke_reliable(type_name, entity_id)
    local node, service_name = get_target(type_name, entity_id)
    if node == self_node() then
        return (pcall(skynet.send, service_name, "lua", "__deliver_reliable", entity_id))
    end
    return (pcall(cluster.send, node, service_name, "__deliver_reliable", entity_id))
end

function M.reliable_send(type_name, entity_id, cmd, args)
    local reliable_msg = require "skyext.entity.reliable_msg"
    local msg_id = reliable_msg.save(type_name, entity_id, cmd, args)

    if not M.poke_reliable(type_name, entity_id) then
        local log = require "skyext.log"
        log.warn(
            "reliable_send immediate delivery failed, will retry on load",
            "type",
            type_name,
            "id",
            entity_id,
            "cmd",
            cmd,
            "msg_id",
            msg_id
        )
    end
    return msg_id
end

return M
