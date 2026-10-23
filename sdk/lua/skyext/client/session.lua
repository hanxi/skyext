-- Lua 客户端 SDK：会话层。规范与五条义务的完整细节见 docs/guide/client_protocol.md，
-- 服务端设计背景见 docs/archive/session_resume.md。TypeScript 对等实现在 sdk/ts/，
-- 两者共享同一套协议语义测试基线（session.test.lua / session.test.ts）。
-- robot（example/nodes/robot）用它跑连通性测试，同时充当本模块的端到端验收用例。
--
-- 客户端必须承担的义务，一条都不能省：
--   1. 每个请求带一个自增的 request id，续接之后**用原 id 重发**在途请求。
--      换 id 服务端就认不出来，扣费、抽卡会执行第二遍。计数器只增不减，重连路径上
--      绝不清零：续接不重建服务端会话，重置后的小 id 会命中另一个请求的缓存响应。
--   2. 数**收到的**下行包，不是数**认得的**。序号不在包里传（TCP/WS 在一条连接内有序不丢），
--      两端各数各的，只在 resume / ping 时对账。认不出 request id 的响应（续接后的重复回包）
--      照样要计数再丢。漏数一个，重放就错位，而且**不会报错**。
--   3. 传输层握手的回包不计数：login / resume / ping 的响应。
--   4. 自己发现断线：切网络时旧连接不产生 FIN/RST，它直接变黑洞。靠 ping 的**响应**判活。
--   5. resume 的响应和重放的包之间**没有顺序保证**（响应来自登录服务，重放来自实体进程，
--      跨节点时走两条 TCP 连接）。响应靠 request id 认领，又不计数，早到晚到都不影响。
local skynet = require "skynet"
local socket = require "skynet.socket"
local netpack = require "skynet.netpack"
local websocket = require "http.websocket"
local sproto_api = require "skyext.sproto_api"
local errcode = require "skyext.errcode"
local log = require "skyext.log"

local M = {}

-- 处在下行计数边界之外的回包，必须和服务端 skyext.entity.session 里的那份一致
local UNCOUNTED_RESPONSE = {
    ["login.login"] = true,
    ["login.resume"] = true,
    ["login.ping"] = true,
}

-- 协议可能被热更换掉，attach 出来的打包函数绑在具体的 host 上，不能长期缓存
local g_packers = setmetatable({}, { __mode = "k" })
local function packer()
    local host = sproto_api.get_sproto_host()
    local f = g_packers[host]
    if not f then
        f = host:attach()
        g_packers[host] = f
    end
    return host, f
end

-- ------------------------------------------------------------------ 传输层

-- 裸 TCP：2 字节大端长度前缀，和 skynet.netpack 对齐
local tcp = {}

function tcp.connect(conf)
    local fd, err = socket.open(conf.host, conf.port)
    if not fd then
        return nil, err
    end
    return { fd = fd, buf = "" }
end

function tcp.send(conn, bytes)
    local data, sz = netpack.pack(bytes)
    socket.write(conn.fd, data, sz)
end

local function take_package(buf)
    if #buf < 2 then
        return nil, buf
    end
    local size = buf:byte(1) * 256 + buf:byte(2)
    if #buf < size + 2 then
        return nil, buf
    end
    return buf:sub(3, 2 + size), buf:sub(3 + size)
end

function tcp.read(conn)
    while true do
        local pack
        pack, conn.buf = take_package(conn.buf)
        if pack then
            return pack
        end
        local more = socket.read(conn.fd)
        if not more or more == "" then
            return nil
        end
        conn.buf = conn.buf .. more
    end
end

function tcp.close(conn)
    pcall(socket.close, conn.fd)
end

-- WebSocket：帧自带边界，不加长度前缀
local ws = {}

function ws.connect(conf)
    local ok, id = pcall(websocket.connect, conf.url)
    if not ok then
        return nil, id
    end
    return { id = id }
end

function ws.send(conn, bytes)
    websocket.write(conn.id, bytes, "binary")
end

function ws.read(conn)
    local data = websocket.read(conn.id)
    if not data then
        return nil
    end
    return data
end

function ws.close(conn)
    pcall(websocket.close, conn.id)
end

local TRANSPORTS = { tcp = tcp, ws = ws }

-- ------------------------------------------------------------------ 会话

local Session = {}
Session.__index = Session

