local time = require "skyext.time"
local util_table = require "skyext.util.table"
local bucket = require "skyext.log.bucket"
local log_level = require "skyext.log.log_level"
local redact = require "skyext.log.redact"
local traceback_c = require "traceback.c"

local type = type
local error = error
local pairs = pairs
local assert = assert
local select = select
local tostring = tostring
local setmetatable = setmetatable

local sformat = string.format
local supper = string.upper
local tpack = table.pack
local tunpack = table.unpack

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
        -- 表里的凭据字段（token/secret/password 等）在序列化阶段就打码
        return util_table.tostring(s, redact)
    end
    return s
end

--  结构化日志
function logger:_pack_events(level, ...)
    local n = select("#", ...)
    assert(n % 2 == 0, "log args not even, must be key-value pairs")
    local values = { ... }
    -- 键名命中凭据词时，值不进日志（在序列化之前替换掉，顺带省下展开大对象的开销）
    for i = 1, n, 2 do
        if redact.is_sensitive(values[i]) then
            values[i + 1] = redact.mask(values[i + 1])
        end
    end
    for i = 1, n do
        values[i] = tostring(self:_serialize(level, values[i]))
    end

    local events = {}
    -- 这些 key 由日志记录本身占用（json 输出中时间戳字段名为 time），事件重名时自动加后缀
    local events_key_cnt = {
        module = 1,
        level = 1,
        timestamp = 1,
        time = 1,
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
    -- msg 最终要进 json/text 两种 formatter，非字符串在 json 编码时会整条丢掉，
    -- 这里统一归一化（表走 _serialize，顺带脱敏）
    msg = tostring(self:_serialize(level, msg))
    local timestamp = time.time()
    local src = ""
    if self.log_src then
        src = get_log_src(self.stack_level + stack_depth) or ""
    end
    local modname = self.name
    save_to_bucket(modname, level, timestamp, src, msg, events)
end

--- 判断某个级别的日志是否会被输出
-- 调用方可以用它跳过昂贵的日志参数准备（堆栈回溯、序列化等）
function logger:is_enabled(level)
    return level <= self.level
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

function logger:error(msg, ...)
    -- 被级别过滤时不要付出抓取堆栈的代价
    if not self:is_enabled(ERROR) then
        return
    end
    -- traceback 会把每帧的 arg/upvalue 连值一起打出来，其中可能有凭据
    local tcb = redact.filter_traceback(self.traceback(nil, 2))
    -- traceback 追加在调用方 kv 之后：它体积最大，排在前面会把有用字段挤到视线外。
    -- 这里的 pack/unpack 开销远小于刚刚抓的那次堆栈。
    local args = tpack(...)
    local n = args.n
    args[n + 1] = "traceback"
    args[n + 2] = tcb
    return self:_log(ERROR, ext_stack_depth, msg, tunpack(args, 1, n + 2))
end

local function log_traceback(self, log_lv, stack_depth, err_type, err_msg)
    if not self:is_enabled(log_lv) then
        return
    end
    local tcb = redact.filter_traceback(self.traceback(nil, stack_depth + 1))
    -- msg 位置放真正的错误信息，而不是 "stack traceback" 这种固定串，
    -- 否则日志检索只能看到千篇一律的标题
    return self:_log(log_lv, stack_depth, err_msg, "err_type", err_type, "traceback", tcb)
end

local do_error_stack_depth = 1
-- 避免 log_traceback 自身抛错时无限递归
local logging_traceback = false
local reset_logging_traceback = setmetatable({}, {
    __close = function()
        logging_traceback = false
    end,
})
local function do_error(self, err_type, err_msg, err_lv)
    if not logging_traceback then
        logging_traceback = true
        local _ <close> = reset_logging_traceback
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

-- 合法的日志级别数值集合，用于配置校验
local level_names = {}
for name, value in pairs(log_level) do
    level_names[value] = name
end

--- 把配置里的日志级别归一化成内部数值
-- 同时接受数值（如 app 配置中的 log_level = 4）与名字（如 "INFO"）
local function coerce_level(v)
    local tv = type(v)
    if tv == "number" then
        if level_names[v] then
            return v
        end
    elseif tv == "string" then
        local level = log_level[supper(v)]
        if level then
            return level
        end
    end
    error(sformat("invalid value: %s for config: level", tostring(v)))
end

-- 配置字段类型约束：coerce 用于归一化与校验，type 为 lua 类型名
-- field 代表映射到config中代表的字段
local config_constraint = {
    name = { type = "string" },
    level = { coerce = coerce_level },
    log_src = { type = "boolean" },
    log_table = { type = "boolean" },
    stack_level = { type = "number" },
    traceback = { type = "function" },
}

function logger:config(t)
    assert(type(t) == "table", "log config must be a table")
    -- 检查配置字段约束
    for f, v in pairs(t) do
        local c = assert(config_constraint[f], "invalid config field: " .. tostring(f))
        if c.coerce then
            v = c.coerce(v)
        elseif type(v) ~= c.type then
            error(sformat("type mismatch for field: %s, expect %s, got %s", f, c.type, type(v)))
        end
        self[f] = v
    end
end

function M.new()
    local obj = {}
    -- 单 vm 内 SERVICE_ARGS 作为全局变量读取。
    obj.name = SERVICE_ARGS or "skyext"

    -- 默认 INFO：DEBUG 会把每次数据库读写、每条协议消息都刷进日志，
    -- 误用默认值就是磁盘和性能事故。需要调试时显式配置 log_level。
    obj.level = log_level.INFO
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
