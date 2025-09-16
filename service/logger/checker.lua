--- 通过队列长度判断日志服务过载，避免堆积日志过大造成内存 oom
local skynet = require "skynet"
local config = require "config"
local global = require "global"
local log = require "log"
local timer = require "timer"

local xpcall_msgh = log.xpcall_msgh

local HEARTBEAT_INTERVAL = 10

local checkers = {}

local overload_mqlen = config.get_number("log_overload_mqlen") or 1000000
local overload_off_mqlen = overload_mqlen * 0.8
checkers.check_mqlen = function()
    local mqlen = skynet.mqlen()

    if global.log_overload and mqlen < overload_off_mqlen then
        global.log_overload = false
        log.info("log overload off", "mqlen", mqlen)
        return
    end

    if mqlen >= overload_mqlen then
        log.error("log overload on", "mqlen", mqlen)
        global.log_overload = true
    end
end

checkers.check_bucket = function()
    for _, bucket in pairs(global.bucket.buckets) do
        if bucket.check_error and bucket.reload and bucket:check_error() then
            bucket:reload()
        end
    end
end

skynet.init(function()
    xpcall(timer.repeat_delayed, xpcall_msgh, "log_heartbeat", HEARTBEAT_INTERVAL, function()
        for _, f in pairs(checkers) do
            pcall(f)
        end
    end)
end)
