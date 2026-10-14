--[[
etcd 的 jwt 鉴权。

etcd 默认签发 5 分钟有效期的 token，这里提前到 3 分钟刷新，并加 0~60 秒随机，
让多个 worker 的刷新时间岔开（https://github.com/etcd-io/etcd/issues/8287）。
]]

local skynet = require "skynet"
local log = require "skyext.log"
local time = require "skyext.time"
local transport = require "skyext.etcd.transport"

local M = { methods = {} }

local URL_AUTHENTICATE = "/v3/auth/authenticate"
local REFRESH_AHEAD = 60 * 3

local function token_fresh(self)
    return self.jwt_token ~= nil and time.now() - self.last_auth_time < REFRESH_AHEAD + math.random(0, 60)
end

-- 返回 true 或 nil, err。token 仍在有效期内时直接返回，不发请求。
function M.methods.authorize(self, timeout)
    timeout = timeout or self.timeout
    if token_fresh(self) then
        return true
    end

    -- 已经有协程在换 token：等它换完，不要并发打一堆认证请求
    if self.requesting_token then
        skynet.sleep(timeout * 100)
        if token_fresh(self) then
            return true
        end
        if self.last_refresh_jwt_err then
            return nil, self.last_refresh_jwt_err
        end
        log.info("etcd authorize retry after waiting", "timeout", timeout)
    end

    self.last_refresh_jwt_err = nil
    self.requesting_token = true
    local res, err =
        transport.post(self, URL_AUTHENTICATE, { name = self.user, password = self.password }, timeout, true)
    self.requesting_token = false

    if not err and not (res and res.body and res.body.token) then
        err = "authenticate refresh token failed"
    end
    if err then
        self.last_refresh_jwt_err = err
        log.warn("etcd authorize failed", "user", self.user, "err", err)
        return nil, err
    end

    self.jwt_token = res.body.token
    self.last_auth_time = time.now()
    -- token 是访问凭据，不能进日志
    log.info("etcd authorize succ", "user", self.user)
    return true
end

return M
