local log_level = require "log.log_level"

local assert = assert
local smatch = string.match
local supper = string.upper

local M = {}

function M.parse_level(input)
    if not input then
        return
    end
    local upper, lower = smatch(input, "^(%a*)-?(%a*)$")
    upper = assert(log_level[#upper > 0 and supper(upper) or "DEBUG"], upper)
    lower = assert(log_level[#lower > 0 and supper(lower) or "FATAL"], lower)
    assert(lower <= upper, "invalid log level setting")
    return { lower = lower, upper = upper }
end

function M.should_log(level, record_level)
    return not (level and (record_level < level.lower or record_level > level.upper))
end

return M
