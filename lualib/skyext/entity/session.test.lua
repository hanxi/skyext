local t = require "skytest"
local skynet = require "skynet"
local errcode = require "skyext.errcode"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/session.lua")

-- 本节点名：会话键里的 gate_node 等于它时走本地消息，否则走 cluster
local SELF_NODE = "role1"
local GATE = ".gate_tcp"
local OWNER = ".entity_agent:role:1"

local function harness(opts)
    opts = opts or {}
    local h = { kicks = {}, gate_ops = {}, mgr_calls = 0, now = 10000, nonce_seq = 0, conf = opts.conf or {} }
    local noop = function() end

    h.entity = { type_name = "role", id = 7 }

    local fake_mgr = {}
    -- 行为对齐 entitymgr:with_loaded_entity：进不去串行队列时返回 false, reason，
    -- 处理期间丢租约同样返回 false
    function fake_mgr:with_loaded_entity(id, f)
        h.mgr_calls = h.mgr_calls + 1
        h.mgr_id = id
        if h.not_loaded then
            return false, "entity not loaded or lease expired"
        end
        if h.before_handler then
            local cb = h.before_handler
            h.before_handler = nil
            cb()
        end
        local result = table.pack(f(h.active or h.entity))
        if h.expire_during then
            return false, "entity lease expired during handler"
        end
        return true, table.unpack(result, 1, result.n)
    end
    function fake_mgr:touch(id)
        h.touched = id
    end
    function fake_mgr:get(id)
        if h.entity and h.entity.id == id and not h.entity_gone then
            return h.entity
        end
        return nil
    end

    -- 网络网关：同节点走 skynet 本地消息，跨节点走 cluster。两者都把原始字节交给网关
    local function record_call(transport, node, service, cmd, ...)
        local op = { transport, cmd, ... }
        h.last_gate_service = service
        if node then
            table.insert(op, 2, node)
        end
        h.gate_ops[#h.gate_ops + 1] = op
        return op
    end
    local function record_kick(node, fd)
        h.kicks[#h.kicks + 1] = { node = node, fd = fd }
    end

    local fake_skynet = setmetatable({
        now = function()
            return h.now
        end,
        send = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            local op = record_call("local", nil, addr, cmd, ...)
            if cmd == "kick" then
                record_kick(SELF_NODE, op[3])
            end
        end,
        call = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            record_call("local", nil, addr, cmd, ...)
            if cmd == "bind" then
                return h.gate_bind_result ~= false
            end
            return true
        end,
    }, { __index = skynet })

    -- 跨节点的网关走 cluster：cluster.send/call 不像 skynet.send/call 带 proto，
    -- 参数直接就是 (node, address, cmd, ...)
    local fake_cluster = {
        send = function(node, addr, cmd, ...)
            local op = record_call("cluster", node, addr, cmd, ...)
            if cmd == "kick" then
                record_kick(node, op[4])
            end
        end,
        call = function(node, addr, cmd, ...)
            record_call("cluster", node, addr, cmd, ...)
            if cmd == "bind" then
                return h.gate_bind_result ~= false
            end
            return true
        end,
    }

    local fake_sproto = {
        set_sender = function(sender)
            h.sender = sender
        end,
        encode_notify = function(name, msg)
            return "PACK:" .. name .. ":" .. tostring(msg and msg.id or "")
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        -- 续接凭据必须不可预测，但测试要能断言"轮换过了"，所以发可递增的假值
        crypto = {
            random_bytes = function()
                h.nonce_seq = h.nonce_seq + 1
                return "nonce" .. h.nonce_seq
            end,
            const_equals = function(a, b)
                return a == b
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return SELF_NODE
            end,
            get_number = function(key)
                return h.conf[key]
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
        ["skyext.timer"] = {
            repeat_delayed = function(_, _, f)
                h.idle_sweep = f
            end,
        },
        ["skyext.sproto_api"] = fake_sproto,
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.session = assert(loadfile(source, "t", env))()
    if not opts.no_mgr then
        h.session.init(fake_mgr)
    end
    h.mgr = fake_mgr
    return h
end

-- 绑定会话并返回会话键
local function bind(h, fd, gate_node, entity)
    gate_node = gate_node or SELF_NODE
    entity = entity or h.entity
    local ok, nonce = h.session.bind(gate_node, GATE, fd, entity, OWNER)
    return ok, h.session.key(gate_node, fd), nonce
end

-- 只保留 push 操作，断言下行顺序时用
local function pushes(h)
    local out = {}
    for _, op in ipairs(h.gate_ops) do
        if op[2] == "push" then
            out[#out + 1] = op[#op]
        end
    end
    return out
end

t.describe("session bind", function()
    t.it("installs the session, cancels a pending unload and points the gate at this service", function()
        local h = harness()
        local cancelled = false
        h.entity.unload_timer = {
            cancel = function()
                cancelled = true
            end,
        }
        local ok, key, nonce = bind(h, 9)
        t.expect(ok).to.equal(true)
        t.expect(key).to.equal("role1/9")
        t.expect(nonce).to.equal("nonce1")
        t.expect(h.entity.session.key).to.equal("role1/9")
        t.expect(h.entity.session.gate_service).to.equal(GATE)
        t.expect(h.entity.unload_timer).to.be_nil()
        t.expect(cancelled).to.equal(true)
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "local", "bind", 9, "role1", OWNER })
    end)

    t.it("routes the bind to a remote gate over cluster", function()
        local h = harness()
        local ok, key = bind(h, 9, "gate1")
        t.expect(ok).to.equal(true)
        t.expect(key).to.equal("gate1/9")
        t.expect(h.entity.session.key).to.equal("gate1/9")
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "cluster", "gate1", "bind", 9, "role1", OWNER })
    end)

    t.it("reports failure when the gate already dropped the connection", function()
        local h = harness()
        h.gate_bind_result = false
        local ok = h.session.bind("role1", GATE, 9, h.entity, OWNER)
        t.expect(ok).to.equal(false)
        t.expect(h.entity.session).to.be_nil()
        t.expect(h.entity.session_io).to.be_nil()
    end)

    -- 顶号和同账号重登走的是同一个实体对象，沿用旧 session_io 会让后来者继承前一个
    -- 客户端的凭据、计数和响应缓存
    t.it("rebuilds the session state on every login so a relog cannot inherit it", function()
        local h = harness()
        local _, _, first = bind(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        t.expect(h.entity.session_io.sent).to.equal(1)

        local _, _, second = bind(h, 10)
        t.expect(second).to_not.equal(first)
        t.expect(h.entity.session_io.sent).to.equal(0)
        t.expect(h.entity.session_io.acked).to.equal(0)

        -- 旧凭据对新会话无效
        t.expect(h.session.resume("role1", GATE, 11, h.entity, OWNER, first, 0)).to.equal(errcode.AUTH_FAILED)
    end)
end)

t.describe("session request gating", function()
    t.it("runs the handler inside the entity gate and keeps all of its return values", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ok, a, b = h.session.with_request(key, function()
            return "pack", 3
        end)
        t.expect(ok).to.equal(true)
        t.expect(a).to.equal("pack")
        t.expect(b).to.equal(3)
        t.expect(h.mgr_id).to.equal(7)
    end)

    t.it("reports success when the handler produced nothing", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ok, result = h.session.with_request(key, function() end)
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
    end)

    t.it("rejects with a reason instead of silently dropping unbound requests", function()
        local h = harness()
        local ran = false
        local ok, reason = h.session.with_request("role1/9", function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client not bound")
        t.expect(ran).to.equal(false)
        t.expect(h.mgr_calls).to.equal(0)
    end)

    t.it("rejects requests that arrive before the entity manager is ready", function()
        local h = harness({ no_mgr = true })
        -- 手动装一个会话，绕过 init（没有 entitymgr）
        h.session.bind("role1", GATE, 9, h.entity, OWNER)
        local ok, reason = h.session.with_request("role1/9", function() end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("entity manager not ready")
    end)

    t.it("rejects when the entity is gone or its lease expired", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.not_loaded = true
        local ran = false
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("entity not loaded or lease expired")
        t.expect(ran).to.equal(false)

        h.not_loaded = false
        h.expire_during = true
        local ok2, reason2 = h.session.with_request(key, function()
            return "pack"
        end)
        t.expect(ok2).to.equal(false)
        t.expect(reason2).to.equal("entity lease expired during handler")
    end)

    t.it("rejects a request whose session was unbound while it waited in the queue", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ran = false
        h.before_handler = function()
            h.session.unbind(key)
        end
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
        t.expect(h.touched).to.equal(7)
    end)

    t.it("rejects a request whose session key was rebound to another entity while it waited", function()
        local h = harness()
        local _, key = bind(h, 9)
        local ran = false
        h.before_handler = function()
            h.session.unbind(key)
            h.session.bind("role1", GATE, 9, { type_name = "role", id = 7 }, OWNER)
        end
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
    end)

    t.it("rejects when the gate handed over a reloaded entity instance", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.active = { type_name = "role", id = 7 }
        local ran = false
        local ok, reason = h.session.with_request(key, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
    end)

    t.it("lets handler errors propagate so the caller can answer the client", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(function()
            h.session.with_request(key, function()
                error("boom")
            end)
        end).to
            .throw("boom")
    end)

    t.it("records the last upstream packet time for the idle check", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.now = 99999
        h.session.with_request(key, function() end)
        t.expect(h.entity.session_io.last_seen).to.equal(99999)
    end)
end)

-- 续接之后客户端按原 request id 重发在途请求，服务端必须认出来回缓存的响应。
-- 重新执行一遍扣费、抽卡比丢一个回包危险得多
t.describe("session upstream idempotency", function()
    t.it("answers a repeated request id from cache without running the handler again", function()
        local h = harness()
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        t.expect({ h.session.with_request(key, handler, 5) }).to.equal({ true, "RESP" })
        t.expect({ h.session.with_request(key, handler, 5) }).to.equal({ true, "RESP" })
        t.expect(runs).to.equal(1)
    end)

    t.it("does not cache anything for requests that carry no request id", function()
        local h = harness()
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        h.session.with_request(key, handler)
        h.session.with_request(key, handler)
        t.expect(runs).to.equal(2)
    end)

    t.it("refuses an evicted request id instead of silently running it a second time", function()
        local h = harness({ conf = { session_respcache_count = 2 } })
        local _, key = bind(h, 9)
        local runs = 0
        local function handler()
            runs = runs + 1
            return "RESP"
        end
        for req_id = 1, 3 do
            h.session.with_request(key, handler, req_id)
        end
        t.expect(runs).to.equal(3)

        local ok, reason, code = h.session.with_request(key, handler, 1)
        t.expect(ok).to.equal(false)
        t.expect(code).to.equal(errcode.REQUEST_EXPIRED)
        t.expect(reason).to.equal("response for this request id was already evicted")
        t.expect(runs).to.equal(3)

        -- 还在缓存里的照常命中
        t.expect({ h.session.with_request(key, handler, 3) }).to.equal({ true, "RESP" })
        t.expect(runs).to.equal(3)
    end)

    -- 客户端在续接之后重置了 request id 计数器：续接不重建 session_io，缓存还是
    -- 断线前那张，小 id 会命中别的请求的响应。只有协议名能看出来
    t.it("refuses a cached request id that now carries a different request", function()
        local h = harness()
        local _, key = bind(h, 9)
        local function handler(resp)
            return function()
                return resp
            end
        end
        t.expect({ h.session.with_request(key, handler("BAG"), 1, "bag.use_item") }).to.equal({ true, "BAG" })

        local ok, reason, code = h.session.with_request(key, handler("SHOP"), 1, "shop.buy")
        t.expect(ok).to.equal(false)
        t.expect(code).to.equal(errcode.REQUEST_CONFLICT)
        t.expect(reason).to.equal("request id reused for a different request")

        -- 同名的照常命中缓存，不重新执行
        local runs = 0
        t.expect({
            h.session.with_request(key, function()
                runs = runs + 1
                return "AGAIN"
            end, 1, "bag.use_item"),
        }).to
            .equal({ true, "BAG" })
        t.expect(runs).to.equal(0)
    end)
end)

t.describe("session lookup", function()
    t.it("get_obj wraps a live entity and returns nil once it is gone", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(h.session.get_entity(key)).to.equal(h.entity)
        t.expect(h.session.get_obj(key)).to.equal({ entity = h.entity })
        t.expect(h.session.is_online(h.entity)).to.equal(true)
        h.entity_gone = true
        t.expect(h.session.get_obj(key)).to.be_nil()
    end)
end)

t.describe("session disconnect", function()
    t.it("kick pushes to the gate that owns the session", function()
        local h = harness()
        bind(h, 9)
        h.session.kick("role1/9")
        t.expect(h.kicks).to.equal({ { node = "role1", fd = 9 } })
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "local", "kick", 9 })
    end)

    t.it("kick reaches a remote gate over cluster", function()
        local h = harness()
        bind(h, 12, "gate1")
        h.session.kick("gate1/12")
        t.expect(h.kicks).to.equal({ { node = "gate1", fd = 12 } })
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "cluster", "gate1", "kick", 12 })
    end)

    t.it("ignores a kick for a session it does not know", function()
        local h = harness()
        h.session.kick("gate1/12")
        t.expect(h.kicks).to.equal({})
    end)

    t.it("reject_client kicks without unbinding so the disconnect flow still runs", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.reject_client(key, "client binding revoked")
        t.expect(h.kicks).to.equal({ { node = "role1", fd = 9 } })
        t.expect(h.session.get_entity(key)).to.equal(h.entity)
        t.expect(h.entity.session.key).to.equal("role1/9")
        t.expect(h.touched).to.be_nil()
    end)

    t.it("unbinds and kicks when the entity side drops the connection", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(h.session.unbind_kick(key, h.entity)).to.equal(true)
        t.expect(h.kicks).to.equal({ { node = "role1", fd = 9 } })
        t.expect(h.session.get_entity(key)).to.be_nil()
        t.expect(h.entity.session).to.be_nil()
        t.expect(h.touched).to.equal(7)
    end)

    -- 断开的只是连接，会话状态要活到实体卸载，否则续接无从谈起
    t.it("keeps the session state across a disconnect", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        h.session.unbind(key)
        t.expect(h.session.is_online(h.entity)).to.equal(false)
        t.expect(h.entity.session_io.sent).to.equal(1)
    end)

    t.it("does not disconnect a new binding when an old entity kick runs late", function()
        local h = harness()
        local old_entity = { type_name = "role", id = 7 }
        bind(h, 9, SELF_NODE, old_entity)
        bind(h, 9, SELF_NODE, h.entity)

        t.expect(h.session.unbind_kick("role1/9", old_entity)).to.equal(false)
        t.expect(h.session.get_entity("role1/9")).to.equal(h.entity)
        t.expect(h.entity.session.key).to.equal("role1/9")
        t.expect(h.kicks).to.equal({})
        t.expect(h.touched).to.be_nil()
    end)

    t.it("kicks a connection whose client stopped sending anything", function()
        local h = harness({ conf = { session_idle_timeout = 60 } })
        bind(h, 9)
        h.session.sweep_idle()
        t.expect(h.kicks).to.equal({})
        h.now = h.now + 61 * 100
        h.session.sweep_idle()
        t.expect(h.kicks).to.equal({ { node = "role1", fd = 9 } })
    end)
end)

t.describe("session downstream counting", function()
    t.it("counts and buffers every push, and writes it to the gate when online", function()
        local h = harness()
        bind(h, 9)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 1 })).to.equal(true)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 2 })).to.equal(true)
        t.expect(h.entity.session_io.sent).to.equal(2)
        t.expect(pushes(h)).to.equal({ "PACK:mail_notify:1", "PACK:mail_notify:2" })
    end)

    -- 离线时包不是丢了，是进了重放缓冲等续接
    t.it("buffers a push while the client is offline instead of dropping it", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.unbind(key)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 1 })).to.equal(false)
        t.expect(h.entity.session_io.sent).to.equal(1)
        t.expect(pushes(h)).to.equal({})
    end)

    t.it("refuses to push to an entity that never had a session", function()
        local h = harness()
        t.expect(h.session.push(h.entity, "mail_notify", {})).to.equal(false)
    end)

    t.it("the sproto sender counts responses but not transport handshakes", function()
        local h = harness()
        bind(h, 9)
        h.sender("role1/9", "RESP", "role.bag_list")
        t.expect(h.entity.session_io.sent).to.equal(1)
        -- resume / ping 的回包处在计数边界之外：算进去客户端的自校验立刻失配
        h.sender("role1/9", "PONG", "login.ping")
        h.sender("role1/9", "RESUMED", "login.resume")
        t.expect(h.entity.session_io.sent).to.equal(1)
        t.expect(pushes(h)).to.equal({ "RESP", "PONG", "RESUMED" })
    end)

    t.it("the sender drops a package for a session that is gone", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.unbind(key)
        local before = #h.gate_ops
        h.sender(key, "RAWBYTES")
        t.expect(#h.gate_ops).to.equal(before)
    end)

    t.it("trims the replay buffer when the client acknowledges", function()
        local h = harness()
        bind(h, 9)
        for i = 1, 3 do
            h.session.push(h.entity, "mail_notify", { id = i })
        end
        h.session.ack(h.entity, 2)
        local io_ = h.entity.session_io
        t.expect(io_.acked).to.equal(2)
        t.expect(io_.out_buf[1]).to.be_nil()
        t.expect(io_.out_buf[3]).to.equal("PACK:mail_notify:3")
    end)

    t.it("gives up on replay rather than keep an unbounded buffer", function()
        local h = harness({ conf = { session_replay_packets = 2 } })
        local _, key = bind(h, 9)
        h.session.unbind(key)
        for i = 1, 3 do
            h.session.push(h.entity, "mail_notify", { id = i })
        end
        t.expect(h.entity.session_io.unresumable).to.equal(true)
        t.expect(h.session.resume("role1", GATE, 10, h.entity, OWNER, "nonce1", 0)).to.equal(errcode.RESUME_UNAVAILABLE)
    end)

    t.it("marks the session unresumable when the client acknowledges an impossible count", function()
        local h = harness()
        bind(h, 9)
        h.session.push(h.entity, "mail_notify", { id = 1 })
        h.session.ack(h.entity, 5)
        t.expect(h.entity.session_io.unresumable).to.equal(true)
    end)
end)

