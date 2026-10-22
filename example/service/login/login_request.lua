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

-- 把会话绑到角色实体上。实体加载在哪个节点由实体系统决定，和本网关在不在一个节点无关
local function load_bind_role(fd, rid, gate_service)
    local code, nonce = router.bind_session("role", rid, self_node(), gate_service, fd)
    if code ~= errcode.OK then
        log.warn("bind_session failed", "rid", rid, "fd", fd, "code", code)
        return { code = code }
    end

    -- 会话已经交给实体，之后的包网关直接转过去，登录服务不再管它
    client.unbind(fd)
    log.info("load_bind_role success", "rid", rid, "fd", fd)
    return {
        code = errcode.OK,
        rid = rid,
        -- 续接凭据。断线后客户端拿它走 resume，不用重新登录
        nonce = nonce,
    }
end

function M:login(fd, obj)
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

    return load_bind_role(fd, rid, obj.gate)
end

-- 断线续接。不验 token、不查库：凭据是 nonce，它只代表一条会话、最长活到实体卸载，
-- 比代表整个账号的 access token 权限小得多。实体不在内存里就直接失败，不会去加载它。
-- 任何错误码客户端都退化成走 login
function M:resume(fd, obj)
    local rid = self.rid
    if (not rid) or (rid <= 0) then
        return { code = errcode.PARAM_ERROR }
    end
    local code, nonce, sent = router.resume_session("role", rid, self_node(), obj.gate, fd, self.nonce, self.recv)
    if code ~= errcode.OK then
        log.info("resume rejected", "rid", rid, "fd", fd, "code", code)
        return { code = code }
    end
    client.unbind(fd)
    log.info("resume success", "rid", rid, "fd", fd)
    return {
        code = errcode.OK,
        nonce = nonce,
        sent = sent,
    }
end

-- 登录阶段的心跳。这时还没有会话，计数无从谈起，回 0 就行。它之所以必须被应答，是因为
-- 客户端要靠收到 pong 才能判断连接还通着——切网络时旧连接会直接黑洞化，不产生 FIN/RST
function M.ping()
    return { sent = 0 }
end

return M
