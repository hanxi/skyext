local logger = require "log.logger"

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

function M.init()
    local config = require "config"
    xpcall(default_logger.config, default_logger.error, {
        level = config.get_number("log_level"),
        log_src = config.get_boolean("log_src"),
        log_table = config.get_boolean("log_print_table"),
    })

    _G.raw_assert = assert
    _G.raw_error = error
    _G.assert = M.sys_assert
    _G.error = M.sys_error
    _G.pcall = logger.safe_pcall
    _G.xpcall = logger.safe_xpcall
end

return M
