local skynet = require "skynet"
local global = require "global"
local user_db_api = require "user_db_api"
local client = require "client"
local roleagent_api = require "roleagent_api"
local errcode = require "errcode"
local config = require "config"
local log = require "log"
local jwt = require "jwt"
local sproto_api = require "sproto_api"

local M = {}

local login_jwt_secret = config.get("login_jwt_secret")
local proto_checksum_enable = config.get_boolean("proto_checksum_enable")
local server2game = config.get_table("server2game")

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

local function load_bind_rold(fd, rid)
    -- TODO: use timeout call
    local agent_addr = roleagent_api.calc_agent_addr(rid)
    local code, rolenode = skynet.call(agent_addr, "lua", "load_bind_role", rid, fd)
    if code ~= 0 then
        log.warn("load_bind_role failed", "rid", rid, "fd", fd, "code", code)
        return {
            code = code,
            rolenode = rolenode,
        }
    end

    -- 跟 login 解绑
    client.unbind(fd)

    log.info("load_bind_role success", "rid", rid, "fd", fd)

    -- 绑定成功后，后面的消息会转发到roleagent
    return {
        code = errcode.OK,
        rid = rid,
    }
end

function M:login(fd, client_obj)
    local data, err = jwt.verify(self.token, login_jwt_secret)
    if not data then
        log.warn("jwt failed", "err", err, "token", self.token)
        return {
            code = errcode.TOKEN_ERROR,
        }
    end

    local account = data.account
    if proto_checksum_enable then
        -- 协议不一致不允许登录
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
    -- 如果是首次进来，会创建用户 user
    local user = user_db_api.ensure_get_user(account)
    if not user then
        log.warn("login ensure_get_user failed", "account", account)
        return {
            code = errcode.DB_ERROR,
        }
    end

    local rid = self.rid
    if (not rid) or (rid <= 0) then
        log.warn("login rid not exist", "account", account)
        return {
            code = errcode.ROLE_NOT_EXIST,
        }
    end

    -- 检查服务器是否存在
    local server = self.server
    if not server2game[server] then
        return {
            code = errcode.SERVER_NOT_EXIST,
        }
    end
    -- 加载 role 并 绑定 fd
    return load_bind_rold(fd, rid)
end

function M:logout(fd, client_obj)
    log.info("logout", "fd", fd)
    skynet.call(global.watchdog_service, "lua", "close_client", fd)
end

return M
