local skynet = require "skynet"
local sproto_api = require "sproto_api"
local cmd_api = require "cmd_api"
local socket = require "skynet.socket"
local config = require "config"
local log = require "log"

local CMD = {}
local g_fd = nil

local g_session = 0

local function new_session()
    g_session = g_session + 1
    return g_session
end

local function call(name, param)
    local ret = sproto_api.call(g_fd, name, param, new_session())
    return ret
end

function CMD.start(conf)
    log.info("roleagent start", "id", conf.id, "name", conf.name)
    local gate_ip = config.get("gate_ip")
    local gate_port = config.get_number("gate_port")
    local fd, err = socket.open(gate_ip, gate_port)
    if not fd then
        log.error("failed to connect to gate", "err", err)
        return
    end
    g_fd = fd
    log.info("connected to gate", "ip", gate_ip, "port", gate_port)

    local param = {
        token = "robot",
        ctx = {
            proto_checksum = sproto_api.get_sproto_info().checksum,
        },
    }
    local ret = call("login.login", param)
    log.info("login response", "ret", ret)

    local ret = call("login.get_roles")
    log.info("get roles response", "ret", ret)
    if ret.roles and #ret.roles > 0 then
        log.info("choosing role", "role", ret.roles[1])
        local param = {
            rid = ret.roles[1].rid,
        }
        local ret = call("login.choose_role", param)
        log.info("choose role response", "ret", ret)
    else
        log.info("no roles available")
        call("login.create_role", {
            name = "robot_" .. skynet.self(),
        })
    end
    call("role.login_info")
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
