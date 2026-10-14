--[[
etcd v3 客户端（走 HTTP gRPC-gateway）。

按职责拆成几个模块，这里只负责构造客户端并把各模块的方法聚合到同一张方法表：
  codec      key/value 的 base64 与 JSON 编解码
  transport  端点解析、故障摘除、请求发送
  auth       jwt 鉴权
  kv         读写、目录读写、事务
  lease      租约
  watch      事件流

用法：
  local etcd = require "skyext.etcd"
  local cli = assert(etcd.new({ http_host = { "http://127.0.0.1:2379" } }))
  cli:set("foo", { a = 1 })
  local res = cli:get("foo")
]]

local time = require "skyext.time"
local transport = require "skyext.etcd.transport"

local M = {}

local methods = {}
local mt = { __index = methods }

for _, name in ipairs({ "auth", "kv", "lease", "watch" }) do
    local mod = require("skyext.etcd." .. name)
    for method, fn in pairs(mod.methods) do
        assert(methods[method] == nil, "duplicate etcd method: " .. method)
        methods[method] = fn
    end
end

-- opts: http_host（字符串或字符串数组）、user、password、timeout（秒）、key_prefix
function M.new(opts)
    opts = opts or {}

    local endpoints, err = transport.parse_endpoints(opts.http_host)
    if not endpoints then
        return nil, err
    end

    return setmetatable({
        endpoints = endpoints,
        working_endpoint = nil,
        fail_expired_time = {},
        timeout = opts.timeout or 5,
        key_prefix = opts.key_prefix or "",

        is_auth = not not (opts.user and opts.password),
        user = opts.user,
        password = opts.password,
        jwt_token = nil,
        last_auth_time = time.now(),
        last_refresh_jwt_err = nil,
        requesting_token = false,
    }, mt)
end

return M
