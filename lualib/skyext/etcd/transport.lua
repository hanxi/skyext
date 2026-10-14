--[[
etcd 客户端的 HTTP 传输层：端点解析、故障摘除、请求发送。

本层不认识 etcd 的业务语义，也不直接依赖 auth：需要鉴权时调用 `self:authorize(timeout)`，
由 skyext.etcd 在构造客户端时把 auth 的实现挂上去，避免 transport 与 auth 互相 require。
]]

local httpc = require "http.httpc"
local log = require "skyext.log"
local redact = require "skyext.log.redact"
local time = require "skyext.time"
local codec = require "skyext.etcd.codec"

local M = {}

local DEFAULT_TIMEOUT = 5
local FAIL_TIMEOUT = 10 -- 端点失败后摘除的秒数
local INIT_COUNT_RESIZE = 2e8

-- http_host 形如 http://127.0.0.1:2379
local function parse_endpoint(host)
    if type(host) ~= "string" then
        return nil, "http_host must be string"
    end
    local scheme, addr = string.match(host, "^(%a[%w+.-]*)://(.+)$")
    if not scheme then
        return nil, "invalid http_host: " .. host
    end
    local hostname, port = string.match(addr, "^(.-):(%d+)/?$")
    if not hostname then
        hostname = string.match(addr, "^([^/]+)/?$")
        port = scheme == "https" and "443" or "2379"
    end
    if not hostname or hostname == "" then
        return nil, "invalid http_host: " .. host
    end
    return { http_host = host, scheme = scheme, host = hostname, port = port }
end

function M.parse_endpoints(http_host)
    local hosts = type(http_host) == "string" and { http_host } or http_host
    if type(hosts) ~= "table" or #hosts == 0 then
        return nil, "http_host is required"
    end

    local endpoints = {}
    for _, host in ipairs(hosts) do
        local endpoint, err = parse_endpoint(host)
        if not endpoint then
            return nil, err
        end
        endpoints[#endpoints + 1] = endpoint
    end
    return endpoints
end

local function ring_balancer(self)
    local endpoints = self.endpoints
    self.init_count = (self.init_count or math.random(100)) + 1
    if self.init_count >= INIT_COUNT_RESIZE then
        self.init_count = 0
    end
    return endpoints[self.init_count % #endpoints + 1]
end

local function is_healthy(self, http_host)
    local expired = self.fail_expired_time[http_host]
    return not expired or expired < time.now()
end

function M.report_failure(self, http_host)
    self.fail_expired_time[http_host] = time.now() + FAIL_TIMEOUT
    self.working_endpoint = nil
end

local function choose_endpoint(self)
    if #self.endpoints == 1 then
        return self.endpoints[1]
    end
    for _ = 1, #self.endpoints do
        local endpoint = ring_balancer(self)
        if is_healthy(self, endpoint.http_host) then
            return endpoint
        end
    end
    -- 全都在摘除期内：与其不发请求，不如挑一个试试，etcd 可能已经恢复
    return self.endpoints[1]
end

local function working_endpoint(self)
    local endpoint = self.working_endpoint
    if not endpoint then
        endpoint = choose_endpoint(self)
        self.working_endpoint = endpoint
    end
    return endpoint
end

-- 认证接口的请求体是 etcd 用户名密码，响应体就是 jwt token 本身。
-- 两者都是整段 JSON 字符串，凭据在字符串内部，按 key 脱敏救不了，只能整体打码。
local function loggable(body, ignore_auth)
    if ignore_auth then
        return redact.mask(body)
    end
    return body
end

local function prepare(self, opts)
    local body
    if opts.body and next(opts.body) then
        body = codec.encode_json(opts.body)
    end

    local headers = {}
    if self.is_auth and not opts.ignore_auth then
        local _, err = self:authorize(opts.timeout)
        if err then
            return nil, err
        end
        headers.Authorization = self.jwt_token
    end
    return { headers = headers, body = body }
end

-- httpc 的超时是模块级变量，只在请求最开始、第一次让出之前读一次，
-- 因此"赋值 → 发请求 → 还原"之间不会被其它协程读到错的值。
local function with_timeout(timeout, f, ...)
    local saved = httpc.timeout
    httpc.timeout = math.max(1, math.floor(timeout * 100))
    local ok, a, b = pcall(f, ...)
    httpc.timeout = saved
    if not ok then
        error(a, 0)
    end
    return a, b
end

local function request(self, http_host, uri, opts)
    local req, err = prepare(self, opts)
    if err then
        return nil, err
    end

    local log_req = loggable(req.body, opts.ignore_auth)
    log.debug("etcd request begin", "uri", uri, "host", http_host, "body", log_req)

    local recvheader = {}
    local status, body =
        with_timeout(opts.timeout, httpc.request, "POST", http_host, uri, recvheader, req.headers, req.body)
    local log_res = loggable(body, opts.ignore_auth)
    log.debug("etcd request end", "uri", uri, "host", http_host, "status", status, "body", log_res)

    if status >= 500 then
        log.warn("etcd request failed", "uri", uri, "host", http_host, "status", status, "body", log_res)
        return nil, "invalid response code: " .. status
    end
    if status == 401 then
        log.warn("etcd request failed", "uri", uri, "host", http_host, "status", status, "body", log_res)
        return nil, "insufficient credentials code: " .. status
    end

    if type(body) ~= "string" then
        return { status = status, headers = recvheader, body = body }
    end
    return { status = status, headers = recvheader, body = codec.decode_json(body) }
end

local function request_stream(self, http_host, uri, opts)
    local req, err = prepare(self, opts)
    if err then
        return nil, err
    end
    log.debug("etcd stream begin", "uri", uri, "host", http_host)
    return with_timeout(opts.timeout, httpc.request_stream, "POST", http_host, uri, {}, req.headers, req.body)
end

-- 返回 res, err。网络层异常（连不上、超时）记一次端点失败并摘除该端点。
function M.post(self, uri, body, timeout, ignore_auth)
    local endpoint = working_endpoint(self)
    local opts = { body = body, timeout = timeout or DEFAULT_TIMEOUT, ignore_auth = ignore_auth }

    local ok, res, err = xpcall(request, log.xpcall_msgh, self, endpoint.http_host, uri, opts)
    if not ok then
        M.report_failure(self, endpoint.http_host)
        return nil, res
    end
    return res, err
end

function M.post_stream(self, uri, body, timeout)
    local endpoint = working_endpoint(self)
    local opts = { body = body, timeout = timeout or DEFAULT_TIMEOUT }

    local ok, stream, err = xpcall(request_stream, log.xpcall_msgh, self, endpoint.http_host, uri, opts)
    if not ok then
        M.report_failure(self, endpoint.http_host)
        return nil, stream
    end
    if not stream then
        return nil, err
    end
    return { cli = self, stream = stream, endpoint = endpoint }
end

return M
