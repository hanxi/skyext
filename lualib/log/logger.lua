local time = require "time"
local util_table = require "util.table"
local bucket = require "log.bucket"
local log_level = require "log.log_level"
local traceback_c = require "traceback.c"

local type = type
local error = error
local pairs = pairs
local assert = assert
local select = select
local tostring = tostring
local setmetatable = setmetatable

local sformat = string.format

local DEBUG = log_level.DEBUG
local INFO = log_level.INFO
local WARN = log_level.WARN
local ERROR = log_level.ERROR
local FATAL = log_level.FATAL

local M = {}

local service_bucket, default_bucket
local function get_bucket()
    -- logger service 会返回 service/logger/bucket.lua 中的 service_bucket
    service_bucket = service_bucket or bucket.new({ name = "service" })
    if service_bucket then
        return service_bucket
    end

    -- 没有 service_bucket 时，使用默认的 bucket
    default_bucket = default_bucket or bucket.get_default()
    return default_bucket
end

local g_record = {}
local function save_to_bucket(modname, level, timestamp, src, msg, events)
    local bucket = get_bucket()
    g_record.module = modname
    g_record.level = level
    g_record.timestamp = timestamp
    g_record.line = src
    g_record.msg = msg
    g_record.events = events
    bucket:put(g_record)
    return g_record
end

local function get_log_src(level)
    -- 防止函数尾调用抓到C函数堆栈导致行号异常
    while true do
        level = level + 1
        local info = debug.getinfo(level, "Sl")
        if not info then
            return "UNKNOWN"
        end
        local currentline = info.currentline
        if currentline > 0 then
            return sformat("%s:%s", info.source, info.currentline)
        end
    end
end

-- logger object
local logger = {}
logger.__index = logger

function logger:_serialize(level, s)
    if type(s) == "table" and (self.log_table or level < INFO) then
        return util_table.tostring(s)
    end
    return s
end

