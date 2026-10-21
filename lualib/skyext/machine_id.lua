-- 机器号槽位：从 etcd 抢一个带租约的编号。
--
-- 手写配置分配机器号在扩容时很容易出事：两个节点抄到同一个号，snowflake 就会发出
-- 重复 ID，而且要等撞库才发现。改成启动时抢一个槽位，租约由 distributed_lock 的
-- 心跳续期，进程没了租约过期，号自动回到池子里。
local skynet = require "skynet"
local distributed_lock = require "skyext.distributed_lock"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

local KEY_PREFIX = "machine_id/"
-- 一轮最多探测多少个槽位：号段有上万个，撞满 64 个基本只能是 etcd 出了问题
local PROBE_LIMIT = 64
-- 抢不到号就退避重试。起步必须短：启动时 etcd 租约还没批下来这种失败毫秒级就能恢复，
-- 固定睡几秒等于让整个进程白等。号段真被占满才需要退到秒级。
local RETRY_DELAY_MIN = 0.1
local RETRY_DELAY_MAX = 5

local slot_mt = {}
slot_mt.__index = slot_mt

--- 新建一个机器号槽位（还没有去抢，要调用 acquire）
-- @param name 号段名称，不同用途的号段互不干扰
-- @param count 号段容量
function M.new(name, count)
    assert(type(name) == "string" and name ~= "", "machine id name required")
    assert(math.type(count) == "integer" and count > 0, "machine id count must be a positive integer")
    return setmetatable({ name = name, count = count, probe = math.min(PROBE_LIMIT, count) }, slot_mt)
end

-- 从节点名散列出的位置开始探测：同一个节点重启后大概率还能拿回原来的号，
-- 不同节点也不会一起从 0 号开始抢
local function probe_start(self)
    local name = config.get("cluster_node_name") or ""
    local hash = 5381
    for i = 1, #name do
        hash = (hash * 33 + string.byte(name, i)) & 0x7fffffff
    end
    return hash % self.count
end

function slot_mt:_on_lost(id)
    if self.released or self.id ~= id then
        -- 过期的是上一轮的句柄，当前这个号不受影响
        return
    end
    log.error("machine id lease lost", "name", self.name, "id", id)
    self.id, self.key, self.handle = nil, nil, nil
    -- 丢过的号不原地捡回来：接手的进程可能已经拿它发过 ID，换个空槽才不会撞上
    skynet.fork(function()
        self:acquire(id)
    end)
end

function slot_mt:_try_claim(exclude)
    local start = probe_start(self)
    for i = 0, self.probe - 1 do
        local id = (start + i) % self.count
        if id ~= exclude then
            local key = string.format("%s%s/%d", KEY_PREFIX, self.name, id)
            local ok, handle = distributed_lock.try_lock(key, config.get("cluster_node_name") or "unknown", function()
                self:_on_lost(id)
            end)
            if ok then
                self.id, self.key, self.handle = id, key, handle
                return true
            end
            if handle ~= "lock held" then
                -- 不是被别人占着，而是 etcd 本身不可用，继续探测只是白费请求
                return false, handle
            end
        end
    end
    return false, "no free slot"
end

--- 抢一个号，抢不到就一直重试；期间 valid() 为 false，调用方必须停下
-- @param exclude 这一轮要跳过的号（刚丢掉的那个）
function slot_mt:acquire(exclude)
    if self.acquiring or self.released then
        return
    end
    self.acquiring = true
    local delay = RETRY_DELAY_MIN
    while not self.id and not self.released do
        local ok, err = self:_try_claim(exclude)
        if ok then
            break
        end
        log.error("machine id claim failed", "name", self.name, "err", err, "retry_after", delay)
        skynet.sleep(delay * 100)
        delay = math.min(delay * 2, RETRY_DELAY_MAX)
    end
    self.acquiring = false
    log.info("machine id acquired", "name", self.name, "id", self.id)
end

--- 停服时主动归还号码：同一个节点马上重启能拿回原来的号，不用等租约过期。
-- 归还后 valid() 恒为 false，也不会再去抢号
function slot_mt:release()
    self.released = true
    local key, handle = self.key, self.handle
    self.id, self.key, self.handle = nil, nil, nil
    if not handle or not distributed_lock.is_valid(handle) then
        return true
    end
    local ok, err = distributed_lock.unlock(key, handle)
    if not ok then
        log.warn("machine id release failed", "name", self.name, "key", key, "err", err)
        return false
    end
    log.info("machine id released", "name", self.name, "key", key)
    return true
end

--- 这个号此刻是否还归我们
function slot_mt:valid()
    -- is_valid 会顺带发现租约超时并触发过期回调
    return self.handle ~= nil and distributed_lock.is_valid(self.handle)
end

return M
