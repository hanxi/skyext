-- service/node_lease 的客户端：节点级 etcd 租约的只读视图。
--
-- 租约的申请、续租、撤销全在 node_lease 服务里，这里只缓存快照并在失效时通知订阅者。
-- 谁要把自己的东西挂在节点租约上（实体锁、服务发现键），就 require 这个库。
--
-- valid() 是纯本地判断，不发消息：node_lease 推过来的 deadline 是绝对的
-- skynet.now() 刻度，而 skynet.now() 读的是进程全局的 TI->current，同一进程里
-- 所有服务看到同一个值，所以直接比较不存在时钟偏移。这样设计还顺带兜住了
-- "node_lease 自己卡死"这种情况：它不再推新的 deadline，老的一到期这里就自行判失效，
-- 不会出现服务卡住而消费者以为租约还活着。
local skynet = require "skynet"
local event_channel_api = require "skyext.event_channel_api"
local log = require "skyext.log"

local M = {}

local g_service
local g_leaseid
local g_epoch = 0
local g_deadline
-- { {name = , fn = }, ... }，按注册顺序回调
local g_on_lost = {}

local function fire_lost(epoch, reason)
    log.error("node lease lost", "epoch", epoch, "reason", reason)
    for _, sub in ipairs(g_on_lost) do
        local ok, err = xpcall(sub.fn, debug.traceback, epoch, reason)
        if not ok then
            log.error("node lease lost callback failed", "name", sub.name, "err", err)
        end
    end
end

local function clear(epoch, reason)
    if not g_leaseid then
        return
    end
    g_leaseid, g_deadline = nil, nil
    fire_lost(epoch, reason)
end

local function on_lease_alive(leaseid, epoch, deadline)
    if epoch ~= g_epoch and g_leaseid then
        -- 换了新租约却没收到失效事件（比如本服务启动时错过了），补一次失效通知，
        -- 让挂在旧租约上的东西有机会清掉再重建
        clear(g_epoch, "superseded by a new lease")
    end
    g_leaseid, g_epoch, g_deadline = leaseid, epoch, deadline
end

local function on_lease_lost(epoch, reason)
    if epoch ~= g_epoch then
        return
    end
    clear(epoch, reason)
end

-- 当前租约是否可用。到期即就地判失效并触发回调。
function M.valid()
    if not g_leaseid or not g_deadline then
        return false
    end
    if skynet.now() >= g_deadline then
        clear(g_epoch, "lease deadline elapsed without a refresh")
        return false
    end
    return true
end

-- etcd 的租约 ID（字符串，原样透传，不转数字以免 int64 丢精度）
function M.id()
    return g_leaseid
end

-- 租约世代。每批新租约 +1，用来判断手里的东西是不是还挂在同一个租约上。
function M.epoch()
    return g_epoch
end

-- 注册失效回调。fn(epoch, reason)，在租约失效时按注册顺序调用一次。
-- name 只用于出错时定位，不做去重。
function M.on_lost(name, fn)
    g_on_lost[#g_on_lost + 1] = { name = name, fn = fn }
end

-- 停服时主动撤销节点租约：挂在上面的锁键、服务发现键立刻从 etcd 消失，
-- 别的节点马上看到本节点下线，不用等 TTL 过期。不触发失效回调。
function M.shutdown()
    return skynet.call(g_service, "lua", "shutdown")
end

skynet.init(function()
    g_service = skynet.uniqueservice("node_lease")
    -- 先订阅再取快照：反过来的话，两步之间发生的失效事件会被漏掉。
    -- 多收一次重复的 lease_alive 无害（epoch 相同，只是刷新 deadline）。
    event_channel_api.subscribe(g_service, "lease_alive", on_lease_alive)
    event_channel_api.subscribe(g_service, "lease_lost", on_lease_lost)

    local snapshot = skynet.call(g_service, "lua", "get")
    if snapshot then
        on_lease_alive(snapshot.leaseid, snapshot.epoch, snapshot.deadline)
    end
end)

return M
