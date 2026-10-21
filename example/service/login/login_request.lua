local client = require "client"
local router = require "skyext.entity.router"
local errcode = require "errcode"
local config = require "skyext.config"
local log = require "skyext.log"
local jwt = require "jwt"
local sproto_api = require "skyext.sproto_api"
local role_db_api = require "role_db_api"
local realm = require "skyext.realm"

local M = {}

-- 配置是在 skyext 的 skynet.init 回调里注入的，本文件被服务 chunk 在加载期 require 到，
-- 顶层读取只会拿到 nil 并把它永久缓存下来，因此统一改成惰性读取
local g_self_node
local function self_node()
    if not g_self_node then
        g_self_node = assert(config.get("cluster_node_name"), "cluster_node_name is not configured")
    end
    return g_self_node
end

local g_proto_checksum_enable
local function proto_checksum_enable()
    if g_proto_checksum_enable == nil then
        g_proto_checksum_enable = config.get_boolean("proto_checksum_enable") or false
    end
    return g_proto_checksum_enable
end

-- 网关/代理上报客户端的真实连接地址。直连时 gate 的 open 已带 peer addr，
-- 这条主要给 goscon 之类代理场景补上真实 IP；当前仅用于登录期的可观测日志。
function M:report_remote_addr(fd)
    log.info("report_remote_addr", "fd", fd, "remote_addr", self.remote_addr, "local_addr", self.local_addr)
end

-- 把会话绑到角色实体上。实体加载在哪个节点由实体系统决定，和本 gate 在不在一个节点无关
local function load_bind_role(fd, rid)
    local code = router.bind_session("role", rid, self_node(), fd)
    if code ~= errcode.OK then
        log.warn("bind_session failed", "rid", rid, "fd", fd, "code", code)
        return { code = code }
    end

    -- 会话已经交给实体，之后的包 gate 直接转过去，登录服务不再管它
    client.unbind(fd)
    log.info("load_bind_role success", "rid", rid, "fd", fd)
    return {
        code = errcode.OK,
        rid = rid,
    }
end

function M:login(fd)
    local data, err, kind = jwt.verify_login(self.token)
    if not data then
        if kind == "config" then
            -- 密钥不可用（没配 / 还是示例里的公开默认值）时不能放行任何登录
            log.error("login rejected, login_jwt_secret is unusable", "reason", err)
        else
            -- token 是登录凭据，不能进日志
            log.warn("jwt failed", "err", err)
        end
        return {
            code = errcode.TOKEN_ERROR,
        }
    end

    local account = data.account
    if proto_checksum_enable() then
        local proto_checksum = sproto_api.get_sproto_info().checksum
        if self.proto_checksum ~= proto_checksum then
            log.warn(
                "proto checksum failed",
                "client",
                self.proto_checksum,
                "server",
                proto_checksum,
                "account",
                account
            )
            return {
                code = errcode.PROTO_CHECKSUM,
            }
        end
    end

    log.info("login", "account", account)
    local rid = self.rid
    if (not rid) or (rid <= 0) then
        log.warn("login rid not exist", "account", account)
        return {
            code = errcode.ROLE_NOT_EXIST,
        }
    end

    local server = self.server
    if not realm.server(server) then
        return {
            code = errcode.SERVER_NOT_EXIST,
        }
    end

    if not role_db_api.has_role(rid, account, server) then
        log.warn("login role not owned by account", "account", account, "rid", rid, "server", server)
        return {
            code = errcode.ROLE_NOT_EXIST,
        }
    end

    return load_bind_role(fd, rid)
end

return M
