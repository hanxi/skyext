-- 日志脱敏。
-- 凭据（token / secret / password 之类）一旦进了日志就等于泄露：日志会被收集、
-- 转发、长期留存，而且往往没有访问控制。这里提供统一的判定与打码入口，
-- 让 logger 在序列化阶段就把这类值抹掉，而不是依赖每个调用点自觉。
local M = {}

M.MASK = "***REDACTED***"

-- 键名（转小写后）包含这些片段就视为凭据。
-- 注意不要放裸的 "key"：etcd 的 key 是业务数据，不是凭据。
local SENSITIVE_PATTERNS = {
    "token",
    "secret",
    "password",
    "passwd",
    "credential",
    "authorization",
    "private_key",
    "access_key",
    "session_key",
    "api_key",
    "apikey",
    "cookie",
}

local lower = string.lower
local find = string.find
local gsub = string.gsub
local sformat = string.format

--- 键名是否属于凭据类
function M.is_sensitive(key)
    if type(key) ~= "string" then
        return false
    end
    local k = lower(key)
    for i = 1, #SENSITIVE_PATTERNS do
        if find(k, SENSITIVE_PATTERNS[i], 1, true) then
            return true
        end
    end
    return false
end

--- 打码一个值。字符串保留长度，方便排障时确认"这里确实有个凭据"，
-- 但不足以还原出凭据本身。
function M.mask(value)
    if type(value) == "string" then
        return sformat("***REDACTED(len=%d)***", #value)
    end
    return M.MASK
end

-- C 版 traceback（lualib-src/traceback.c）会把每一帧的参数和 upvalue 连值一起打出来：
--   "\n\t\t<arg 1> token = \"eyJ...\""
-- 序列化时换行会被转义（见 char2escape），所以一条记录必然只占一行，可以按行打码。
-- 前缀里的 \n 用可选匹配，兼容记录正好出现在字符串开头的情况。
local TRACEBACK_PATTERN = "(\n?\t\t)<(arg %d+)> ([%w_]+) = ([^\n]*)"
local TRACEBACK_UPVALUE_PATTERN = "(\n?\t\t)<(upvalue %d+)> ([%w_]+) = ([^\n]*)"

local function mask_record(prefix, kind, name)
    return prefix .. "<" .. kind .. "> " .. name .. " = " .. M.MASK
end

--- 抹掉 traceback 里凭据类的 arg/upvalue 取值
function M.filter_traceback(s)
    if type(s) ~= "string" then
        return s
    end
    local function replace(prefix, kind, name)
        if M.is_sensitive(name) then
            return mask_record(prefix, kind, name)
        end
        -- 返回 nil 表示保留原文
    end
    s = gsub(s, TRACEBACK_PATTERN, replace)
    return (gsub(s, TRACEBACK_UPVALUE_PATTERN, replace))
end

return M
