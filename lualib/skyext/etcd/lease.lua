--[[
etcd 的租约（lease）操作。

租约 ID 由 etcd 以 int64 返回，JSON 里是字符串，这里原样透传，不做数字转换：
转成 Lua number 会在超过 2^53 时丢精度，续约就会续到别的租约上去。
]]

local codec = require "skyext.etcd.codec"
local transport = require "skyext.etcd.transport"

local M = { methods = {} }

local URL_GRANT = "/v3/lease/grant"
local URL_REVOKE = "/v3/lease/revoke"
local URL_KEEPALIVE = "/v3/lease/keepalive"
local URL_TIMETOLIVE = "/v3/lease/timetolive"
local URL_LEASES = "/v3/lease/leases"

function M.methods.grant(self, ttl, id)
    if type(ttl) ~= "number" then
        return nil, "lease grant needs a numeric TTL"
    end
    return transport.post(self, URL_GRANT, { TTL = ttl, ID = id or 0 }, self.timeout)
end

function M.methods.revoke(self, id)
    if id == nil then
        return nil, "lease revoke needs ID"
    end
    return transport.post(self, URL_REVOKE, { ID = id }, self.timeout)
end

function M.methods.keepalive(self, id)
    if id == nil then
        return nil, "lease keepalive needs ID"
    end
    return transport.post(self, URL_KEEPALIVE, { ID = id }, self.timeout)
end

-- keys 为 true 时额外返回该租约绑定的全部 key
function M.methods.timetolive(self, id, keys)
    if id == nil then
        return nil, "lease timetolive needs ID"
    end

    local res, err = transport.post(self, URL_TIMETOLIVE, { ID = id, keys = keys or false }, self.timeout)
    if res and res.status == 200 and type(res.body) == "table" and res.body.keys then
        for i, key in ipairs(res.body.keys) do
            res.body.keys[i] = codec.decode_base64(key)
        end
    end
    return res, err
end

function M.methods.leases(self)
    return transport.post(self, URL_LEASES, nil, self.timeout)
end

return M
