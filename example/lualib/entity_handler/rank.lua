-- 排行榜：每个 game 一份的作用域实体（entity_types.rank.scope = "game"，常驻），
-- 按区服目录自动预加载，开服后新 game 的那一份自动出现；持有它的节点停服或崩溃后由新的目标节点接管。
local orm = require "orm"
local time = require "skyext.time"

local M = {}

M.handlers = {}

local MAX_ENTRIES = 100
-- 排名不在每次提交时重排，而是由实体定时器隔一会儿刷新一次
local REFRESH_SEC = 2

-- 排好序的榜单是从 entity.data.entries 推出来的派生数据，不需要落库，但也不能直接
-- 挂成 entity.sorted：entity 根是引擎的命名空间（data、modules、timers、session、
-- handle、invalid、unloading…都在上面），业务往里加字段迟早会和引擎新增的撞名。
-- 这里用一张以实体为键的弱表存放，实体卸载后条目随之回收。
-- 带 modules_path 的实体类型（比如 role）应该走 entity.modules 的模块机制，
-- rank 是单文件 handler，用不上那套。
local g_cache = setmetatable({}, { __mode = "k" })

local function cache_of(entity)
    local c = g_cache[entity]
    if not c then
        c = {}
        g_cache[entity] = c
    end
    return c
end

local function better(a, b)
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.time ~= b.time then
        return a.time < b.time
    end
    return a.rid < b.rid
end

-- 重排并只保留前 MAX_ENTRIES 名，结果缓存起来供 top 直接读
local function refresh(entity)
    local list = {}
    for _, e in pairs(entity.data.entries) do
        list[#list + 1] = orm.totable(e)
    end
    table.sort(list, better)
    for i = #list, MAX_ENTRIES + 1, -1 do
        entity.data.entries[list[i].rid] = nil
        list[i] = nil
    end
    local cache = cache_of(entity)
    cache.sorted = list
    cache.changed = nil
end

-- 只记更高的分。返回是否刷新了成绩
function M.handlers.submit(entity, rid, name, score)
    local entry = entity.data.entries[rid]
    if entry and entry.score >= score then
        return false
    end
    entity.data.entries[rid] = { rid = rid, name = name, score = score, time = time.now_ms() }
    cache_of(entity).changed = true
    return true
end

function M.handlers.top(entity, count)
    local list = cache_of(entity).sorted or {}
    local result = {}
    for i = 1, math.min(count, #list) do
        local e = list[i]
        result[i] = { rid = e.rid, name = e.name, score = e.score }
    end
    return result
end

function M.on_load(entity)
    refresh(entity)
    entity:every("refresh", REFRESH_SEC, function(e)
        if cache_of(e).changed then
            refresh(e)
        end
    end)
end

return M
