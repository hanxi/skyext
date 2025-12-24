-- 输出到文件
local time = require "time"
local log_util = require "log.util"
local log_formatter = require "log.formatter"

local parse_level = log_util.parse_level
local should_log = log_util.should_log

local assert = assert
local tonumber = tonumber
local sfind = string.find
local smatch = string.match
local os_date = os.date

local LOG_ONELINE_SZ = 255

local file_mt = {}
file_mt.__index = file_mt

local line_mt = {}
line_mt.__index = line_mt

local time_mt = {}
time_mt.__index = time_mt

local size_mt = {}
size_mt.__index = size_mt

local M = {}

function line_mt:need_split()
    self.linecount = self.linecount + 1
    if self.linecount > self.maxline then
        self.linecount = 0
        return true
    end
    return false
end

function time_mt:need_split()
    local t = os_date("*t", time.now())
    if self.split == "hour" then
        if
            t.year ~= self.last.year
            or t.month ~= self.last.month
            or t.day ~= self.last.day
            or t.hour ~= self.last.hour
        then
            self.last.year = t.year
            self.last.month = t.month
            self.last.day = t.day
            self.last.hour = t.hour
            return true
        end
    else -- day
        if t.year ~= self.last.year or t.month ~= self.last.month or t.day ~= self.last.day then
            self.last.year = t.year
            self.last.month = t.month
            self.last.day = t.day
            return true
        end
    end
    return false
end

function size_mt:need_split(str)
    local delta = #str + 1
    local size = self.size + delta
    if size > delta and size > self.maxsize then
        self.size = delta
        return true
    end
    self.size = size
    return false
end

function file_mt:reload()
    self:close()
    local handle = assert(io.open(self.path, "a+"))
    if self.flush_n > 0 then
        handle:setvbuf("full", self.flush_n * LOG_ONELINE_SZ)
    else
        handle:setvbuf("line")
    end
    self.handle = handle
    self.size = handle:seek("end")
end

function file_mt:split()
    local split_mgr = self.split_mgr
    local path = self.path
    local filename = path
    local new_path
    repeat
        if filename == split_mgr.lastprefix then
            split_mgr.count = split_mgr.count + 1
            new_path = filename .. "." .. split_mgr.count
        else
            split_mgr.count = 0
            split_mgr.lastprefix = filename
            new_path = filename
        end
        local handle <close> = io.open(new_path)
    until not handle
    os.rename(path, new_path)
    self:reload()
    if split_mgr.size then
        split_mgr.size = split_mgr.size + self.size
    end
end

function file_mt:init()
    self:reload()
    if self.split_mgr and self.size > 0 then
        self:split()
    end
end

function file_mt:put(record)
    if not self.handle then
        return nil
    end

    if not should_log(self.level, record.level) then
        return nil
    end
    local str = self.formatter(record)
    local split_mgr = self.split_mgr
    if split_mgr and split_mgr:need_split(str) then
        self:split()
    end
    local flush_n = self.flush_n
    if flush_n > 0 then
        local flush_i = self.flush_i + 1
        self.handle:write(str, "\n")
        if flush_i == flush_n then
            self:flush()
        end
    else
        self.handle:write(str, "\n")
    end
    return true
end

function file_mt:flush()
    if self.flush_n > 0 then
        self.flush_i = 0
    end
    self.flush_ok = self.handle:flush()
end

function file_mt:check_error()
    return self.flush_ok ~= true
end

function file_mt:close()
    local handle = self.handle
    if handle then
        self:flush()
        handle:close()
        self.handle = nil
    end
end

local function parse_bytes(u)
    local num, unit = smatch(u:upper(), "^([%d.]+)([KMGTP]?)B?$")
    num = assert(unit and tonumber(num), "invalid format")
    local index = (sfind("KMGTP", unit) or 0) * 10
    return num * (1 << index)
end

local function new_split_mgr(params)
    if not params.split then
        return
    end

    local mgr = {
        count = 0,
        dateext = params.dateext,
    }

    if params.split == "line" then
        mgr.maxline = params.maxline
        mgr.linecount = 0
        return setmetatable(mgr, line_mt)
    elseif params.split == "size" then
        mgr.maxsize = parse_bytes(params.maxsize)
        mgr.size = 0
        return setmetatable(mgr, size_mt)
    elseif params.split == "hour" then
        local t = os_date("*t", time.now())
        mgr.last = {
            year = t.year,
            month = t.month,
            day = t.day,
            hour = t.hour,
        }
        mgr.split = params.split
        return setmetatable(mgr, time_mt)
    elseif params.split == "day" then
        local t = os_date("*t", time.now())
        mgr.last = {
            year = t.year,
            month = t.month,
            day = t.day,
        }
        mgr.split = params.split
        return setmetatable(mgr, time_mt)
    end
end

-- 日志轮转生成名字格式:
-- filename.count
-- 例如: 配置文件名 app.log
-- 轮转文件名: app.log.1
-- 必须提供文件名，不支持配空
--  params: 支持三种分割方式(默认不分割); 支持 json 风格输出(默认关闭)
--      filename
--      split=size&maxsize=100M
--      split=line&maxline=100000
--      split=hour/day
--      format=json      (json/text)
--      color=true       (使用颜色)
--      style            (函数或日志格式字符串或vtext格式)
--      level=INFO-DEBUG (日志级别范围)
--      flush_period=0  (多少条日志刷一次盘，默认为 0，每次都刷)
function M.new(params)
    assert(params.filename, "please specify a file pattern")
    local split_mgr = new_split_mgr(params)
    local file_obj = {
        path = params.filename, -- 当前文件路径
        split_mgr = split_mgr,
        flush_i = 0,
        flush_n = params.flush_period or 0,
        flush_ok = true,
    }
    file_obj.params = {
        format = "text",
        color = false,
        split = false,
        maxline = 1e6,
        maxsize = "100M",
    }
    for k, v in pairs(params) do
        file_obj.params[k] = v
    end
    params = file_obj.params

    file_obj.formatter = log_formatter.get_formatter(params.format, params.color, params.style)
    file_obj.level = parse_level(params.level)
    file_obj = setmetatable(file_obj, file_mt)

    file_obj:init()
    return file_obj
end

return M
