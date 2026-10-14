-- 回存轮：用一个定时器把一批条目摊到周期内的若干个槽上轮转处理。
--
-- 原来每个缓存文档各挂一个定时器：定时器堆里有多少文档就有多少项，增删都要做
-- 堆操作；更要命的是回调在全局定时器协程里同步写库，一次慢写会把进程里所有其他
-- 定时任务一起卡住。
-- 轮转只占一个定时器，条目进出都是 O(1)；刷槽放进独立协程，写库再慢也只是让这一
-- 轮变长（上一槽没刷完时 tick 直接丢弃，天然形成背压），不会拖累别的定时任务。
local skynet = require "skynet"
local timer = require "skyext.timer"
local log = require "skyext.log"

local M = {}

local TICK_SEC = 1

local wheel_mt = {}
wheel_mt.__index = wheel_mt

--- 新建一个回存轮（第一个条目加入时才真正起定时器）
-- @param name 定时器名称，也用于日志
-- @param period 同一个条目两次处理之间的间隔，单位是秒
-- @param on_entry 处理单个条目的回调，内部可以让出
function M.new(name, period, on_entry)
    assert(type(period) == "number" and period > 0, "wheel period must be a positive number")
    assert(type(on_entry) == "function", "wheel callback must be a function")
    -- 槽数按一秒一格取整，周期不足一秒时退化成单槽并缩短 tick，保证周期本身仍然准确
    local slot_count = math.max(1, math.floor(period / TICK_SEC + 0.5))
    local self = setmetatable({
        name = name,
        on_entry = on_entry,
        slot_count = slot_count,
        tick = period / slot_count,
        slots = {},
        slot_of = {},
        hand = 0,
        count = 0,
        flushing = false,
    }, wheel_mt)
    for i = 1, slot_count do
        self.slots[i] = {}
    end
    return self
end

function wheel_mt:_flush(slot)
    local entries = self.slots[slot]
    -- 回调会让出，让出期间别的协程可能往这个槽里塞条目，而遍历中新增键在 Lua 里
    -- 是未定义行为，所以先把键快照出来
    local keys, n = {}, 0
    for entry in pairs(entries) do
        n = n + 1
        keys[n] = entry
    end
    for i = 1, n do
        local entry = keys[i]
        -- 让出期间条目可能已经被移除
        if entries[entry] then
            -- 单个条目出错不该连累同槽的其他条目，它们都得等满一轮才有下次机会
            xpcall(self.on_entry, log.xpcall_msgh, entry)
        end
    end
end

function wheel_mt:_tick()
    if self.flushing then
        if not self.behind then
            self.behind = true
            log.warn("save wheel falling behind", "name", self.name, "count", self.count)
        end
        return
    end
    if self.behind then
        self.behind = nil
        log.info("save wheel caught up", "name", self.name, "count", self.count)
    end
    self.flushing = true
    skynet.fork(function()
        self.hand = self.hand % self.slot_count + 1
        -- flushing 一旦卡在 true，整个轮子就再也不转了，所以这里兜一层
        xpcall(self._flush, log.xpcall_msgh, self, self.hand)
        self.flushing = false
    end)
end

function wheel_mt:_ensure_timer()
    if self.timer_obj then
        return
    end
    self.timer_obj = timer.repeat_delayed(self.name, self.tick, function()
        self:_tick()
    end)
end

--- 加入一个条目，之后每隔 period 秒被处理一次
-- entry 同时充当键，不能重复加入
function wheel_mt:add(entry)
    assert(self.slot_of[entry] == nil, "entry already in the wheel")
    -- 随机落槽：批量加载时才不会全挤在同一格上
    local slot = math.random(1, self.slot_count)
    self.slot_of[entry] = slot
    self.slots[slot][entry] = true
    self.count = self.count + 1
    self:_ensure_timer()
end

--- 移除一个条目，返回它是否真的在轮上
function wheel_mt:remove(entry)
    local slot = self.slot_of[entry]
    if not slot then
        return false
    end
    self.slot_of[entry] = nil
    self.slots[slot][entry] = nil
    self.count = self.count - 1
    return true
end

return M
