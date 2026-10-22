-- 基于 etcd 的实体锁，带 fencing token。
--
-- 锁键挂在节点级租约上（见 skyext.node_lease）：租约一没，etcd 自动删掉本节点
-- 持有的全部锁键，别的节点立刻就能接手，不用等谁来主动释放。本模块只负责
-- 加锁/解锁和租约失效时的本地隔离，租约本身的申请与续租是 node_lease 服务的事。
--
-- fence 用的是锁键的 create_revision——etcd 全局单调递增，同一把锁的新持有者
-- 拿到的 fence 一定比旧持有者大。存储层据此拒绝旧持有者的迟到写入。
local skynet = require "skynet"
local etcd = require "skyext.etcd"
local codec = require "skyext.etcd.codec"
local node_lease = require "skyext.node_lease"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

local LOCK_PREFIX = "/skynet/lock/"

local g_etcd_client
local g_locks = {}
-- 停服后置位：不再加锁
local g_closed = false

local function notify_lock_expired(key, handle)
    if handle.expired_cb then
        local ok, err = xpcall(handle.expired_cb, debug.traceback, handle)
        if not ok then
            log.error("notify_lock_expired failed", "key", key, "err", err)
        end
    end
end

local function invalidate_all(reason)
    local old_locks = g_locks
    g_locks = {}
    for key, handle in pairs(old_locks) do
        handle.valid = false
        log.error("distributed lock expired", "key", key, "reason", reason)
        notify_lock_expired(key, handle)
    end
end

function M.is_valid(handle)
    return handle ~= nil
        and handle.valid
        and node_lease.valid()
        and handle.epoch == node_lease.epoch()
        and g_locks[handle.key] == handle
end

local function parse_revision(revision)
    local n = tonumber(revision)
    return n and math.tointeger(n)
end

-- 锁值是持锁方传进来的字符串（当前全部调用方传的都是节点名）。写入时 etcd 客户端
-- 按 codec.encode_value 先 JSON 再 base64，读回来必须走同一套解码。
-- 这里曾经只解 base64，拿到的是带引号的 "\"rolenode1\""，和任何节点名都对不上，
-- 上层的交接和转发全都打到一个不存在的节点上。
local function parse_owner(kv)
    if not kv or not kv.value then
        return nil
    end
    local owner = codec.decode_value(kv.value)
    if type(owner) ~= "string" or owner == "" then
        return nil
    end
    return owner
end

function M.try_lock(key, value, expired_cb)
    assert(type(key) == "string" and key ~= "", "lock key required")
    if g_closed then
        return false, "lock service closed"
    end
    local existing = g_locks[key]
    if existing and M.is_valid(existing) then
        return true, existing
    end
    if not node_lease.valid() then
        return false, "etcd lease unavailable"
    end

    local leaseid, epoch = node_lease.id(), node_lease.epoch()
    local lock_key = LOCK_PREFIX .. key
    local ret, err = g_etcd_client:txn({
        { target = "CREATE", key = lock_key, create_revision = 0 },
    }, {
        { requestPut = { key = lock_key, value = value, lease = leaseid } },
    }, {
        { requestRange = { key = lock_key } },
    })
    if not ret or ret.status ~= 200 or not ret.body then
        log.error("etcd lock transaction failed", "key", key, "err", err, "ret", ret)
        return false, err or "etcd lock transaction failed"
    end
    -- 请求往返期间租约可能已经换过一轮，那样这次写入已经被 etcd 连带删掉了
    if not node_lease.valid() or epoch ~= node_lease.epoch() then
        return false, "lease changed during acquisition"
    end
    if g_locks[key] and M.is_valid(g_locks[key]) then
        return true, g_locks[key]
    end

    local body = ret.body
    local revision
    if body.succeeded then
        revision = parse_revision(body.header and body.header.revision)
    else
        local range = body.responses and body.responses[1] and body.responses[1].response_range
        local kv = range and range.kvs and range.kvs[1]
        if kv and tostring(kv.lease) == tostring(leaseid) then
            revision = parse_revision(kv.create_revision)
        else
            return false, "lock held", parse_owner(kv)
        end
    end
    if not revision then
        return false, "etcd did not return a fencing revision"
    end

    local handle = {
        key = key,
        my_key = lock_key,
        lease = leaseid,
        epoch = epoch,
        fence = revision,
        valid = true,
        expired_cb = expired_cb,
    }
    g_locks[key] = handle
    log.info("lock acquired", "key", key, "fence", revision)
    return true, handle
end

function M.unlock(key, handle)
    if not M.is_valid(handle) or handle.key ~= key then
        return false, "lock not held or lease expired"
    end

    -- Do not delete a successor's key if the old lease expired during the request.
    local ret, err = g_etcd_client:txn({
        { target = "CREATE", key = handle.my_key, create_revision = handle.fence },
    }, {
        { requestDeleteRange = { key = handle.my_key } },
    }, {
        { requestRange = { key = handle.my_key } },
    })
    if not ret or ret.status ~= 200 or not ret.body or not ret.body.succeeded then
        log.error("etcd unlock failed", "key", key, "err", err, "ret", ret)
        if g_locks[key] == handle then
            g_locks[key] = nil
            handle.valid = false
            notify_lock_expired(key, handle)
        end
        return false, err or "lock no longer owned"
    end
    if g_locks[key] ~= handle or not M.is_valid(handle) then
        return false, "lease expired during unlock"
    end
    g_locks[key] = nil
    handle.valid = false
    log.info("lock released", "key", key, "fence", handle.fence)
    return true
end

-- 本服务停止加锁，并丢弃手里的锁句柄。
--
-- 这里不撤销租约：租约是节点级的，归 node_lease 管，本节点还有别的服务在用它。
-- 停服时真正放锁的动作是 node_shutdown 最后撤销节点租约，etcd 会连带删掉所有锁键。
-- 这是主动放手，不触发过期回调（回调的语义是失租，machine_id 会据此重新抢号）。
function M.shutdown()
    g_closed = true
    for _, handle in pairs(g_locks) do
        handle.valid = false
    end
    g_locks = {}
    return true
end

skynet.init(function()
    g_etcd_client = assert(etcd.new(config.get_table("etcd_config")))
    node_lease.on_lost("distributed_lock", function(_, reason)
        invalidate_all(reason)
    end)
end)

return M
