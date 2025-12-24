local skynet = require "skynet"
local log = require "log"
local service = require "skynet.service"

local function test_etcd_service1()
    local skynet = require "skynet"
    local config = require "config"
    local log = require "log"
    local timer = require "timer"
    local etcd = require "etcd"

    skynet.start(function()
        local etcd_config = config.get_table("etcd_config")
        local etcd_client = etcd.new(etcd_config)
        timer.repeat_immediately("test1", 100, function()
            local LEASE_TTL = 30 -- 秒

            local r = etcd_client:get("/test/a")
            log.info("etcd get /test/a", "r", r)
            skynet.fork(function()
                local ret, err = etcd_client:grant(LEASE_TTL)
                log.info("etcd grant", "ret", ret, "err", err)
            end)
            skynet.call(".test-etcd2", "lua", "get")
        end)
        skynet.register(".test-etcd1")
    end)
end
local function test_etcd_service2()
    local skynet = require "skynet"
    local config = require "config"
    local log = require "log"
    local cmd_api = require "cmd_api"
    local etcd = require "etcd"

    skynet.start(function()
        local etcd_config = config.get_table("etcd_config")
        local etcd_client = etcd.new(etcd_config)
        local CMD = {}
        function CMD.get()
            local r = etcd_client:get("/test/a")
            log.info("etcd get /test/a", "r", r)
        end
        cmd_api.dispatch(CMD)
        skynet.register(".test-etcd2")
    end)
end
skynet.start(function()
    log.info("Test etcd start")
    service.new("test-etcd1", test_etcd_service1)
    service.new("test-etcd2", test_etcd_service2)
end)