-- conf:
--   transport     "tcp" 或 "ws"
--   host / port   tcp 用
--   url           ws 用（ws:// 或 wss://）
--   login_param   function() -> login.login 的请求表（token 可能过期，所以是函数）
--   on_push       function(name, msg) 服务端主动推送
--   on_state      function(state) "online" / "offline" / "relogin"
function M.new(conf)
    local transport = assert(TRANSPORTS[conf.transport or "tcp"], "unknown transport")
    return setmetatable({
        conf = conf,
        transport = transport,
        ping_interval = conf.ping_interval or 15,
        -- 连发几次 ping 收不到响应就判定连接已死。15s * 2 = 30s
        ping_tolerance = conf.ping_tolerance or 2,
        reconnect_delay = conf.reconnect_delay or 1,
        handshake_timeout = conf.handshake_timeout or 5,
        conn = nil,
        online = false,
        closed = false,
        rid = nil,
        nonce = nil,
        recv = 0, -- 已收到的计数内下行包数，必须和服务端的 sent 严格相等
        -- 只在这里置 0。重连、续接、完整重登都不重置，见义务 1
        next_req_id = 0,
        pending = {}, -- request id -> { name, param, co, response, answered }
    }, Session)
end

function Session:notify_state(state)
    if self.conf.on_state then
        self.conf.on_state(state)
    end
end

-- 发一个请求并等响应。timeout 为 nil 时一直等——续接之后请求会被原样重发，
-- 等待跨越重连正是这套机制的意义所在。只有握手类请求才给超时
function Session:request(name, param, timeout)
    local req_id = self.next_req_id + 1
    self.next_req_id = req_id
    local p = { name = name, param = param, co = coroutine.running() }
    self.pending[req_id] = p
    self:send(req_id, p)

    if timeout then
        -- 回包可能在 send 让出时就已经到了，这时不能再睡
        if not p.answered then
            skynet.sleep(timeout * 100, p)
        end
        if not p.answered then
            -- 响应也许还在路上。pending 条目要留着：计数要靠它分辨那个回包算不算数
            p.co = nil
            return nil
        end
    else
        while not p.answered and not self.closed do
            p.co = coroutine.running()
            skynet.wait(p)
        end
    end
    return p.response
end

function Session:send(req_id, p)
    local conn = self.conn
    if not conn then
        return false
    end
    local _, pack = packer()
    local ok, err = pcall(self.transport.send, conn, pack(p.name, p.param, req_id))
    if not ok then
        log.warn("client send failed", "name", p.name, "err", err)
        return false
    end
    return true
end

local function answer(p, response)
    p.answered = true
    p.response = response
    local co = p.co
    if co then
        p.co = nil
        skynet.wakeup(p)
    end
end

function Session:handle(bytes)
    local host = packer()
    local ok, msg_type, a, b = pcall(host.dispatch, host, bytes)
    if not ok then
        -- 解不开码的包也要计数：服务端发出时计了数，这里漏数一个，recv 就
        -- 永久落后 sent 一位，ping 对账必然错位（义务 2）
        self.recv = self.recv + 1
        log.error("client dispatch failed", "err", msg_type)
        return
    end
    if msg_type == "REQUEST" then
        -- 服务端推送，计数内
        self.recv = self.recv + 1
        if self.conf.on_push then
            self.conf.on_push(a, b)
        end
        return
    end

    local req_id, response = a, b
    local p = self.pending[req_id]
    if not p then
        -- 续接之后同一个请求会有两份响应：重放出来的那份，和按原 id 重发后命中服务端幂等
        -- 缓存的那份。认领一份，另一份丢掉——但**必须先计数**：服务端两份都计了，这里漏数
        -- 一个，recv 就永久落后 sent 一位，而且不报错。
        -- 丢掉的这份一定是计数内的：握手类请求的 pending 条目在 resend_pending /
        -- fail_pending 里已经显式清过，而它们的响应从不进重放缓冲，不可能被重放
        self.recv = self.recv + 1
        log.info("client dropped a duplicate response", "req_id", req_id, "recv", self.recv)
        return
    end
    self.pending[req_id] = nil
    if not UNCOUNTED_RESPONSE[p.name] then
        self.recv = self.recv + 1
    end
    answer(p, response)
end

-- 连接断了（读失败或主动丢弃）。只处理当前这条，迟到的断开通知不能影响新连接
function Session:drop(conn)
    if conn == nil or self.conn ~= conn then
        return
    end
    self.conn = nil
    self.online = false
    self.transport.close(conn)
    log.info("client connection lost", "recv", self.recv)
    self:notify_state("offline")
end

-- 续接之后重发在途请求。**必须用原来的 request id**，服务端靠它认出重复请求、
-- 回缓存的响应而不是重新执行一遍
function Session:resend_pending()
    for req_id, p in pairs(self.pending) do
        if UNCOUNTED_RESPONSE[p.name] then
            -- 握手类请求不会被重放，旧连接上的那次永远不会有响应了
            self.pending[req_id] = nil
            answer(p, nil)
        else
            self:send(req_id, p)
        end
    end
end

