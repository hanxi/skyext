local time = require "time"
local log_level = require "log.log_level"

local pairs = pairs
local tconcat = table.concat
local sformat = string.format

local colors = {
    Black = 30,
    Red = 31,
    Green = 32,
    Yellow = 33,
    Blue = 34,
    Magenta = 91,
    Cyan = 36,
    Default = 39, -- 默认颜色
    LightRed = 91,
    White = 97,
}

local function color_seq(color)
    return sformat("\x1b[%dm", color)
end

local color_reset = color_seq(0)

local level_desc = {
    [log_level.FATAL] = { name = "FATAL", color = color_seq(colors.LightRed), simple_name = "F" },
    [log_level.ERROR] = { name = "ERROR", color = color_seq(colors.Red), simple_name = "E" },
    [log_level.WARN] = { name = "WARN", color = color_seq(colors.Yellow), simple_name = "W" },
    [log_level.INFO] = { name = "INFO", color = "", simple_name = "I" },
    [log_level.DEBUG] = { name = "DEBUG", color = color_seq(colors.Cyan), simple_name = "D" },
}

local M = {}

local last_time, last_time_str
local function format_time(timestamp)
    local sec = timestamp // 1
    local ms = timestamp * 1000 % 1000

    local f
    if sec == last_time then
        f = last_time_str
    else
        f = time.format(sec)
        last_time_str = f
        last_time = sec
    end
    return sformat("%s.%03d", f, ms)
end

local function level_to_string(level)
    local desc = level_desc[level]
    return desc.name
end

local json_encoder
local grecord = {}
local function json_format_record(record)
    local rec = grecord
    rec.module = record.module
    rec.level = level_to_string(record.level)
    rec.line = record.line
    rec.msg = record.msg
    for _, event in pairs(record.events) do
        rec[event[1]] = event[2]
    end
    rec.time = format_time(record.timestamp)
    return json_encoder(rec)
end

local F = {}

function F.json(record)
    json_encoder = json_encoder or require("cjson.safe").encode
    return json_format_record(record)
end

local function default_logmt(record)
    local desc = level_desc[record.level]
    local date = format_time(record.timestamp)
    local short_log_level = desc.simple_name
    local mod = record.module
    local line = record.line
    local msg = record.msg
    local events_tbl = {}
    for _, event in pairs(record.events) do
        events_tbl[#events_tbl+1] = event[1] .. ":" .. event[2]
    end
    local events_str = tconcat(events_tbl, " ")
    return sformat("[%s %s] %s%s: msg:%s %s", date, short_log_level, mod, line, msg, events_str)
end

function F.text(record, style)
    if not level_desc[record.level] then
        error("log level not exist, level: " .. record.level)
    end
    return style(record)
end

local function colorify(msg, record)
    local desc = level_desc[record.level]
    if not desc then
        error("log level not exist, level: " .. record.level)
    end
    local color_beg = desc.color
    local color_end = color_reset
    return sformat("%s%s%s", color_beg, msg, color_end)
end

-- text format 可配置 style 函数, 参考 default_logmt
function M.get_formatter(format, color, style)
    ---返回值
    ---@return msg string format后的字符串
    format = format or "text"
    local logfmt = assert(F[format], format)
    style = style or default_logmt
    return function(record)
        local msg = logfmt(record, style)
        if color then
            return colorify(msg, record)
        else
            return msg
        end
    end
end

return M
