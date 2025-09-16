print("fuck", package.path)
local skynet = require "skynet"
local c = require "skynet.core"
local cmd_api = require "cmd_api"
local cmd = require "cmd"
local global = require "global"
local bucket = require "bucket"
local logger = require "log.logger"
local config = require "config"
local ptype = require "ptype"
require "checker"

local skynet_unpack = skynet.unpack

local PTYPE_LOG = ptype.PTYPE_LOG
local PTYPE_LOG_ERR = ptype.PTYPE_LOG_ERR

local kernel_logger = logger.new()
kernel_logger:config({
    name = "kernel",
    log_src = false,
})

-- 捕捉sighup信号(kill -1)
skynet.register_protocol {
    name = "SYSTEM",
    id = skynet.PTYPE_SYSTEM,
    unpack = function(...)
        return ...
    end,
    dispatch = function()
        global.bucket.reload()
        kernel_logger:info("SIGHUP")
    end,
}

skynet.register_protocol {
    name = "text",
    id = skynet.PTYPE_TEXT,
    unpack = skynet.tostring,
    dispatch = function(_, address, msg)
        local found = msg:find("[Ee]rror")
        if found then
            -- 删除 msg 中的颜色字符
            msg = msg:gsub("\x1B%[%d+m", "")
            kernel_logger:warn(msg, "address", address)
        else
            kernel_logger:info(msg, "address", address)
        end
    end,
}

local function logger_dispatch_callback(prototype, msg, sz, session, source)
    if prototype == PTYPE_LOG then
        -- 定时检查服务过载情况, 过载时丢弃LOG日志
        if global.log_overload then
            return
        end

        return global.bucket:put(skynet_unpack(msg, sz))
    elseif prototype == PTYPE_LOG_ERR then
        --- ERROR 日志不执行流控
        return global.bucket:put(skynet_unpack(msg, sz))
    else
        return skynet.dispatch_message(prototype, msg, sz, session, source)
    end
end

local function start_func()
    local log_config = config.get_table("log_config")
    global.bucket = bucket.new(log_config)
    cmd_api.dispatch(cmd)
    skynet.register(".logger")
end

c.callback(logger_dispatch_callback)
skynet.timeout(0, function()
    skynet.init_service(function()
        local ok, err = pcall(start_func)
        if not ok then
            print(err)
        end
    end)
end)
