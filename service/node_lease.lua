-- 节点级 etcd 租约：整个进程只有这一个租约，实体锁和服务发现都挂在它上面。
--
-- 为什么要收成一个：锁和服务发现各自持一个租约时，两者的失效域是分开的。
-- 锁租约没了而发现租约还在，本节点仍留在 etcd 的服务列表里，别的节点继续按 HRW
-- 把实体路由过来，可每次加锁都拿到"租约不可用"——对外存活、对内全拒，而且不会
-- 自动摘除。更糟的是 distributed_lock 是库不是服务，每个 require 它的服务
-- （每个实体类型的每个 entity_agent）都会各申请一个租约，节点上的租约数随 agent
-- 数量线性增长，续租请求也跟着翻倍。收成一个之后，"租约没了"是一个事件，
-- 实体隔离和服务发现摘除是它的两面，不会只发生一边。
--
-- 续租的容错边界：
--   * 传输层异常、5xx、超时都只是"这一拍没续上"，不动已有租约，下一拍再试。
--     etcd 一次 GC 抖动或 leader 切换就把全节点实体隔离、把在线玩家全踢，代价
--     远大于多等一拍。transport 层已经会在单次请求内换端点重试。
--   * 真正的失效判据只有两个：etcd 明确回答租约已不存在（TTL <= 0），
--     或者距上一次"确认还活着"超过了宽限期（LEASE_TTL - GRACE）。
--   * deadline 只在续租确认成功时才往后推，任何失败路径都不会延长它。
--     这条不变式保证了"宽限期内容忍"不会把一个已经死掉的租约当成还活着。
local skynet = require "skynet"
local etcd = require "skyext.etcd"
local timer = require "skyext.timer"
local cmd_api = require "skyext.cmd_api"
local event_channel_api = require "skyext.event_channel_api"
local config = require "skyext.config"
local log = require "skyext.log"

local LEASE_TTL = 30 -- 秒
local HEARTBEAT_INTERVAL = LEASE_TTL // 3
-- 留给"最后一次续租的请求本身还在路上"的余量：确认时刻 + (TTL - GRACE) 之后
-- 就不再认为租约可用，比 etcd 真正过期早 GRACE 秒。
local GRACE = 2

local g_etcd_client
local g_leaseid
-- 绝对的 skynet.now() 刻度。skynet.now() 读的是进程全局的 TI->current，
-- 所有服务看到的是同一个值，所以这个刻度可以直接发给别的服务去比较，不存在时钟偏移。
local g_deadline
-- 每批新租约 +1。消费者据此分辨"还是原来那个租约"和"换了一个新的"。
local g_epoch = 0
local g_heartbeat
local g_closed = false

local function publish_alive()
    event_channel_api.publish("lease_alive", g_leaseid, g_epoch, g_deadline)
end

local function lose_lease(reason)
    local leaseid, epoch = g_leaseid, g_epoch
    g_leaseid, g_deadline = nil, nil
    log.error("node lease lost", "leaseid", leaseid, "epoch", epoch, "reason", reason)
    event_channel_api.publish("lease_lost", epoch, reason)
end

-- 顺带发现超时：被问到的时候宽限期已经走完，就地判失效
local function lease_valid()
    if not g_leaseid or not g_deadline then
        return false
    end
    if skynet.now() >= g_deadline then
        lose_lease("keepalive grace period elapsed")
        return false
    end
    return true
end

local function grant_lease()
    local started = skynet.now()
    local ret, err = g_etcd_client:grant(LEASE_TTL)
    if not ret or ret.status ~= 200 or not ret.body or not ret.body.ID then
        log.error("node lease grant failed", "err", err, "ret", ret)
        return false
    end
    g_leaseid = ret.body.ID
    g_epoch = g_epoch + 1
    g_deadline = started + (LEASE_TTL - GRACE) * 100
    log.info("node lease granted", "leaseid", g_leaseid, "epoch", g_epoch, "ttl", LEASE_TTL)
    publish_alive()
    return true