--  结构化日志
function logger:_pack_events(level, ...)
    local n = select("#", ...)
    assert(n % 2 == 0, "log args not even, must be key-value pairs")
    local values = { ... }
    for i = 1, n do
        values[i] = tostring(self:_serialize(level, values[i]))
    end

    local events = {}
    local events_key_cnt = {
        module = 1,
        level = 1,
        timestamp = 1,
        line = 1,
        msg = 1,
    }
    for i = 1, n, 2 do
        local k = values[i]
        local v = values[i + 1]
        local key = k
        local cnt = events_key_cnt[k] or 0
        if cnt > 0 then
            key = k .. "_" .. events_key_cnt[k]
        end
        events[#events + 1] = { key, v }
        events_key_cnt[k] = cnt + 1
    end
    return events
end

function logger:_raw_log(level, stack_depth, msg, ...)
    local events = self:_pack_events(level, ...)
    local timestamp = time.time()
    local src = ""
    if self.log_src then
        src = get_log_src(self.stack_level + stack_depth) or ""
    end
    local modname = self.name
    save_to_bucket(modname, level, timestamp, src, msg, events)
end

function logger:_log(level, stack_depth, msg, ...)
    -- 过滤掉信息的条件：level高于log_level
    if level > self.level then
        return
    end
    local ok, err = pcall(self._raw_log, self, level, stack_depth, msg, ...)
    if not ok then
        -- 兜底
        print(err, msg, ...)
    end
end

-- public interface
local ext_stack_depth = 2
function logger:debug(...)
    return self:_log(DEBUG, ext_stack_depth, ...)
end

function logger:info(...)
    return self:_log(INFO, ext_stack_depth, ...)
end

function logger:warn(...)
    return self:_log(WARN, ext_stack_depth, ...)
end

function logger:error(...)
    local tcb = self.traceback(nil, 2)
    return self:_log(ERROR, ext_stack_depth, "traceback", tcb, ...)
end

local function log_traceback(self, log_lv, stack_depth, err_type, err_msg)
    local tcb = self.traceback(nil, stack_depth + 1)
    return self:_log(log_lv, stack_depth, "stack traceback", "err_type", err_type, "err_msg", err_msg, "traceback", tcb)
end

local xpcall_counter = 0
local pcall_counter = 0

-- 创建恢复对象
local function create_restore_guard()
    local original_xpcall_count = xpcall_counter
    local original_pcall_count = pcall_counter
    local guard = {}

    -- 设置元表使对象可关闭
    local mt = {}
    mt.__close = function(self)
        xpcall_counter = original_xpcall_count
        pcall_counter = original_pcall_count
    end

    setmetatable(guard, mt)
    return guard
end

-- 检查是否在错误处理上下文中
local function in_error_handling_context()
    return xpcall_counter > 0 or pcall_counter > 0
end

-- 封装的 pcall
local origin_pcall = pcall
function M.safe_pcall(func, ...)
    pcall_counter = pcall_counter + 1
    local _ <close> = create_restore_guard()
    return origin_pcall(func, ...)
end

-- 封装的 xpcall
local origin_xpcall = xpcall
function M.safe_xpcall(func, msgh, ...)
    xpcall_counter = xpcall_counter + 1
    local _ <close> = create_restore_guard()
    return origin_xpcall(func, msgh, ...)
end

local do_error_stack_depth = 1
local is_first_get_traceback = true
local reset_is_first_get_traceback = setmetatable({}, {
    __close = function()
        is_first_get_traceback = true
    end,
})
local function do_error(self, err_type, err_msg, err_lv)
    if is_first_get_traceback and (not in_error_handling_context()) then
        is_first_get_traceback = false
        local _ <close> = reset_is_first_get_traceback
        log_traceback(self, FATAL, do_error_stack_depth, err_type, err_msg)
    end
    return error(err_msg, err_lv)
end

local def_assert_msg = "assertion failed!"
local assert_err_lv = 2
function logger:sys_assert(v, ...)
    if v then
        return v, ...
    end
    local message = select("#", ...) > 0 and ... or def_assert_msg

    return do_error(self, "assert", message, assert_err_lv)
end

function logger:sys_error(message, level)
    level = level or 1
    if level > 0 then
        level = level + 1
    end

    return do_error(self, "error", message, level)
end

local xpcall_msgh_stack_depth = 2
function logger:xpcall_msgh(msg)
    log_traceback(self, FATAL, xpcall_msgh_stack_depth, "error", msg)
    return msg
end

-- 配置字段类型约束，如果 type 为 table，则为 table 映射值。
-- field 代表映射到config中代表的字段
local config_constraint = {
    name = { type = "string" },
    level = { type = log_level },
    log_src = { type = "boolean" },
    log_table = { type = "boolean" },
    stack_level = { type = "number" },
    traceback = { type = "function" },
}

function logger:config(t)
    -- 检查配置字段约束
    for f, v in pairs(t) do
        local c = assert(config_constraint[f], "invalid config type:" .. f)
        local ct = c.type
        if type(ct) == "table" then
            v = assert(ct[v], "invalid value: " .. v .. " for config: " .. f)
        else -- lua types
            if type(v) ~= ct then
                error("type mismatch for field: " .. f)
            end
        end
        self[f] = v
    end
end

function M.new()
    local obj = {}
    -- 单 vm 内 SERVICE_ARGS 作为全局变量读取。
    obj.name = SERVICE_ARGS or "skyext"

    obj.level = log_level.DEBUG
    obj.log_src = true

    -- 回溯栈的深度
    obj.stack_level = 3

    -- 序列化相关
    obj.log_table = true

    local max_depth = 3
    local max_ele = 5
    local max_string = 80
    local max_len = 1000
    local levels1 = 3
    local levels2 = 3
    obj.traceback = traceback_c.get_traceback(max_depth, max_ele, max_string, max_len, levels1, levels2)

    return setmetatable(obj, logger)
end

return M