-- 续接失败后退化成完整登录：会话状态已经没了，在途请求全部失败
function Session:fail_pending()
    for req_id, p in pairs(self.pending) do
        self.pending[req_id] = nil
        answer(p, nil)
    end
end

function Session:try_resume()
    if not self.nonce or not self.rid then
        return false
    end
    local resp =
        self:request("login.resume", { rid = self.rid, nonce = self.nonce, recv = self.recv }, self.handshake_timeout)
    if not resp or resp.code ~= errcode.OK then
        log.info("resume rejected, falling back to login", "code", resp and resp.code)
        return false
    end
    self.nonce = resp.nonce
    self.online = true
    -- resp.sent 是服务端已发出的包数，(recv, sent] 这些包正在重放过来，收到就自然对上；
    -- 响应和重放之间没有顺序保证，这里不能等、也不用等
    log.info("resumed", "recv", self.recv, "server_sent", resp.sent)
    self:resend_pending()
    self:notify_state("online")
    return true
end

function Session:do_login()
    local param = self.conf.login_param()
    if not param then
        return false
    end
    local resp = self:request("login.login", param, self.handshake_timeout)
    if not resp or resp.code ~= errcode.OK then
        log.warn("login failed", "code", resp and resp.code)
        return false
    end
    -- 全新的会话：计数清零，旧的在途请求在服务端已经不存在了
    self.rid = resp.rid
    self.nonce = resp.nonce
    self.recv = 0
    self.online = true
    self:fail_pending()
    self:notify_state("online")
    return true
end

-- 建连并让会话重新可用：先试续接，不行再完整登录
function Session:establish()
    local conn, err = self.transport.connect(self.conf)
    if not conn then
        log.warn("connect failed", "err", err)
        return false
    end
    self.conn = conn
    skynet.wakeup(self) -- 收包协程可能正挂着等连接
    if self:try_resume() then
        return true
    end
    self:notify_state("relogin")
    if self:do_login() then
        return true
    end
    self:drop(conn)
    return false
end

function Session:reader()
    while not self.closed do
        local conn = self.conn
        if not conn then
            -- 没有连接时短暂挂起，建连流程会在设置 self.conn 之后唤醒
            skynet.sleep(10, self)
        else
            -- 连接被另一个协程关掉时 websocket.read 是抛错而不是返回 nil。
            -- 收包协程死了整个会话就哑了（没人收响应，续接和重登都会超时），
            -- 所以这里必须兜住
            local ok, bytes = pcall(self.transport.read, conn)
            if ok and bytes then
                self:handle(bytes)
            else
                self:drop(conn)
            end
        end
    end
end

function Session:supervisor()
    while not self.closed do
        if not self.conn then
            self:establish()
        end
        skynet.sleep(self.reconnect_delay * 100)
    end
end

-- 心跳。它存在的理由是客户端要自己发现黑洞连接，所以必须看**响应**：
-- 单向心跳只让服务端知道客户端还活着，客户端什么也得不到
function Session:heartbeat()
    local misses = 0
    while not self.closed do
        skynet.sleep(self.ping_interval * 100)
        if self.online then
            local conn = self.conn
            local resp = self:request("login.ping", { recv = self.recv }, self.ping_interval)
            if resp then
                misses = 0
                -- 隐式计数唯一的对账点。对不上说明两端已经错位，继续跑下去只会把
                -- 错位的数据当正常数据用，不如立刻断开重来
                if resp.sent ~= self.recv then
                    log.error("downstream count desync", "client", self.recv, "server", resp.sent)
                    self.nonce = nil
                    self:drop(conn)
                end
            else
                misses = misses + 1
                if misses >= self.ping_tolerance then
                    log.warn("no pong, dropping the connection", "misses", misses)
                    misses = 0
                    self:drop(conn)
                end
            end
        end
    end
end

-- 建连、登录，并把收包、重连、心跳三个协程跑起来。
-- 收包协程必须先起来：握手本身要等响应，没人收包就只能等到超时
function Session:start()
    skynet.fork(Session.reader, self)
    local ok = self:establish()
    skynet.fork(Session.supervisor, self)
    skynet.fork(Session.heartbeat, self)
    return ok
end

function Session:call(name, param)
    return self:request(name, param)
end

-- 主动丢弃当前连接，让重连协程走一遍续接。用于测试，也用于客户端自己察觉到
-- 网络环境变了（切 WiFi/蜂窝）时不等心跳超时、立刻重连
function Session:reconnect()
    self:drop(self.conn)
end

function Session:close()
    self.closed = true
    self:fail_pending()
    local conn = self.conn
    self.conn = nil
    self.online = false
    if conn then
        self.transport.close(conn)
    end
    skynet.wakeup(self)
end

return M