t.describe("session resume", function()
    local function bind_and_push(h, count)
        local _, key, nonce = bind(h, 9)
        for i = 1, count or 0 do
            h.session.push(h.entity, "mail_notify", { id = i })
        end
        return key, nonce
    end

    t.it("moves the session onto a new connection and rotates the credential", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 2)
        local code, new_nonce, sent = h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 1)
        t.expect(code).to.equal(errcode.OK)
        t.expect(new_nonce).to_not.equal(nonce)
        t.expect(sent).to.equal(2)
        t.expect(h.entity.session.fd).to.equal(20)
        t.expect(h.session.get_entity("role1/20")).to.equal(h.entity)
        t.expect(h.session.get_entity("role1/9")).to.be_nil()
    end)

    -- 旧连接多半还半开着，要回收；但不能走 unbind_kick——那条路会引出网关的
    -- session_closed，触发 on_unbind_client，业务层就看到一次假的下线再上线
    t.it("reclaims the half-open old connection without unbinding the entity", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 0)
        t.expect(h.kicks).to.equal({ { node = "role1", fd = 9 } })
        t.expect(h.entity.session).to_not.be_nil()
        t.expect(h.touched).to.be_nil()
    end)

    -- 热替换之后旧连接的 session_closed 才迟迟到达，不能把新连接清掉
    t.it("survives a session_closed for the old connection arriving after the swap", function()
        local h = harness()
        local old_key, nonce = bind_and_push(h, 0)
        h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 0)
        h.session.unbind(old_key)
        t.expect(h.entity.session).to_not.be_nil()
        t.expect(h.entity.session.fd).to.equal(20)
        t.expect(h.touched).to.be_nil()
    end)

    t.it("holds back new pushes until the replay is done, then releases them in order", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 3)
        h.session.ack(h.entity, 1)
        h.gate_ops = {}

        h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 1)
        -- 续接只做热替换，重放还没开始
        t.expect(pushes(h)).to.equal({})
        -- 业务在 on_resume_client 之前推的包也要排在旧包后面
        h.session.push(h.entity, "mail_notify", { id = 9 })
        t.expect(pushes(h)).to.equal({})

        h.session.replay(h.entity)
        t.expect(pushes(h)).to.equal({ "PACK:mail_notify:2", "PACK:mail_notify:3", "PACK:mail_notify:9" })
        -- 重放结束后恢复直发
        h.session.push(h.entity, "mail_notify", { id = 10 })
        t.expect(pushes(h)[4]).to.equal("PACK:mail_notify:10")
    end)

    t.it("replays nothing when the client already received everything", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 2)
        h.gate_ops = {}
        h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 2)
        h.session.replay(h.entity)
        t.expect(pushes(h)).to.equal({})
    end)

    t.it("rejects a wrong credential and a credential that was already rotated", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        t.expect(h.session.resume("role1", GATE, 20, h.entity, OWNER, "wrong", 0)).to.equal(errcode.AUTH_FAILED)
        t.expect(h.session.resume("role1", GATE, 20, h.entity, OWNER, nil, 0)).to.equal(errcode.AUTH_FAILED)
        -- 仍然挂在原连接上
        t.expect(h.entity.session.fd).to.equal(9)

        h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 0)
        t.expect(h.session.resume("role1", GATE, 21, h.entity, OWNER, nonce, 0)).to.equal(errcode.AUTH_FAILED)
    end)

    t.it("rejects an entity that never had a session", function()
        local h = harness()
        t.expect(h.session.resume("role1", GATE, 20, h.entity, OWNER, "nonce1", 0)).to.equal(errcode.RESUME_UNAVAILABLE)
    end)

    -- 隐式计数不自带校验，这是唯一一次对账的机会
    t.it("rejects a received count that cannot be true", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 2)
        t.expect(h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 3)).to.equal(errcode.RESUME_UNAVAILABLE)
        h.session.ack(h.entity, 2)
        t.expect(h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 1)).to.equal(errcode.RESUME_UNAVAILABLE)
    end)

    t.it("reports a closed connection when the gate dropped the new fd first", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        h.gate_bind_result = false
        t.expect(h.session.resume("role1", GATE, 20, h.entity, OWNER, nonce, 0)).to.equal(errcode.SESSION_CLOSED)
        t.expect(h.entity.session.fd).to.equal(9)
    end)

    -- 会话和传输无关：TCP 断了可以从 WS 接回来，也可以换一个网关节点
    t.it("accepts a resume from another gate node and another transport", function()
        local h = harness()
        local _, nonce = bind_and_push(h, 0)
        local code = h.session.resume("gate2", ".gate_ws", 3, h.entity, OWNER, nonce, 0)
        t.expect(code).to.equal(errcode.OK)
        t.expect(h.entity.session.gate_node).to.equal("gate2")
        t.expect(h.entity.session.gate_service).to.equal(".gate_ws")
    end)

    t.it("answers a ping with the current sent count and trims the buffer", function()
        local h = harness()
        bind_and_push(h, 2)
        local reply = h.session.cmds.ping({ recv = 2 }, 9, { entity = h.entity })
        t.expect(reply).to.equal({ sent = 2 })
        t.expect(h.entity.session_io.acked).to.equal(2)
    end)
end)
