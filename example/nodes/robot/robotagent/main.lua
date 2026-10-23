-- 压测/连通性机器人。它同时是 sdk/lua（Lua 客户端 SDK）的验收用例：
-- 同一套业务流程在 tcp 和 ws 两种传输上各跑一遍，行为必须完全一致；
-- 中间主动断一次连接，验证续接之后业务能接着做、且不用重新登录。
-- Account HTTP（dev_login/选服/建角/网关发现）走 skyext.client.account，
-- 连接、登录、计数、心跳、续接走 skyext.client.session，这里只剩业务编排。
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local log = require "skyext.log"
local sproto_api = require "skyext.sproto_api"
local client_account = require "skyext.client.account"
local client_session = require "skyext.client.session"

local CMD = {}

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
    local account = client_account.new({ hosts = { config.get("account_host") } })
    local name = "robot" .. conf.id
    local token = account:dev_login(name)
    if not token then
        return
    end

    -- 服务器列表不需要登录。没有角色时在推荐服建角；接口不可用时回退示例服 s1
    local role = account:ensure_role(token, name, account:pick_recommended_server() or "s1")
    if not role then
        return
    end

    -- 网关地址来自 account 的 /gates，不写死在配置里。正式客户端走的就是这条路径：
    -- 先查列表再直连其中一台，数据路径上没有代理。列表里只会有真的在线的网关
    -- （网关键挂在节点租约上），所以也不用自己判断某个端口通不通
    local gates = account:gates()
    if not gates or not gates[1] then
        log.error("no gate is online", "gates", gates)
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
