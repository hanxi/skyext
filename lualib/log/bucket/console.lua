-- 输出到屏幕
local log_formatter = require "log.formatter"
local log_util = require "log.util"

local should_log = log_util.should_log
local parse_level = log_util.parse_level

local M = {}

local console_mt = {}
console_mt.__index = console_mt

function console_mt:put(record)
    if not should_log(self.level, record.level) then
        return nil
    end
    local msg = self.formatter(record)
    self.handle:write(msg, "\n")
    return true
end

function M.new(params)
    local console_obj = {}
    console_obj.params = { format = "text", color = true }
    for k, v in pairs(params) do
        console_obj.params[k] = v
    end
    params = console_obj.params

    console_obj.level = parse_level(params.level)
    console_obj.formatter = log_formatter.get_formatter(params.format, params.color, params.style)
    console_obj.handle = io.stdout
    console_obj = setmetatable(console_obj, console_mt)
    return console_obj
end

return M
