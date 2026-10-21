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

local FNV_OFFSET = 0xcbf29ce484222325
local FNV_PRIME = 0x100000001b3

-- 由字符串键确定性地算出实体 ID，给按名字寻址的实体用（比如每个 game 一份的排行榜）：
-- 任何节点拿同一个键都算出同一个 ID，不用查表。结果是正整数
function M.key_id(key)
    assert(type(key) == "string" and key ~= "", "entity key must be a non-empty string")
    local h = FNV_OFFSET
    for i = 1, #key do
        h = (h ~ string.byte(key, i)) * FNV_PRIME
    end
    h = h & 0x7fffffffffffffff
    if h == 0 then
        h = 1
    end
    return h
end

-- 类型配置里 preload 列出的实体 ID：整数原样使用，字符串经 key_id 换算
function M.preload_ids(type_name)
    local ids = {}
    for _, key in ipairs(M.get(type_name).preload or {}) do
        ids[#ids + 1] = math.type(key) == "integer" and key or M.key_id(key)
    end
    return ids
end

function M.format_agent_service_name(type_name, index)
    return string.format(".entity_agent:%s:%d", type_name, index)
end

return M
