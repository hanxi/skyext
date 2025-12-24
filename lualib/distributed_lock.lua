local skynet = require "skynet"
local etcd = require "etcd"
local timer = require "timer"
local util_string = require "util.string"
local config = require "config"
local log = require "log"
local crypt = require "skynet.crypt"

local sformat = string.format
local encode_base64 = crypt.base64encode

local M = {}

local LOCK_PREFIX = "/skynet/lock/"
local LEASE_TTL = 30 -- 秒
local HEARTBEAT_INTERVAL = LEASE_TTL // 3

local g_etcd_client
local g_leaseid
local g_locks = {}

local function make_lock_info(key, value)
    local pfx = sformat("%s%s/", LOCK_PREFIX, key)
    return {
        pfx = pfx,
        my_key = pfx .. g_leaseid,
        value = value,
    }
end

local function make_my_key(key)
    return sformat("%s%s/%s", LOCK_PREFIX, key, g_leaseid)
end

-- 在锁失效时通知业务
local function notify_lock_expired(key, lock_info)
    if lock_info.expired_cb then
        local ok, err = xpcall(lock_info.expired_cb, debug.traceback, lock_info)
        if not ok then
            log.error("notify_lock_expired failed", "err", err, "key", key)
        end
    end
end

local function try_acquire(key, value)
    if not g_leaseid then
        log.error("etcd client not initialized", "key", key)
        return
    end

    local lock_info = make_lock_info(key, value)
    local pfx = lock_info.pfx
    local my_key = lock_info.my_key
    local compare = {
        {
            target = "CREATE",
            key = my_key,
            createRevision = 0, -- key不存在
        },
    }
    local success = {
        {
            requestPut = {
                key = my_key,
                lease = g_leaseid,
                value = value,
            },
        },
        {
            requestRange = {
                key = pfx,
                sortOrder = "ASCEND",
                sortTarget = "CREATE",
                limit = 1,
            },
        },
    }
    local failure = {
        {
            requestRange = {
                key = my_key,
            },
        },
        {
            requestRange = {
                key = pfx,
                sortOrder = "ASCEND",
                sortTarget = "CREATE",
                limit = 1,
            },
        },
    }

    local ret, err = g_etcd_client:txn(compare, success, failure)
    if err then
        log.error("etcd txn failed", "err", err)
        return
    end

    lock_info.my_rev = ret.body.header.revision
    if not ret.body.succeeded then
        -- 事务失败,说明key已存在,获取已存在key的revision
        lock_info.my_rev = ret.body.responses[1].response_range.kvs[1].create_revision
    end
    return ret.body, lock_info
end

-- TODO: 使用 watch 实现 lock 接口

-- 不等待锁定成功,失败返回谁占用
function M.try_lock(key, value, expired_cb)
    if g_locks[key] then
        return true
    end

    local resp, lock_info = try_acquire(key, value)
    if not resp then
        return false
    end

    -- 检查是否获得锁
    local owner_key = resp.responses[2].response_range.kvs
    if (not owner_key) or (#owner_key == 0) or (owner_key[1].create_revision == lock_info.my_rev) then
        lock_info.expired_cb = expired_cb
        g_locks[key] = lock_info
        log.info("lock success", "key", lock_info.my_key, "value", value)
        return true
    end

    -- 被谁锁的
    local lockvalue = owner_key[1].value

    -- 未获得锁,清理key
    local ret, err = g_etcd_client:delete(lock_info.my_key)
    if not ret then
        log.error("distributed_lock etcd delete fail", "key", lock_info.my_key, "err", err)
    end

    return false, lockvalue
end

-- 解锁
function M.unlock(key)
    if not g_locks[key] then
        return false, "lock not held"
    end

    local my_key = g_locks[key].my_key

    local ret, err = g_etcd_client:delete(my_key)
    if not ret then
        log.error("etcd delete fail", "key", my_key, "err", err)
        return false
    end

    g_locks[key] = nil
    log.info("unlock success", "key", key, "my_key", my_key)
    return true
end

local function etcd_grant()
    local ret, err = g_etcd_client:grant(LEASE_TTL)
    if not ret then
        log.error("distributed_lock grant leaseid failed", "err", err)
        return
    elseif (not ret.body) or not ret.body.ID then
        log.error("distributed_lock grant leaseid failed", "ret", ret)
        return
    end

    g_leaseid = ret.body.ID
    log.info("distributed_lock grant", "leaseid", g_leaseid)
    return true
end

local function etcd_keepalive()
    if not g_leaseid then
        log.error("distributed_lock keepalive no leaseid")
        return false
    end

    local ret, err = g_etcd_client:keepalive(g_leaseid)
    if not ret then
        log.error("distributed_lock keepalive failed socket", "err", err)
        return true
    elseif (not ret.body) or not ret.body.result or not ret.body.result.TTL then
        log.error("distributed_lock keepalive overdue", "leaseid", g_leaseid)
        return false
    end

    log.debug("distributed_lock etcd keepalive ok", "leaseid", g_leaseid, "ttl", ret.body.result.TTL)
    return true
end

-- 尝试使用新lease重建所有锁
local function on_recreate_lease()
    local old_locks = g_locks
    g_locks = {} -- 立刻清空，表示所有旧锁都已失效

    log.info("on_recreate_lease leaseid recreated", "leaseid", g_leaseid)
    for key, lock_info in pairs(old_locks) do
        local ok, lockvalue = M.try_lock(key, lock_info.value, lock_info.expired_cb)
        if not ok then
            log.error("on_recreate_lease recreate lock failed", "key", key, "lockvalue", lockvalue)
            -- 锁重建失败，通知业务
            notify_lock_expired(key, lock_info)
        else
            log.info("Successfully re-acquired lock", "key", key)
        end
    end
end

skynet.init(function()
    local etcd_config = config.get_table("etcd_config")
    g_etcd_client = etcd.new(etcd_config)
    g_keepalive_timer = timer.repeat_immediately("distributed_lock_heartbeat", HEARTBEAT_INTERVAL, function()
        if g_leaseid and etcd_keepalive() then
            -- 续约成功，一切正常
            return
        end

        -- 续约失败或 leaseid 不存在，需要重新获取
        g_leaseid = nil
        if etcd_grant() then
            -- 成功获取新租约，现在处理锁的重建
            -- 使用 skynet.fork 来异步执行，避免阻塞 timer
            skynet.fork(on_recreate_lease)
        else
            log.error("Failed to grant a new lease. Will retry in next interval.")
        end
    end)
end)

return M
