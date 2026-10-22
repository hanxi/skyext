local skynet = require "skynet"
local sproto_api = require "skyext.sproto_api"
local cmd_api = require "skyext.cmd_api"
local socket = require "skynet.socket"
local config = require "skyext.config"
local log = require "skyext.log"
local httpc = require "skyext.httpc"
local cjson = require "cjson.safe"
local errcode = require "errcode"

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

-- 拿登录 token。示例走 Account 的开发登录接口；正式客户端从 SDK/平台登录服务拿
local function fetch_token(account_host, account)
    local status, res = httpc.post_json(account_host, "/dev_login", { account = account })
    if status ~= 200 or type(res) ~= "table" or res.code ~= errcode.OK then
        log.error("dev_login failed", "status", status, "res", res)
        return nil
    end
    -- token 是登录凭据，只能记录长度这类非敏感信息
    log.info("got login token", "len", #res.token)
    return res.token
end

-- 机器人按编号错开起点，再依次试到第一个连得上的 gate。
-- 连哪个 gate 都能进游戏（gate 只管会话，上行包转发到角色实体所在节点），
-- 所以只起了部分节点时不该因为"轮到"的那个没开就失败
local function connect_gate(gate_addrs, start)
    local count = #gate_addrs
    for i = 0, count - 1 do
        local gate = gate_addrs[(start + i - 1) % count + 1]
        local fd, err = socket.open(gate.ip, gate.port)
        if fd then
            log.info("connected to gate", "ip", gate.ip, "port", gate.port)
            return fd
        end
        log.warn("gate unreachable", "ip", gate.ip, "port", gate.port, "err", err)
    end
end

-- 登录后走一遍背包和邮件：给自己发一封信，等可靠消息投递完再看邮箱
local function play(rid)
    log.info("login_info response", "ret", call("role.login_info"))
    log.info("bag", "ret", call("bag.get_bag"))
    log.info("send mail", "ret", call("mail.send", { to_rid = rid, title = "hello", content = "mail to myself" }))
    skynet.sleep(100)
    log.info("mail list", "ret", call("mail.list"))
    -- 排行榜每 2 秒刷新一次排名，等一轮再看
    log.info("rank submit", "ret", call("rank.submit", { score = rid % 1000 }))
    skynet.sleep(300)
    log.info("rank top", "ret", call("rank.top", { count = 5 }))
end

function CMD.start(conf)
    -- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的是 nil，
    -- 所以 account_host 和 gate_addrs 都要在这里取
    local account_host = config.get("account_host")
    local gate_addrs = assert(config.get_table("gate_addrs"), "gate_addrs is not configured")
    local account = "robot" .. conf.id
    local token = fetch_token(account_host, account)
    if not token then
        return
    end

    -- 服务器列表不需要登录；没有角色时在推荐服建角
    local server = "s1"
    local list_status, list = httpc.get(account_host, "/servers")
    local servers = list_status == 200 and cjson.decode(list)
    for _, entry in ipairs(servers and servers.servers or {}) do
        if entry.recommended then
            server = entry.server
        end
    end
    log.info("server list", "servers", servers and servers.servers, "pick", server)

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
            server = server,
            name = account,
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
    local fd = connect_gate(gate_addrs, conf.gate or (conf.id % #gate_addrs + 1))
    if not fd then
        log.error("no gate is reachable", "gate_addrs", gate_addrs)
        return
    end
    g_fd = fd

    local param = {
        token = token,
        rid = role.rid,
        -- 登录时报的是角色的出生服
        server = role.server,
        proto_checksum = sproto_api.get_sproto_info().checksum,
    }
    local ret = call("login.login", param)
    log.info("login response", "ret", ret)
    if not ret or ret.code ~= errcode.OK then
        return
    end
    play(role.rid)
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
                local v
                v, last = recv_package(last)
                if not v then
                    log.error("socket read", "err", last)
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
