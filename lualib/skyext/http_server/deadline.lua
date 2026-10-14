local setmetatable = setmetatable

-- 连接超时守卫。
--
-- skynet 的 socket.read / socket.write 没有超时参数，唯一能打断阻塞读写的手段
-- 是从外部 shutdown 这个 fd：pending 的读写会正常失败，调用方沿原有错误路径收尾。
--
-- 实现上每条连接只占一个协程、同一时刻只有一个待触发的定时器：守卫协程睡到
-- 当前截止时间，醒来发现截止时间被延后了就接着睡。cancel 会把它立刻唤醒结束，
-- 否则连接关掉之后协程还要挂到原截止时间，高频短连接下会堆积。
--
-- 时间单位沿用 skynet 约定的 1/100 秒：注入的 now/sleep 必须是同一单位。
local M = {}

local guard = {}
guard.__index = guard

local TICKS_PER_SECOND = 100

--- 创建守卫
-- @param fd socket fd
-- @param deps { now, sleep, wakeup, fork, shutdown }，全部注入以便单测
function M.new(fd, deps)
    return setmetatable({
        fd = fd,
        _now = deps.now,
        _sleep = deps.sleep,
        _wakeup = deps.wakeup,
        _fork = deps.fork,
        _shutdown = deps.shutdown,
        deadline = nil,
        reason = nil,
        expired = nil,
        running = false,
    }, guard)
end

local function watch(self)
    while true do
        local deadline = self.deadline
        if not deadline then
            self.running = false
            return
        end
        local wait = deadline - self._now()
        if wait <= 0 then
            -- 记下原因再 shutdown：调用方拿到的只是一个 socket error，
            -- 没有这个字段就分不清"客户端断开"和"我们把它超时掐了"
            self.expired = self.reason
            self.deadline = nil
            self.running = false
            self._shutdown(self.fd)
            return
        end
        self._sleep(wait, self)
    end
end

--- 设定（或延长）截止时间
-- @param seconds 从现在起的秒数；0 表示不设限，等价于 cancel
-- @param reason 超时原因，用于日志与 expired_reason
function guard:set(seconds, reason)
    if seconds <= 0 then
        return self:cancel()
    end
    self.deadline = self._now() + seconds * TICKS_PER_SECOND
    self.reason = reason
    if not self.running then
        self.running = true
        self._fork(watch, self)
    end
end

--- 取消守卫并立刻结束守卫协程
function guard:cancel()
    self.deadline = nil
    self.reason = nil
    self._wakeup(self)
end

--- 已经超时则返回超时原因，否则返回 nil
function guard:expired_reason()
    return self.expired
end

return M
