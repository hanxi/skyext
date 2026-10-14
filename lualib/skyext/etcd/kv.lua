--[[
etcd 的 KV 操作：读写、目录（前缀）读写、事务。

调用方传的是不带前缀的相对 key，本模块负责加上客户端配置的 key_prefix 再编码。
内部函数一律接收已经拼好前缀的完整 key。
]]

local codec = require "skyext.etcd.codec"
local transport = require "skyext.etcd.transport"

local M = { methods = {} }

local URL_PUT = "/v3/kv/put"
local URL_RANGE = "/v3/kv/range"
local URL_DELETERANGE = "/v3/kv/deleterange"
local URL_TXN = "/v3/kv/txn"

local RANGE_FIELDS = {
    "limit",
    "revision",
    "sort_order",
    "sort_target",
    "serializable",
    "keys_only",
    "count_only",
    "min_mod_revision",
    "max_mod_revision",
    "min_create_revision",
    "max_create_revision",
}

local function full_key(self, key)
    local ok, err = codec.verify_key(key)
    if not ok then
        return nil, err
    end
    return codec.real_key(self.key_prefix, key)
end

local function range(self, key, opts)
    local body = { key = codec.encode_base64(key) }
    for _, field in ipairs(RANGE_FIELDS) do
        body[field] = opts[field]
    end
    if opts.range_end then
        body.range_end = codec.encode_base64(opts.range_end)
    end

    local res, err = transport.post(self, URL_RANGE, body, opts.timeout or self.timeout)
    if res and res.status == 200 and type(res.body) == "table" then
        codec.decode_kvs(res.body.kvs)
    end
    return res, err
end

local function delete_range(self, key, opts)
    local body = {
        key = codec.encode_base64(key),
        range_end = opts.range_end and codec.encode_base64(opts.range_end) or nil,
        prev_kv = opts.prev_kv,
    }
    return transport.post(self, URL_DELETERANGE, body, opts.timeout or self.timeout)
end

local function txn(self, compare, success, failure, opts)
    if not compare or #compare < 1 then
        return nil, "compare couldn't be empty"
    end
    if (success == nil or #success < 1) and (failure == nil or #failure < 1) then
        return nil, "success and failure couldn't be empty at the same time"
    end
    local body = { compare = compare, success = success, failure = failure }
    return transport.post(self, URL_TXN, body, (opts and opts.timeout) or self.timeout)
end

local function shallow_copy(t)
    local out = {}
    for k, v in pairs(t) do
        out[k] = v
    end
    return out
end

local function encode_compare(self, rule)
    local key, err = full_key(self, rule.key)
    if not key then
        return nil, err
    end
    local out = shallow_copy(rule)
    out.key = codec.encode_base64(key)
    if rule.value ~= nil then
        out.value, err = codec.encode_value(rule.value)
        if not out.value then
            return nil, "failed to encode value: " .. err
        end
    end
    return out
end

-- 事务分支里的三种请求都要把 key 换成带前缀的 base64，requestPut 另外要编码 value
local function encode_op(self, rule)
    local out = shallow_copy(rule)
    for _, name in ipairs({ "requestPut", "requestRange", "requestDeleteRange" }) do
        local req = rule[name]
        if req then
            local key, err = full_key(self, req.key)
            if not key then
                return nil, err
            end
            local encoded = shallow_copy(req)
            encoded.key = codec.encode_base64(key)
            if name == "requestPut" then
                encoded.value, err = codec.encode_value(req.value)
                if not encoded.value then
                    return nil, "failed to encode value: " .. err
                end
            end
            out[name] = encoded
        end
    end
    return out
end

local function encode_branch(self, rules, encode)
    if not rules then
        return nil
    end
    local out = {}
    for i, rule in ipairs(rules) do
        local encoded, err = encode(self, rule)
        if not encoded then
            return nil, err
        end
        out[i] = encoded
    end
    return out
end

function M.methods.get(self, key, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end
    return range(self, real, {
        timeout = opts and opts.timeout,
        revision = opts and opts.revision,
    })
end

function M.methods.readdir(self, key, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end
    opts = opts or {}
    return range(self, real, {
        range_end = codec.range_end(real),
        revision = opts.revision,
        timeout = opts.timeout,
        limit = opts.limit,
        sort_order = opts.sort_order,
        sort_target = opts.sort_target,
        keys_only = opts.keys_only,
        count_only = opts.count_only,
    })
end

function M.methods.set(self, key, val, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end

    local value
    value, err = codec.encode_value(val)
    if not value then
        return nil, "failed to encode value: " .. err
    end

    opts = opts or {}
    local body = {
        key = codec.encode_base64(real),
        value = value,
        lease = opts.lease,
        prev_kv = opts.prev_kv,
        ignore_value = opts.ignore_value,
        ignore_lease = opts.ignore_lease,
    }
    return transport.post(self, URL_PUT, body, opts.timeout or self.timeout)
end

-- key 不存在时才写入（原子创建）
function M.methods.setnx(self, key, val, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end

    local value
    value, err = codec.encode_value(val)
    if not value then
        return nil, "failed to encode value: " .. err
    end

    local encoded = codec.encode_base64(real)
    local compare = { { target = "CREATE", key = encoded, create_revision = 0 } }
    local success = { { requestPut = { key = encoded, value = value, lease = opts and opts.lease } } }
    return txn(self, compare, success, nil, opts)
end

-- key 已存在时才写入（更新）
function M.methods.setx(self, key, val, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end

    local value
    value, err = codec.encode_value(val)
    if not value then
        return nil, "failed to encode value: " .. err
    end

    local encoded = codec.encode_base64(real)
    local compare = { { target = "CREATE", key = encoded, create_revision = 0 } }
    local failure = { { requestPut = { key = encoded, value = value, lease = opts and opts.lease } } }
    return txn(self, compare, nil, failure, opts)
end

-- 乐观锁写入：key 的 mod_revision 与预期一致时才写入
function M.methods.mod(self, key, val, opts)
    if not opts or opts.mod_revision == nil then
        return nil, "mod needs mod_revision"
    end

    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end

    local value
    value, err = codec.encode_value(val)
    if not value then
        return nil, "failed to encode value: " .. err
    end

    local encoded = codec.encode_base64(real)
    local compare = { { target = "MOD", key = encoded, mod_revision = opts.mod_revision } }
    local success = { { requestPut = { key = encoded, value = value, lease = opts.lease } } }
    return txn(self, compare, success, nil, opts)
end

function M.methods.txn(self, compare, success, failure, opts)
    local encoded_compare, err = encode_branch(self, compare, encode_compare)
    if compare and not encoded_compare then
        return nil, err
    end

    local encoded_success
    encoded_success, err = encode_branch(self, success, encode_op)
    if success and not encoded_success then
        return nil, err
    end

    local encoded_failure
    encoded_failure, err = encode_branch(self, failure, encode_op)
    if failure and not encoded_failure then
        return nil, err
    end

    return txn(self, encoded_compare, encoded_success, encoded_failure, opts)
end

function M.methods.delete(self, key, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end
    return delete_range(self, real, {
        timeout = opts and opts.timeout,
        prev_kv = opts and opts.prev_kv,
    })
end

function M.methods.rmdir(self, key, opts)
    local real, err = full_key(self, key)
    if not real then
        return nil, err
    end
    return delete_range(self, real, {
        range_end = codec.range_end(real),
        timeout = opts and opts.timeout,
        prev_kv = opts and opts.prev_kv,
    })
end

return M
