local logger = require "skyext.log.logger"

local M = {}

local default_logger = logger.new()

M.logger = default_logger

function M.config(...)
    return default_logger:config(...)
end

function M.debug(...)
    return default_logger:debug(...)
end

function M.info(...)
    return default_logger:info(...)
end

function M.warn(...)
    return default_logger:warn(...)
end

function M.error(...)
    return default_logger:error(...)
end

function M.xpcall_msgh(...)
    return default_logger:xpcall_msgh(...)
end

function M.sys_assert(...)
    return default_logger:sys_assert(...)
end

function M.sys_error(...)
    return default_logger:sys_error(...)
end

function M.is_enabled(...)
    return default_logger:is_enabled(...)
end

--- 按应用配置初始化默认 logger
-- 不再覆盖 _G.assert / _G.error / _G.pcall / _G.xpcall，
-- 需要“报错同时打印堆栈”的场景请显式使用 log.sys_assert / log.sys_error / log.xpcall_msgh。
function M.init()
    local config = require "skyext.config"
    local conf = {
        level = config.get_number("log_level"),
        log_src = config.get_boolean("log_src"),
        log_table = config.get_boolean("log_print_table"),
    }
    -- 配置非法时不能静默吞掉（旧实现用错 self 且错误处理函数本身会再抛错），
    -- 这里退回默认配置并把原因打出来
    local ok, err = pcall(default_logger.config, default_logger, conf)
    if not ok then
        default_logger:error("invalid log config, fallback to default", "err", tostring(err))
    end
end

return M
