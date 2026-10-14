local skynet = require "skynet"
local global = require "global"
local client = require "client"
local entity_types = require "skyext.entity.types"
local errcode = require "errcode"
local config = require "skyext.config"
local log = require "skyext.log"
local jwt = require "jwt"
local sproto_api = require "skyext.sproto_api"

local M = {}

-- 配置是在 skyext 的 skynet.init 回调里注入的，本文件被服务 chunk 在加载期 require 到，
-- 顶层读取只会拿到 nil 并把它永久缓存下来，因此统一改成惰性读取
local g_server2game
local function server2game()
    if not g_server2game then
        g_server2game = assert(config.get_table("server2game"), "server2game is not configured")
    end
    return g_server2game
end

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

function M:report_remote_addr(fd, client_obj)
    log.info("report_remote_addr", "fd", fd, "remote_addr", self.remote_addr, "local_addr", self.local_addr)
    if not client_obj then
        log.error(
            "report_remote_addr client not found",
            "fd",
            fd,
            "remote_addr",
            self.remote_addr,
            "local_addr",
            self.local_addr
        )
        return
    end
    client_obj.addr = self.remote_addr
end

local function load_bind_role(fd, rid)
    local target_node = entity_types.calc_node("role", rid)
    if target_node ~= self_node() then
        return {
            code = errcode.NOT_THIS_NODE,
            rolenode = target_node,
        }
    end

    local agent_index = entity_types.calc_agent_index("role", rid)
    local agent_name = entity_types.format_agent_service_name("role", agent_index)

    local code = skynet.call(agent_name, "lua", "bind_client", rid, fd)
    if code ~= errcode.OK then
        log.warn("bind_client failed", "rid", rid, "fd", fd, "code", code)
        return { code = code }
    end

    client.unbind(fd)
    log.info("load_bind_role success", "rid", rid, "fd", fd)
    return {
        code = errcode.OK,
        rid = rid,
    }
end

function M:login(fd, client_obj)
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
    if not server2game()[server] then
        return {
            code = errcode.SERVER_NOT_EXIST,
        }
    end

    return load_bind_role(fd, rid)
end

function M:logout(fd, client_obj)
    log.info("logout", "fd", fd)
    skynet.call(global.watchdog_service, "lua", "close_client", fd)
end

return M
