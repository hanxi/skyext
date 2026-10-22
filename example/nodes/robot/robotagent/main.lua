-- 压测/连通性机器人。它同时是 example/lualib/client_session.lua 的验收用例：
-- 同一套业务流程在 tcp 和 ws 两种传输上各跑一遍，行为必须完全一致；
-- 中间主动断一次连接，验证续接之后业务能接着做、且不用重新登录。
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local log = require "skyext.log"
local httpc = require "skyext.httpc"
local cjson = require "cjson.safe"
local errcode = require "errcode"
local sproto_api = require "skyext.sproto_api"
local client_session = require "client_session"

local CMD = {}

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

-- 服务器列表不需要登录。没有角色时在推荐服建角
local function pick_server(account_host)
    local status, body = httpc.get(account_host, "/servers")
    local servers = status == 200 and cjson.decode(body)
    local pick = "s1"
    for _, entry in ipairs(servers and servers.servers or {}) do
        if entry.recommended then
            pick = entry.server
        end
    end
    log.info("server list", "servers", servers and servers.servers, "pick", pick)
    return pick
end

-- 网关地址来自 account 的 /gates，不写死在配置里。正式客户端走的就是这条路径：
-- 先查列表再直连其中一台，数据路径上没有代理。列表里只会有真的在线的网关
-- （网关键挂在节点租约上），所以也不用自己判断某个端口通不通
local function fetch_gates(account_host)
    local status, body = httpc.get(account_host, "/gates")
    local res = status == 200 and cjson.decode(body)
    if type(res) ~= "table" or res.code ~= errcode.OK or not res.gates[1] then
        log.error("no gate is online", "status", status, "res", res)
        return nil
    end
    log.info("gate list", "gates", res.gates)
    return res.gates
end

-- 登录 token 走 Authorization 头。放进 URL query 会被访问日志、代理日志、
-- Referer 和浏览器历史一路抄送
local function authed(method, account_host, url, token, body)
    local header = { authorization = "Bearer " .. token }
    local data
    if body then
        header["content-type"] = "application/json"
        data = cjson.encode(body)
    end
    local status, res = httpc.request(method, account_host, url, nil, header, data)
    return status, cjson.decode(res) or res
end

local function ensure_role(account_host, token, account, server)
    local status, res = authed("GET", account_host, "/roles", token)
    if status ~= 200 or res.code ~= errcode.OK then
        log.error("failed to get roles", "status", status, "res", res)
        return nil
    end
    if res.roles[1] then
        return res.roles[1]
    end

    local create_status, created =
        authed("POST", account_host, "/create_role", token, { server = server, name = account })
    if create_status ~= 200 or created.code ~= errcode.OK then
        log.error("failed to create role", "status", create_status, "res", created)
        return nil
    end
    return created.role
end

-- 走一遍背包和邮件：给自己发一封信，等可靠消息投递完再看邮箱
local function play(s, rid)
    log.info("login_info response", "ret", s:call("role.login_info"))
    log.info("bag", "ret", s:call("bag.get_bag"))
    log.info("send mail", "ret", s:call("mail.send", { to_rid = rid, title = "hello", content = "mail to myself" }))
    skynet.sleep(100)
    log.info("mail list", "ret", s:call("mail.list"))
    -- 排行榜每 2 秒刷新一次排名，等一轮再看
    log.info("rank submit", "ret", s:call("rank.submit", { score = rid % 1000 }))
    skynet.sleep(300)
    log.info("rank top", "ret", s:call("rank.top", { count = 5 }))
end

-- 续接验收：断掉当前连接，重连协程应该用 nonce 续上同一个会话，
-- 凭据轮换、下行计数接着数，业务不用重新登录
local function check_resume(s)
    local before = { nonce = s.nonce, recv = s.recv }
    s:reconnect()
    for _ = 1, 100 do
        if s.online then
            break
        end
        skynet.sleep(10)
    end
    if not s.online then
        log.error("resume check failed: still offline")
        return false
    end
    if s.nonce == before.nonce then
        log.error("resume check failed: credential was not rotated")
        return false
    end
    if s.recv < before.recv then
        log.error("resume check failed: downstream count went backwards", "before", before.recv, "after", s.recv)
        return false
    end
    log.info("resumed", "recv_before", before.recv, "recv_after", s.recv)
    return s:call("role.login_info") ~= nil
end

local function run(transport, gate, role, token)
    if transport == "ws" and not gate.ws_url then
        log.warn("gate has no websocket port, skipping the ws run", "gate", gate.node)
        return true
    end
    local host, port = gate.tcp_addr:match("^(.+):(%d+)$")
    local conf = {
        transport = transport,
        host = host,
        port = tonumber(port),
        url = gate.ws_url,
        login_param = function()
            return {
                token = token,
                rid = role.rid,
                -- 登录时报的是角色的出生服
                server = role.server,
                proto_checksum = sproto_api.get_sproto_info().checksum,
            }
        end,
        on_push = function(name, msg)
            log.info("push", "name", name, "msg", msg)
        end,
        on_state = function(state)
            log.info("session state", "transport", transport, "state", state)
        end,
    }

    local s = client_session.new(conf)
    if not s:start() then
        log.error("login failed", "transport", transport, "gate", gate)
        s:close()
        return false
    end
    play(s, role.rid)
    local ok = check_resume(s)
    if ok then
        play(s, role.rid)
    end
    s:close()
    return ok
end

function CMD.start(conf)
    -- 配置是在 skyext 的 skynet.init 回调里注入的，服务 chunk 加载期读到的是 nil，
    -- 所以 account_host 要在这里取
    local account_host = config.get("account_host")
    local account = "robot" .. conf.id
    local token = fetch_token(account_host, account)
    if not token then
        return
    end

    local role = ensure_role(account_host, token, account, pick_server(account_host))
    if not role then
        return
    end

    local gates = fetch_gates(account_host)
    if not gates then
        return
    end

    -- 机器人按编号错开起点，再依次试到第一个连得上的 gate。连哪个 gate 都能进游戏
    -- （gate 只管会话，上行包转发到角色实体所在节点），所以某一台正好在重启时不该整体失败
    local start = conf.gate or (conf.id % #gates + 1)
    local transports = config.get_table("robot_transports") or { "tcp", "ws" }
    for i = 0, #gates - 1 do
        local gate = gates[(start + i - 1) % #gates + 1]
        local all_ok = true
        for _, transport in ipairs(transports) do
            if not run(transport, gate, role, token) then
                all_ok = false
                break
            end
        end
        if all_ok then
            log.info("robot finished", "gate", gate, "transports", transports)
            return
        end
    end
    log.error("no gate completed the run", "gates", gates)
end

skynet.start(function()
    cmd_api.dispatch(CMD)
end)
