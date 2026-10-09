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

function M.reliable_send(type_name, entity_id, cmd, args)
    local reliable_msg = require "skyext.entity.reliable_msg"
    local msg_id = reliable_msg.save(type_name, entity_id, cmd, args)

    local node, service_name = get_target(type_name, entity_id)
    local ok
    if node == self_node() then
        ok = pcall(skynet.send, service_name, "lua", "__deliver_reliable", entity_id, msg_id, cmd, args)
    else
        ok = pcall(cluster.send, node, service_name, "__deliver_reliable", entity_id, msg_id, cmd, args)
    end
    if not ok then
        local log = require "skyext.log"
        log.warn("reliable_send immediate delivery failed, will retry on load",
            "type", type_name, "id", entity_id, "cmd", cmd, "msg_id", msg_id)
    end
end

return M