end

-- @return ok, fatal
--   ok=true   续租确认成功，deadline 已经往后推
--   fatal=true etcd 明确说租约没了，不用等宽限期
local function keepalive()
    local started = skynet.now()
    local leaseid = g_leaseid
    local ret, err = g_etcd_client:keepalive(leaseid)

    if not ret or ret.status ~= 200 then
        -- 连不上、超时、5xx：这一拍没续上，但租约在 etcd 那边很可能还好好的
        log.warn("node lease keepalive failed", "leaseid", leaseid, "err", err, "ret", ret)
        return false, false
    end

    local result = ret.body and ret.body.result
    if not result then
        -- 200 但没有 result：形态不对，当成这一拍没续上，交给宽限期兜底
        log.warn("node lease keepalive response malformed", "leaseid", leaseid, "ret", ret)
        return false, false
    end

    -- 有 result 就是 etcd 给出的权威回答。租约已经不存在时 TTL 是 0，而 JSON
    -- 网关会把 protobuf 的零值整个字段省掉——所以"读不到 TTL"等同于"TTL 为 0"，
    -- 不能当成形态异常去容忍，否则真丢了租约也要白等一个宽限期才隔离。
    local ttl = tonumber(result.TTL)
    if not ttl or ttl <= 0 then
        return false, true
    end
    if leaseid ~= g_leaseid then
        -- 请求往返期间租约已经被换掉了，这次的结果作废
        return false, false
    end

    g_deadline = started + (math.min(ttl, LEASE_TTL) - GRACE) * 100
    return true, false
end

local function heartbeat()
    if g_leaseid then
        local ok, fatal = keepalive()
        if ok then
            publish_alive()
        elseif fatal then
            lose_lease("etcd reports the lease no longer exists")
        elseif skynet.now() >= g_deadline then
            lose_lease("keepalive grace period elapsed")
        else
            -- 宽限期还没走完：保留租约，下一拍再试。
            -- HEARTBEAT_INTERVAL=10s、宽限期 28s，容得下连续两次失败。
            log.warn("node lease keepalive transient failure, tolerating", "deadline", g_deadline)
        end
    end
    if not g_leaseid and not g_closed then
        grant_lease()
    end
end

local CMD = {}

-- 当前租约快照。消费者在自己的 skynet.init 里同步取一次，之后靠事件更新。
function CMD.get()
    if not lease_valid() then
        return nil
    end
    return { leaseid = g_leaseid, epoch = g_epoch, deadline = g_deadline }
end

-- 停服：主动撤销租约，挂在它上面的锁键、节点键、服务键立刻从 etcd 消失，
-- 别的节点马上看到本节点下线，不用等 TTL 过期。
-- 这是主动放手，不发 lease_lost（那个事件的语义是失租，machine_id 会据此重新抢号）。
function CMD.shutdown()
    g_closed = true
    if g_heartbeat then
        g_heartbeat:cancel()
        g_heartbeat = nil
    end
    local leaseid = g_leaseid
    g_leaseid, g_deadline = nil, nil
    if not leaseid then
        return true
    end
    local ret, err = g_etcd_client:revoke(leaseid)
    if not ret or ret.status ~= 200 then
        log.error("node lease revoke failed", "leaseid", leaseid, "err", err, "ret", ret)
        return false
    end
    log.info("node lease revoked", "leaseid", leaseid)
    return true
end

skynet.start(function()
    g_etcd_client = assert(etcd.new(config.get_table("etcd_config")))
    event_channel_api.init()
    -- 同步拿到租约再对外服务：消费者一拿到本服务地址就能用租约加锁。
    -- etcd 此刻不可用不挡启动，交给心跳重试。
    grant_lease()
    g_heartbeat = timer.repeat_delayed("node_lease_heartbeat", HEARTBEAT_INTERVAL, heartbeat)
    cmd_api.dispatch(CMD)
end)
