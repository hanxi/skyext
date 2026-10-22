-- client_session 是客户端接入规范的可执行版本，这里钉住的是**协议语义**：
-- 下行怎么计数、续接怎么重发在途请求、对账对不上怎么办。每个客户端平台都要重写一遍
-- 这套逻辑，写错了不会报错，只会在断线重连之后悄悄错位。
--
-- 传输层的分帧（裸 TCP 的 2 字节长度前缀）不在这里测：它没有分支，而且 robot
-- 两种传输各跑一遍就验到了。这里统一走 ws，因为 ws 的帧边界是现成的。
local t = require "skytest"
local skynet = require "skynet"
local errcode = require "errcode"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "example/lualib/client_session.lua")

local URL = "ws://127.0.0.1:7013"

local function harness()
    local h = { writes = {}, inbox = {}, open = {}, states = {}, pushes = {}, next_id = 0 }
    local noop = function() end

    local fake_websocket = {
        connect = function(url)
            t.expect(url).to.equal(URL)
            if h.connect_fail then
                error("connection refused")
            end
            h.next_id = h.next_id + 1
            h.open[h.next_id] = true
            h.inbox[h.next_id] = {}
            h.conn_id = h.next_id
            return h.next_id
        end,
        write = function(id, pack, fmt)
            t.expect(fmt).to.equal("binary")
            h.writes[#h.writes + 1] = { id = id, pack = pack }
        end,
        -- 阻塞到有包或连接关闭。关闭时抛错，和 skynet 的真实行为一致
        read = function(id)
            while true do
                local q = h.inbox[id]
                if q and q[1] then
                    return table.remove(q, 1)
                end
                if not h.open[id] then
                    error("ws closed")
                end
                skynet.sleep(1)
            end
        end,
        close = function(id)
            h.open[id] = nil
        end,
    }

    -- 包就是 { name, args, req_id } 这样的表，不做真的编解码：这里要测的是计数和
    -- 重发，不是 sproto
    local host = {
        attach = function()
            return function(name, args, req_id)
                return { name = name, args = args, req_id = req_id }
            end
        end,
        dispatch = function(_, p)
            if p.kind == "REQUEST" then
                return "REQUEST", p.name, p.body
            end
            return "RESPONSE", p.req_id, p.body
        end,
    }

    local imports = {
        skynet = skynet,
        ["skynet.socket"] = {},
        ["skynet.netpack"] = {},
        ["http.websocket"] = fake_websocket,
        ["skyext.sproto_api"] = {
            get_sproto_host = function()
                return host
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    local M = assert(loadfile(source, "t", env))()

    h.session = M.new({
        transport = "ws",
        url = URL,
        handshake_timeout = 0.2,
        reconnect_delay = 0.02,
        login_param = function()
            return h.login_param or { token = "tok", rid = 1 }
        end,
        on_push = function(name, msg)
            h.pushes[#h.pushes + 1] = { name = name, msg = msg }
        end,
        on_state = function(state)
            h.states[#h.states + 1] = state
        end,
    })

    -- 让已经排队的协程跑完。收包用的是轮询的假 socket，要多给几个 tick
    function h.settle()
        for _ = 1, 6 do
            skynet.sleep(2)
        end
    end

    -- 本端最后发出去的一个包
    function h.last()
        return h.writes[#h.writes]
    end

    -- 从最后一个包往前找指定协议，返回它（断言找得到）
    function h.sent(name)
        for i = #h.writes, 1, -1 do
            if h.writes[i].pack.name == name then
                return h.writes[i].pack
            end
        end
        error("no " .. name .. " was sent")
    end

    function h.reply(req_id, body)
        table.insert(h.inbox[h.conn_id], { kind = "RESPONSE", req_id = req_id, body = body })
        h.settle()
    end

    function h.push(name, body)
        table.insert(h.inbox[h.conn_id], { kind = "REQUEST", name = name, body = body })
        h.settle()
    end

    -- 起会话并应答它的 login。start 会阻塞在握手上，所以放进 fork 里
    function h.login(nonce)
        skynet.fork(function()
            h.started = h.session:start()
        end)
        h.settle()
        h.reply(h.sent("login.login").req_id, { code = errcode.OK, rid = 1, nonce = nonce or "n1" })
        return h.session
    end

    -- 业务请求：发出去、拿到回包，中间要让出去等响应
    function h.call(name, body)
        local ret
        skynet.fork(function()
            ret = h.session:call(name, nil)
        end)
        h.settle()
        h.reply(h.sent(name).req_id, body or { code = errcode.OK })
        return ret
    end

    -- 断线并应答重连时的 resume
    function h.drop_and_resume(resp)
        h.session:reconnect()
        h.settle()
        h.reply(h.sent("login.resume").req_id, resp)
    end

    return h
end

t.describe("client_session 登录", function()
    t.it("登录成功后记下凭据，下行计数从 0 开始", function()
        local h = harness()
        local s = h.login("nonce-a")
        t.expect(h.started).to.be_truthy()
        t.expect(s.online).to.be_truthy()
        t.expect(s.nonce).to.equal("nonce-a")
        t.expect(s.rid).to.equal(1)
        -- 登录响应由登录服务直写 socket，根本没经过服务端的会话层，不能计数
        t.expect(s.recv).to.equal(0)
        s:close()
    end)

    t.it("登录被拒时不置为在线，也不记凭据", function()
        local h = harness()
        skynet.fork(function()
            h.started = h.session:start()
        end)
        h.settle()
        h.reply(h.sent("login.login").req_id, { code = errcode.TOKEN_ERROR })
        t.expect(h.started).to.be_falsy()
        t.expect(h.session.online).to.be_falsy()
        t.expect(h.session.nonce).to.be_nil()
        h.session:close()
    end)
end)

t.describe("client_session 下行计数", function()
    t.it("业务回包和服务端推送都计数", function()
        local h = harness()
        local s = h.login()
        h.call("bag.get_bag")
        t.expect(s.recv).to.equal(1)
        h.push("mail.new", { mail_id = 7 })
        t.expect(s.recv).to.equal(2)
        t.expect(h.pushes[1].name).to.equal("mail.new")
        s:close()
    end)

    t.it("ping 的回包不计数：它是传输层握手，在计数边界之外", function()
        local h = harness()
        local s = h.login()
        h.call("bag.get_bag")
        skynet.fork(function()
            s:request("login.ping", { recv = s.recv }, 1)
        end)
        h.settle()
        h.reply(h.sent("login.ping").req_id, { sent = 1 })
        t.expect(s.recv).to.equal(1)
        s:close()
    end)
end)

t.describe("client_session 续接", function()
    t.it("带上 nonce 和已收计数续接，成功后轮换凭据", function()
        local h = harness()
        local s = h.login("nonce-a")
        h.call("bag.get_bag")
        h.drop_and_resume({ code = errcode.OK, nonce = "nonce-b", sent = 1 })

        local req = h.sent("login.resume")
        t.expect(req.args).to.equal({ rid = 1, nonce = "nonce-a", recv = 1 })
        t.expect(s.nonce).to.equal("nonce-b")
        t.expect(s.online).to.be_truthy()
        -- 续接的响应同样不计数
        t.expect(s.recv).to.equal(1)
        s:close()
    end)

    t.it("续接成功后用原 request id 重发在途请求，服务端才认得出是同一个", function()
        local h = harness()
        local s = h.login()
        local ret
        skynet.fork(function()
            ret = s:call("bag.use_item", { id = 1 })
        end)
        h.settle()
        local original = h.sent("bag.use_item").req_id

        h.drop_and_resume({ code = errcode.OK, nonce = "nonce-b", sent = 0 })
        local resent = h.last()
        t.expect(resent.pack.name).to.equal("bag.use_item")
        t.expect(resent.pack.req_id).to.equal(original)
        -- 业务调用没有超时，它一直等着，正是续接机制存在的意义
        t.expect(ret).to.be_nil()

        h.reply(original, { code = errcode.OK })
        t.expect(ret).to.equal({ code = errcode.OK })
        s:close()
    end)

    t.it("重发后收到两份响应时，认领一份、另一份计数后丢掉", function()
        local h = harness()
        local s = h.login()
        skynet.fork(function()
            s:call("bag.use_item", { id = 1 })
        end)
        h.settle()
        local original = h.sent("bag.use_item").req_id

        -- 断线前服务端其实已经回过一次，这份在重放流里；重发命中幂等缓存又回一次。
        -- 服务端两份都计了，客户端只认领得了一份——另一份要是不计数，recv 就永久少一
        h.drop_and_resume({ code = errcode.OK, nonce = "nonce-b", sent = 0 })
        h.reply(original, { code = errcode.OK })
        t.expect(s.recv).to.equal(1)
        h.reply(original, { code = errcode.OK })
        t.expect(s.recv).to.equal(2)
        s:close()
    end)

    t.it("续接被拒时退化成完整登录，计数清零、在途请求全部失败", function()
        local h = harness()
        local s = h.login("nonce-a")
        h.call("bag.get_bag")
        local ret, answered
        skynet.fork(function()
            ret = s:call("bag.use_item", { id = 1 })
            answered = true
        end)
        h.settle()

        h.drop_and_resume({ code = errcode.RESUME_UNAVAILABLE })
        h.reply(h.sent("login.login").req_id, { code = errcode.OK, rid = 1, nonce = "nonce-c" })

        t.expect(s.online).to.be_truthy()
        t.expect(s.nonce).to.equal("nonce-c")
        t.expect(s.recv).to.equal(0)
        -- 会话状态在服务端已经没了，在途请求不能继续等下去
        t.expect(answered).to.be_truthy()
        t.expect(ret).to.be_nil()
        s:close()
    end)

    t.it("没有凭据时直接走登录，不发 resume", function()
        local h = harness()
        local s = h.login()
        s.nonce = nil
        local before = #h.writes
        s:reconnect()
        h.settle()
        for i = before + 1, #h.writes do
            t.expect(h.writes[i].pack.name).to.equal("login.login")
        end
        t.expect(#h.writes > before).to.be_truthy()
        s:close()
    end)
end)

t.describe("client_session 连接管理", function()
    t.it("迟到的断开通知不影响已经建好的新连接", function()
        local h = harness()
        local s = h.login()
        local stale = s.conn
        h.drop_and_resume({ code = errcode.OK, nonce = "nonce-b", sent = 0 })
        local fresh = s.conn

        s:drop(stale)
        t.expect(s.conn).to.equal(fresh)
        t.expect(s.online).to.be_truthy()
        s:close()
    end)

    t.it("close 之后不再重连，等待中的请求立刻放行", function()
        local h = harness()
        local s = h.login()
        local answered
        skynet.fork(function()
            s:call("bag.use_item", { id = 1 })
            answered = true
        end)
        h.settle()

        s:close()
        h.settle()
        t.expect(answered).to.be_truthy()
        t.expect(s.conn).to.be_nil()
        t.expect(s.online).to.be_falsy()
    end)
end)
