local skynet = require "skynet"
local snowflake = require "snowflake"

local M = {}

-- 缓存配置
local CACHE_CAPACITY = 1000 -- 缓存容量
local REFILL_THRESHOLD = 0.2 -- 补充阈值（20%）
local REFILL_SIZE = CACHE_CAPACITY -- 每次补充数量

-- ID缓存(使用哈希表)
local id_cache = {}
local cache_size = 0

-- 补充状态
local is_refilling = false

-- 获取缓存中的ID数量
local function get_cache_size()
    return cache_size
end

-- 检查是否需要补充缓存
local function should_refill()
    return get_cache_size() <= (CACHE_CAPACITY * REFILL_THRESHOLD)
end

-- 补充缓存
local function refill_cache()
    -- 避免重复补充
    if is_refilling then
        return
    end

    is_refilling = true

    local function do_refill()
        -- 批量获取新ID
        local ok, new_ids = pcall(M.raw_newids, REFILL_SIZE)
        if not ok then
            skynet.error("refill_cache failed:", new_ids)
            is_refilling = false
            return
        end

        -- 添加到缓存中
        for _, id in ipairs(new_ids) do
            id_cache[id] = true
            cache_size = cache_size + 1
        end

        skynet.error(string.format("Cache refilled, current size: %d", cache_size))
        is_refilling = false
    end

    -- 异步执行补充，避免阻塞
    skynet.fork(do_refill)
end

-- 从缓存中获取一个ID
local function get_cached_id()
    -- 获取任意一个ID
    for id in pairs(id_cache) do
        id_cache[id] = nil
        cache_size = cache_size - 1

        -- 检查是否需要补充缓存
        if should_refill() then
            refill_cache()
        end

        return id
    end

    -- 缓存为空，直接从原始接口获取
    return M.raw_newid()
end

-- 从缓存中获取多个ID
local function get_cached_ids(count)
    local result = {}
    local found = 0

    -- 先从现有缓存中获取
    for id in pairs(id_cache) do
        table.insert(result, id)
        id_cache[id] = nil
        cache_size = cache_size - 1
        found = found + 1
        if found >= count then
            break
        end
    end

    local remaining = count - found

    -- 如果还需要更多ID
    if remaining > 0 then
        -- 检查是否需要补充缓存
        if should_refill() then
            refill_cache()
        end

        -- 直接从原始接口获取剩余的ID
        local new_ids = M.raw_newids(remaining)
        for _, id in ipairs(new_ids) do
            table.insert(result, id)
        end
    end

    -- 检查是否需要补充缓存
    if should_refill() then
        refill_cache()
    end

    return result
end

-- 原始接口
function M.raw_newid()
    return snowflake.newid()
end

function M.raw_newids(count)
    return snowflake.newids(count)
end

-- 公开接口
function M.newid()
    return get_cached_id()
end

function M.newids(count)
    return get_cached_ids(count)
end

-- 获取缓存状态（用于监控）
function M.get_cache_status()
    return {
        size = cache_size,
        capacity = CACHE_CAPACITY,
        is_refilling = is_refilling,
        should_refill = should_refill(),
    }
end

-- 初始化缓存
skynet.init(function()
    refill_cache()
end)

return M
