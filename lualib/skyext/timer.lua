-- 秒级定时器
local skynet = require "skynet"
local binaryheap = require "skyext.binaryheap"
local time = require "skyext.time"
local log = require "skyext.log"
local log_level = require "skyext.log.log_level"

local mrandom = math.random
local mmin = math.min
local millisecond = time.now_ms
local xpcall_msgh = log.xpcall_msgh

local DEBUG = log_level.DEBUG

local MAX_IDLE_MS = 5000 -- 最大等待5秒
local OVERLOAD_TIME_MS = 1000 -- 超过1秒的执行时间认为是过载
local MAX_BATCH_EXEC = 64 -- 单轮最多执行的定时器个数，避免积压时饿死其他消息

local M = {}
local g_timers = {}
local g_minheap = nil
local g_task_co = nil
local g_task_running = false
local g_timer_idx = 0
local g_sleeping = false
local g_skip_sleep = false
-- 调度协程代数：shutdown 后重新启动时，旧协程据此退出，避免出现两个调度循环
local g_generation = 0

local function new_timer_id()
    g_timer_idx = g_timer_idx + 1
    return g_timer_idx
end

local function do_wakeup()
    if g_sleeping and g_task_co then
        g_sleeping = false
        skynet.wakeup(g_task_co)
    else
        g_skip_sleep = true
    end
end

---@class TimerObj
local timer_mt = {}
timer_mt.__index = timer_mt

-- 取消定时器
function timer_mt:cancel()
    local id = self._id
    if g_minheap then
        g_minheap:remove(id)
    end
    g_timers[id] = nil
end

-- 时间提前到下一帧执行
function timer_mt:wakeup()
    local id = self._id
    if not g_minheap then
        return
    end
    if g_minheap:valueByPayload(id) then
        g_minheap:update(id, millisecond())
    elseif g_timers[id] then
        -- 如果定时器还存在（已经被弹出堆但仍然有效），重新插入到最小堆中
        g_minheap:insert(millisecond(), id)
    else
        -- 已取消或已执行完毕的一次性定时器，忽略
        return
    end
    if log.is_enabled(DEBUG) then
        log.debug("timer wakeup", "timer_obj", self)
    end

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
    assert(type(func) == "function", "timer callback must be a function")
    assert(type(sec) == "number" and sec >= 0, "timer interval must be a non-negative number")
    local id = new_timer_id()
    local timer_obj = {
        _name = name,
        _id = id,
        _interval = sec * 1000,
        _func = func,
        _first = first * 1000,
        _times = times or 0,
    }
    if log.is_enabled(DEBUG) then
        log.debug("new timer", "timer_obj", timer_obj)
    end
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
        -- 不补帧: 以回调结束的时刻为基准，保证两次执行间隔>=interval 且不重叠
        local next_exec_time = ms_now + timer_obj._interval
        insert_timer_exec_time(timer_obj, next_exec_time)
    else
        -- 一次性任务执行后删除
        g_timers[id] = nil
    end
end

--- 弹出时间节点前触发的定时器并执行
-- 单轮最多执行 MAX_BATCH_EXEC 个，剩余的留到下一轮，避免长时间占用工作线程
local function minheap_pop_exec(generation)
    local executed = 0
    while g_task_running and generation == g_generation and executed < MAX_BATCH_EXEC do
        local id, exec_time = g_minheap:peek()
        if not exec_time or exec_time > millisecond() then
            break
        end
        g_minheap:pop()

        local timer_obj = g_timers[id]
        if timer_obj then
            executed = executed + 1
            local begin_ms = millisecond()
            xpcall(timer_obj._func, xpcall_msgh)
            -- 回调可能很慢（甚至在内部让出），用回调结束的时刻作为下次计时基准
            local end_ms = millisecond()
            local cost = end_ms - begin_ms
            if cost >= OVERLOAD_TIME_MS then
                log.warn("timer callback too slow", "name", timer_obj._name, "id", id, "cost_ms", cost)
            end
            update_timer(id, end_ms)
        end
    end
end

local function do_sleep(duration, generation)
    if g_skip_sleep then
        g_skip_sleep = false
        return
    end
    g_sleeping = true
    skynet.sleep(duration)
    if generation == g_generation then
        -- 已经被 shutdown 并重启时，不要覆盖新调度协程的状态
        g_sleeping = false
    end
end

--- 启动定时器
local function ensure_init()
    if g_task_running then
        return
    end

    g_task_running = true
    g_generation = g_generation + 1
    g_minheap = binaryheap.minUnique()
    g_skip_sleep = false
    g_sleeping = false
    local generation = g_generation
    g_task_co = skynet.fork(function()
        local overload_duration = 0
        while g_task_running and generation == g_generation do
            minheap_pop_exec(generation)
            if not (g_task_running and generation == g_generation) then
                break
            end

            local ms_now = millisecond()
            local _, next_exec_time = g_minheap:peek()
            local duration = next_exec_time and (next_exec_time - ms_now) or MAX_IDLE_MS

            if duration > 0 then
                overload_duration = 0
                do_sleep(mmin(duration, MAX_IDLE_MS) // 10, generation)
            else
                -- 仍有已到期任务：累计滞后时间，并且必须让出，避免独占工作线程
                overload_duration = overload_duration - duration
                if overload_duration > OVERLOAD_TIME_MS then
                    log.error("timer overload duration exceed threshold", "overload_duration", overload_duration)
                    overload_duration = 0
                end
                do_sleep(0, generation)
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
    assert(type(sec) == "number" and sec > 0, "timer interval must be a positive number")
    -- 间隔不足 1 秒或者不是整数秒时，math.random(1, sec) 会抛错，这里退化为按比例取随机
    local first = sec >= 1 and mrandom(1, sec // 1) or mrandom() * sec
    local timer_obj = new_timer_obj(name, sec, func, first, times)
    insert_timer(timer_obj)
    return timer_obj
end

--- 当前存活的定时器数量
function M.active_count()
    local count = 0
    for _ in pairs(g_timers) do
        count = count + 1
    end
    return count
end

--- 关闭定时器
function M.shutdown()
    if not g_task_running then
        return
    end
    g_task_running = false
    -- 让旧的调度协程在下一次检查时退出
    g_generation = g_generation + 1
    -- g_minheap 不置空，这样仍在执行中的回调里调用 cancel/wakeup 不会出错
    for id in pairs(g_timers) do
        g_minheap:remove(id)
        g_timers[id] = nil
    end
    do_wakeup()
    g_skip_sleep = false
    g_task_co = nil
end

return M
