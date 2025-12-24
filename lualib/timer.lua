-- 秒级定时器
local skynet = require "skynet"
local binaryheap = require "binaryheap"
local time = require "time"
local log = require "log"

local mrandom = math.random
local millisecond = time.now_ms
local xpcall_msgh = log.xpcall_msgh

local MAX_IDLE_MS = 5000 -- 最大等待5秒
local OVERLOAD_TIME_MS = 1000 -- 超过1秒的执行时间认为是过载

local M = {}
local g_timers = {}
local g_minheap = nil
local g_task_co = nil
local g_task_running = false
local g_timer_idx = 0
local g_sleeping = false
local g_skip_sleep = false

local function new_timer_id()
    g_timer_idx = g_timer_idx + 1
    return g_timer_idx
end

local function do_wakeup()
    if g_sleeping then
        skynet.wakeup(g_task_co)
        g_sleeping = false
    else
        g_skip_sleep = true
    end
end

---@class TimerObj
local timer_mt = {}
timer_mt.__index = timer_mt

-- 取消定时器
function timer_mt:cancel()
    g_minheap:remove(self._id)
    g_timers[self._id] = nil
end

-- 时间提前到下一帧执行
function timer_mt:wakeup()
    if g_minheap:valueByPayload(self._id) then
        g_minheap:update(self._id, millisecond())
    else
        if g_timers[self.id] then
            -- 如果定时器还存在，则重新插入到最小堆中
            g_minheap:insert(millisecond(), self._id)
        end
    end
    log.debug("timer wakeup", "timer_obj", self)

    do_wakeup()
end

function timer_mt:__tostring()
    return ("<timer object (name:%s,id:%d) at %p>"):format(self._name, self._id, self)
end

--- 创建定时器对象
-- @param name 定时器名称
-- @param sec 执行间隔，单位是秒
-- @param func 定时器回调函数
-- @param first: 首次执行时间，单位是秒(0立即执行)
-- @param times 执行次数，如果不提供，则始终周期性执行
local function new_timer_obj(name, sec, func, first, times)
    local id = new_timer_id()
    local timer_obj = {
        _name = name,
        _id = id,
        _interval = sec * 1000,
        _func = func,
        _first = first * 1000,
        _times = times or 0,
    }
    log.info("new timer", "timer_obj", timer_obj)
    return setmetatable(timer_obj, timer_mt)
end

local function insert_timer_exec_time(timer_obj, next_exec_time)
    local id = timer_obj._id
    g_timers[id] = timer_obj
    local old_ms = g_minheap:valueByPayload(id)
    if old_ms then
        -- 如果定时器已经存在，更新其执行时间，使用最小的时间，可能 wakeup 时已经插入了
        if old_ms > next_exec_time then
            g_minheap:update(id, next_exec_time)
        end
    else
        g_minheap:insert(next_exec_time, id)
    end
end

--- 插入定时器
local function insert_timer(timer_obj)
    local next_exec_time = timer_obj._first + millisecond()
    insert_timer_exec_time(timer_obj, next_exec_time)
    do_wakeup()
end

local function update_timer(id, ms_now)
    local timer_obj = g_timers[id]
    if not timer_obj then
        -- 需要更新的定时器可能已经被取消
        return
    end

    local times = timer_obj._times
    if times and times ~= 1 then
        -- 周期性任务继续插入
        if times > 0 then
            timer_obj._times = times - 1
        end
        -- 不补帧: 每次执行间隔>=interval
        local next_exec_time = ms_now + timer_obj._interval
        insert_timer_exec_time(timer_obj, next_exec_time)
    else
        -- 一次性任务执行后删除
        g_timers[timer_obj._id] = nil
    end
end

--- 执行定时器
local function exec_timers(timer_ids, ms_now)
    for _, id in pairs(timer_ids) do
        local timer_obj = g_timers[id]
        if timer_obj then
            xpcall(timer_obj._func, xpcall_msgh)
            update_timer(id, ms_now)
        end

        if not g_task_running then
            break
        end
    end
end

--- 弹出时间节点前触发的定时器并执行
local function minheap_pop_exec()
    local timer_ids = {}
    local ms_now = millisecond()
    while true do
        local id, exec_time = g_minheap:peek()
        if not exec_time or exec_time > ms_now then
            break
        end
        timer_ids[#timer_ids + 1] = id
        g_minheap:pop()
    end
    exec_timers(timer_ids, ms_now)
end

local function do_sleep(duration)
    if g_skip_sleep then
        g_skip_sleep = false
    else
        g_sleeping = true
        skynet.sleep(duration)
        g_sleeping = false
    end
end

--- 启动定时器
local function ensure_init()
    if g_task_running then
        return
    end

    g_task_running = true
    g_minheap = binaryheap.minUnique()
    g_task_co = skynet.fork(function()
        local overload_duration = 0
        local duration
        local ms_now
        while g_task_running do
            minheap_pop_exec()
            if g_task_running then
                ms_now = millisecond()
                local _, next_exec_time = g_minheap:peek()
                if not next_exec_time then
                    duration = MAX_IDLE_MS
                else
                    duration = next_exec_time - ms_now
                end

                if duration > 0 then
                    overload_duration = 0
                    duration = math.min(duration, MAX_IDLE_MS)
                    do_sleep(duration // 10)
                else
                    local compensate = -duration
                    overload_duration = overload_duration + compensate
                    if overload_duration > OVERLOAD_TIME_MS then
                        overload_duration = 0
                        log.error("timer overload duration exceed threshold", "overload_duration", overload_duration)
                        do_sleep(0)
                    end
                end
            end
        end
    end)
end

-- 创建一个单次定时器
function M.timeout(name, sec, func)
    ensure_init()
    local timer_obj = new_timer_obj(name, sec, func, sec, 1)
    insert_timer(timer_obj)
    return timer_obj
end

--- 创建一个立即执行的周期性定时器
-- @param name 定时器名称
-- @param sec 执行间隔，单位是秒
-- @param func 定时器回调函数
-- @param times 执行次数，如果不提供，则始终周期性执行
function M.repeat_immediately(name, sec, func, times)
    ensure_init()
    local timer_obj = new_timer_obj(name, sec, func, 0, times)
    insert_timer(timer_obj)
    return timer_obj
end

--- 创建一个延迟执行的周期性定时器
-- @param name 定时器名称
-- @param sec 执行间隔，单位是秒
-- @param func 定时器回调函数
-- @param times 执行次数，如果不提供，则始终周期性执行
function M.repeat_delayed(name, sec, func, times)
    ensure_init()
    local timer_obj = new_timer_obj(name, sec, func, sec, times)
    insert_timer(timer_obj)
    return timer_obj
end

--- 创建一个首次随机的延迟执行的周期性定时器
-- @param name 定时器名称
-- @param sec 执行间隔，单位是秒
-- @param func 定时器回调函数
-- @param times 执行次数，如果不提供，则始终周期性执行
function M.repeat_random_delayed(name, sec, func, times)
    ensure_init()
    local first = mrandom(1, sec)
    local timer_obj = new_timer_obj(name, sec, func, first, times)
    insert_timer(timer_obj)
    return timer_obj
end

--- 关闭定时器
function M.shutdown()
    if g_task_running then
        return
    end
    g_task_running = false
    for id, timer_obj in pairs(g_timers) do
        timer_obj:cancel()
    end
end

return M
