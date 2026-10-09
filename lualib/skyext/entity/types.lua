local config = require "skyext.config"
local jchash = require "jchash"

local M = {}

local g_types = nil

local function ensure_loaded()
    if g_types then
        return
    end
    g_types = config.get_table("entity_types") or {}
end

function M.get(type_name)
    ensure_loaded()
    local t = g_types[type_name]
    if not t then
        error("unknown entity type: " .. tostring(type_name))
    end
    return t
end

function M.all()
    ensure_loaded()
    return g_types
end

function M.calc_node(type_name, entity_id)
    local t = M.get(type_name)
    local nodes = t.nodes
    assert(nodes and #nodes > 0, "no nodes for entity type: " .. type_name)
    local idx = jchash.hash(entity_id, #nodes)
    return nodes[idx + 1]
end

function M.calc_agent_index(type_name, entity_id)
    local t = M.get(type_name)
    local agent_count = t.agent_count or 1
    return entity_id % agent_count + 1
end

function M.format_agent_service_name(type_name, index)
    return string.format(".entity_agent:%s:%d", type_name, index)
end

return M
