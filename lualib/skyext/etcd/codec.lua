--[[
etcd v3 gRPC-gateway 的编解码规则。

key 与 value 在 HTTP 网关上都必须是 base64；value 在 base64 之外再套一层 JSON，
这样存进去的是 Lua 值而不只是字符串。规则集中在这里，避免每个请求各拼各的。
]]

local cjson = require "cjson.safe"
local crypt = require "skynet.crypt"

local M = {}

M.encode_base64 = crypt.base64encode
M.decode_base64 = crypt.base64decode
M.encode_json = cjson.encode
M.decode_json = cjson.decode

function M.verify_key(key)
    if type(key) ~= "string" then
        return false, "key must be string"
    end
    if #key == 0 then
        return false, "key should not be empty"
    end
    return true
end

function M.real_key(prefix, key)
    return (type(prefix) == "string" and prefix or "") .. key
end

function M.encode_key(prefix, key)
    return M.encode_base64(M.real_key(prefix, key))
end

function M.encode_value(val)
    local data, err = M.encode_json(val)
    if not data then
        return nil, err or "failed to encode value"
    end
    return M.encode_base64(data)
end

function M.decode_value(data)
    if data == nil then
        return nil
    end
    return M.decode_json(M.decode_base64(data))
end

-- 把前缀扫描转成区间扫描：返回该前缀的上界（区间左闭右开）。
-- 做法与 etcd clientv3 的 GetPrefixRangeEnd 一致：从末尾找到第一个小于 0xff 的字节，
-- 加一后截断。直接给末字节加一在 0xff 结尾时会溢出（string.char(256) 直接报错）。
-- 全 0xff 或空 key 用 "\0" 表示"一直扫到 keyspace 末尾"。
function M.range_end(key)
    for i = #key, 1, -1 do
        local b = string.byte(key, i)
        if b < 0xff then
            return string.sub(key, 1, i - 1) .. string.char(b + 1)
        end
    end
    return string.char(0)
end

function M.decode_kvs(kvs)
    if not kvs then
        return
    end
    for _, kv in ipairs(kvs) do
        kv.key = M.decode_base64(kv.key)
        kv.value = M.decode_value(kv.value)
    end
end

return M
