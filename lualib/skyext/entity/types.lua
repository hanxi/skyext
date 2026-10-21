local config = require "skyext.config"
local placement = require "skyext.entity.placement"

local M = {}

local g_types = nil

local function ensure_loaded()
    if g_types then
        return
    end
    -- 配置有可能还没注入（config.init 之前被 require 到），
    -- 这时候不能把空表缓存下来，否则之后永远都是 unknown entity type
    local types = config.get_table("entity_types")
    if type(types) ~= "table" then
        error("entity_types is not configured")
    end
    g_types = types
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
    return placement.calc_node(type_name, M.get(type_name), entity_id)
end

function M.calc_agent_index(type_name, entity_id)
    local t = M.get(type_name)
    local agent_count = t.agent_count or 1
    return placement.hash(entity_id) % agent_count + 1
end

function M.format_agent_service_name(type_name, index)
    return string.format(".entity_agent:%s:%d", type_name, index)
end

return M
