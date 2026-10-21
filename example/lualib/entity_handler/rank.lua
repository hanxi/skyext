-- 排行榜：每个 game 一份的常驻实体（entity_types.rank.resident = true），
-- 节点启动时按 preload 主动加载，持有它的节点停服或崩溃后由新的目标节点接管。
local orm = require "orm"
local time = require "skyext.time"

local M = {}

M.handlers = {}

local MAX_ENTRIES = 100
-- 排名不在每次提交时重排，而是由实体定时器隔一会儿刷新一次
local REFRESH_SEC = 2

local function better(a, b)
    if a.score ~= b.score then
        return a.score > b.score
    end
    if a.time ~= b.time then
        return a.time < b.time
    end
    return a.rid < b.rid
end

-- 重排并只保留前 MAX_ENTRIES 名，结果缓存在实体上供 top 直接读
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
    entity.sorted = list
    entity.changed = nil
end

-- 只记更高的分。返回是否刷新了成绩
function M.handlers.submit(entity, rid, name, score)
    local entry = entity.data.entries[rid]
    if entry and entry.score >= score then
        return false
    end
    entity.data.entries[rid] = { rid = rid, name = name, score = score, time = time.now_ms() }
    entity.changed = true
    return true
end

function M.handlers.top(entity, count)
    local list = entity.sorted or {}
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
        if e.changed then
            refresh(e)
        end
    end)
end

return M
