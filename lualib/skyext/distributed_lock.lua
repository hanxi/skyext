local skynet = require "skynet"
local etcd = require "skyext.etcd"
local codec = require "skyext.etcd.codec"
local timer = require "skyext.timer"
local config = require "skyext.config"
local log = require "skyext.log"

local M = {}

local LOCK_PREFIX = "/skynet/lock/"
local LEASE_TTL = 30
local HEARTBEAT_INTERVAL = LEASE_TTL // 3

local g_etcd_client
local g_leaseid
local g_deadline
local g_locks = {}

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
    g_leaseid = nil
    g_deadline = nil
    for key, handle in pairs(old_locks) do
        handle.valid = false
        log.error("distributed lock expired", "key", key, "reason", reason)
        notify_lock_expired(key, handle)
    end
end

local function lease_valid()
    if not g_leaseid or not g_deadline then
        return false
    end
    if skynet.now() >= g_deadline then
        invalidate_all("lease heartbeat deadline elapsed")
        return false
    end
    return true
end

function M.is_valid(handle)
    return handle ~= nil and handle.valid and lease_valid() and g_locks[handle.key] == handle
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
    local existing = g_locks[key]
    if existing and M.is_valid(existing) then
        return true, existing
    end
    if not lease_valid() then
        return false, "etcd lease unavailable"
    end

    local leaseid = g_leaseid
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
    if not lease_valid() or leaseid ~= g_leaseid then
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
    if g_locks[key] ~= handle or not lease_valid() then
        return false, "lease expired during unlock"
    end
    g_locks[key] = nil
    handle.valid = false
    log.info("lock released", "key", key, "fence", handle.fence)
    return true
end

local function grant_lease()
    local started = skynet.now()
    local ret, err = g_etcd_client:grant(LEASE_TTL)
    if not ret or ret.status ~= 200 or not ret.body or not ret.body.ID then
        log.error("distributed lock grant failed", "err", err, "ret", ret)
        return false
    end
    g_leaseid = ret.body.ID
    g_deadline = started + (LEASE_TTL - 2) * 100
    if not lease_valid() then
        return false
    end
    log.info("distributed lock lease granted", "leaseid", g_leaseid)
    return true
end

local function keepalive()
    local started = skynet.now()
    local leaseid = g_leaseid
    local ret, err = g_etcd_client:keepalive(leaseid)
    local ttl = ret and ret.body and ret.body.result and tonumber(ret.body.result.TTL)
    if not ret or ret.status ~= 200 or not ttl or ttl <= 0 or leaseid ~= g_leaseid then
        log.error("distributed lock keepalive failed", "err", err, "leaseid", leaseid, "ret", ret)
        return false
    end
    g_deadline = started + (math.min(ttl, LEASE_TTL) - 2) * 100
    return lease_valid()
end

skynet.init(function()
    g_etcd_client = assert(etcd.new(config.get_table("etcd_config")))
    -- 同步拿到租约再往下走：require 一返回调用方就能加锁。
    -- 以前租约是交给心跳定时器异步申请的，模块加载完到定时器跑第一轮之间
    -- 所有 try_lock 都会拿到 etcd lease unavailable，snowflake 抢机器号就栽在这里。
    -- etcd 此刻不可用不挡启动，继续交给心跳重试。
    grant_lease()
    timer.repeat_delayed("distributed_lock_heartbeat", HEARTBEAT_INTERVAL, function()
        if g_leaseid and not keepalive() then
            invalidate_all("keepalive failed or lease expired")
        end
        if not g_leaseid then
            grant_lease()
        end
    end)
end)

return M
