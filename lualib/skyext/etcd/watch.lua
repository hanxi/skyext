--[[
etcd 的 watch。

watch 走 HTTP chunked 流：请求发出去之后连接一直开着，etcd 每有一批事件就推一个
JSON chunk。返回的对象是可调用的，每调用一次读一批事件；用完必须关闭，
配合 `local w <close> = cli:watchdir(...)` 让 to-be-closed 变量自动收尾。
]]

local codec = require "skyext.etcd.codec"
local log = require "skyext.log"
local transport = require "skyext.etcd.transport"

local M = { methods = {} }

local URL_WATCH = "/v3/watch"

local function decode_events(events)
    for _, ev in ipairs(events) do
        ev.kv.key = codec.decode_base64(ev.kv.key)
        -- DELETE 事件没有 value
        ev.kv.value = codec.decode_value(ev.kv.value)
        ev.type = ev.type or "PUT"
        if ev.prev_kv then
            ev.prev_kv.key = codec.decode_base64(ev.prev_kv.key)
            ev.prev_kv.value = codec.decode_value(ev.prev_kv.value)
        end
    end
end

local watch_mt = {
    __call = function(self)
        local stream = self.stream
        if not stream then
            return nil, "stream not initialized"
        end

        local resp = stream()
        if stream.status ~= 200 then
            log.warn("etcd watch response failed", "status", stream.status, "resp", resp)
            return nil, stream.status
        end

        local body = codec.decode_json(resp)
        if not body then
            log.error("etcd watch decode failed", "resp", resp)
            transport.report_failure(self.cli, self.endpoint.http_host)
            return nil, "decode json failed"
        end

        if body.error then
            log.warn("etcd watch returned error", "err", body.error)
            return nil, body.error, stream
        end

        local events = body.result and body.result.events
        if events then
            decode_events(events)
        end
        return body, nil, stream
    end,
    __close = function(self)
        if self.stream then
            self.stream:close()
            self.stream = nil
        end
    end,
}

local WATCH_FIELDS = {
    "prev_kv",
    "start_revision",
    "watch_id",
    "progress_notify",
    "fragment",
    "filters",
}

local function watch(self, key, opts, range_end)
    if type(key) ~= "string" then
        return nil, "key must be string"
    end
    -- 空 key 在 etcd 里表示整个 keyspace 的起点
    local real = #key == 0 and string.char(0) or codec.real_key(self.key_prefix, key)

    local create_request = {
        key = codec.encode_base64(real),
        range_end = range_end and codec.encode_base64(range_end) or nil,
    }
    for _, field in ipairs(WATCH_FIELDS) do
        create_request[field] = opts[field]
    end

    local stream, err =
        transport.post_stream(self, URL_WATCH, { create_request = create_request }, opts.timeout or self.timeout)
    if not stream then
        -- 返回一个可关闭的空壳：调用方用的是 <close> 变量，给 nil 会在作用域结束时报错
        return setmetatable({}, watch_mt), err
    end
    return setmetatable(stream, watch_mt)
end

function M.methods.watch(self, key, opts)
    return watch(self, key, opts or {}, nil)
end

function M.methods.watchdir(self, key, opts)
    local real = codec.real_key(self.key_prefix, key)
    return watch(self, key, opts or {}, codec.range_end(real))
end

return M
