local skynet = require "skynet"
local sproto_api = require "sproto_api"
local cmd_api = require "cmd_api"
local socket = require "skynet.socket"
local config = require "config"
local log = require "log"
local jwt = require "jwt"
local httpc = require "httpc"
local cjson = require "cjson.safe"
local errcode = require "errcode"

local CMD = {}
local g_fd = nil

local g_session = 0

local login_jwt_secret = config.get("login_jwt_secret")
local gate_nodes = config.get_table("gate_nodes")

local function new_session()
    g_session = g_session + 1
    return g_session
end

local function call(name, param)
    local ret = sproto_api.call(g_fd, name, param, new_session())
    return ret
end

function CMD.start(conf)
    local data = {
        account = "robot3",
    }
    local token = jwt.sign(data, login_jwt_secret, "HS512", 60)
    log.info("generate token", "token", token)

    local account_host = config.get("account_host")
    local status, body = httpc.get(account_host, "/roles?token=" .. token)
    if status ~= 200 then
        log.error("failed to get roles", "status", status, "body", body)
        return
    end
    local res = cjson.decode(body)
    if res.code ~= errcode.OK then
        log.error("failed to get roles", "res", res)
        return
    end

    local roles = res.roles
    if #roles == 0 then
        local req = {
            token = token,
            server = "s1",
            name = "robot3",
        }
        local status, res = httpc.post_json(account_host, "/create_role", req)
        if status ~= 200 then
            log.error("failed to create role", "status", status, "res", res)
            return
        end
        if res.code ~= errcode.OK then
            log.error("failed to create role", "res", res)
            return
        end
        roles = { res.role }
    end

    if #roles == 0 then
        log.error("no roles available")
        return
    end

    local role = roles[1]
    local rolenode = role.rolenode
    local gate_ip = gate_nodes[rolenode].ip
    local gate_port = gate_nodes[rolenode].port
    local fd, err = socket.open(gate_ip, gate_port)
    if not fd then
        log.error("failed to connect to gate", "err", err)
        return
    end
    g_fd = fd
    log.info("connected to gate", "ip", gate_ip, "port", gate_port)

    local param = {
        token = token,
        rid = role.rid,
        server = "s1",
        proto_checksum = sproto_api.get_sproto_info().checksum,
    }
    local ret = call("login.login", param)
    log.info("login response", "ret", ret)
    local ret = call("role.login_info")
    log.info("login_info response", "ret", ret)
end

local function unpack_package(text)
    local size = #text
    if size < 2 then
        return nil, text
    end
    local s = text:byte(1) * 256 + text:byte(2)
    if size < s + 2 then
        return nil, text
    end

    return text:sub(3, 2 + s), text:sub(3 + s)
end

local function recv_package(last)
    local result
    result, last = unpack_package(last)
    if result then
        return result, last
    end
    local r = socket.read(g_fd)
    if not r then
        return nil, last
    end
    if r == "" then
        error "Server closed"
    end
    return recv_package(last .. r)
end

skynet.start(function()
    cmd_api.dispatch(CMD)
    skynet.fork(function()
        local host = sproto_api.get_sproto_host()
        local last = ""
        while true do
            if g_fd then
                v, last = recv_package(last)
                if not v then
                    log.error("socket read error:", sz)
                    break
                end
                local type, request_name, request, response_cb = host:dispatch(v)
                if type then
                    local ret = sproto_api.raw_dispatch(g_fd, type, request_name, request, response_cb)
                    if ret then
                        log.debug("dispatched message response", "ret", ret)
                    end
                else
                    log.error("failed to dispatch message")
                end
            end
            skynet.sleep(10) -- Sleep to avoid busy loop
        end
    end)
end)
