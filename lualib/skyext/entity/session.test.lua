local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/session.lua")

-- 本节点名：会话键里的 gate_node 等于它时走本地消息，否则走 cluster
local SELF_NODE = "role1"
local OWNER = ".entity_agent:role:1"

local function harness(opts)
    opts = opts or {}
    local h = { kicks = {}, gate_ops = {}, notifies = {}, mgr_calls = 0 }
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

    -- 网络 gate：同节点走 skynet 本地消息，跨节点走 cluster。两者都把原始字节交给 gate
    local function record_call(transport, node, cmd, ...)
        local op = { transport, cmd, ... }
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
        send = function(addr, proto, cmd, ...)
            t.expect(addr).to.equal(".session_gate")
            t.expect(proto).to.equal("lua")
            local op = record_call("local", nil, cmd, ...)
            if cmd == "kick" then
                record_kick(SELF_NODE, op[3])
            end
        end,
        call = function(addr, proto, cmd, ...)
            t.expect(addr).to.equal(".session_gate")
            t.expect(proto).to.equal("lua")
            record_call("local", nil, cmd, ...)
            if cmd == "bind" then
                return h.gate_bind_result ~= false
            end
            return true
        end,
    }, { __index = skynet })

    -- 跨节点的 gate 走 cluster：cluster.send/call 不像 skynet.send/call 带 proto，
    -- 参数直接就是 (node, address, cmd, ...)
    local fake_cluster = {
        send = function(node, addr, cmd, ...)
            t.expect(addr).to.equal(".session_gate")
            local op = record_call("cluster", node, cmd, ...)
            if cmd == "kick" then
                record_kick(node, op[4])
            end
        end,
        call = function(node, addr, cmd, ...)
            t.expect(addr).to.equal(".session_gate")
            record_call("cluster", node, cmd, ...)
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
        notify = function(key, name, msg)
            h.notifies[#h.notifies + 1] = { key = key, name = name, msg = msg }
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return SELF_NODE
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
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
    local ok = h.session.bind(gate_node, fd, entity, OWNER)
    return ok, h.session.key(gate_node, fd)
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
        local ok, key = bind(h, 9)
        t.expect(ok).to.equal(true)
        t.expect(key).to.equal("role1/9")
        t.expect(h.entity.session).to.equal({ gate_node = "role1", fd = 9, key = "role1/9" })
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
        local ok = h.session.bind("role1", 9, h.entity, OWNER)
        t.expect(ok).to.equal(false)
        t.expect(h.entity.session).to.be_nil()
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
        h.session.bind("role1", 9, h.entity, OWNER)
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
            h.session.bind("role1", 9, { type_name = "role", id = 7 }, OWNER)
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
end)

t.describe("session lookup", function()
    t.it("get_obj wraps a live entity and returns nil once it is gone", function()
        local h = harness()
        local _, key = bind(h, 9)
        t.expect(h.session.get_entity(key)).to.equal(h.entity)
        t.expect(h.session.get_obj(key)).to.equal({ entity = h.entity })
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
        h.session.kick("gate1/12")
        t.expect(h.kicks).to.equal({ { node = "gate1", fd = 12 } })
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "cluster", "gate1", "kick", 12 })
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
end)

t.describe("session push and sproto sender", function()
    t.it("push notifies the entity's own session", function()
        local h = harness()
        bind(h, 9)
        t.expect(h.session.push(h.entity, "mail_notify", { id = 1 })).to.equal(true)
        t.expect(h.notifies).to.equal({ { key = "role1/9", name = "mail_notify", msg = { id = 1 } } })
    end)

    t.it("push returns false when the entity is offline", function()
        local h = harness()
        t.expect(h.session.push(h.entity, "mail_notify", {})).to.equal(false)
        t.expect(h.notifies).to.equal({})
    end)

    t.it("installs a sproto sender that pushes encoded bytes to the owning gate", function()
        local h = harness()
        bind(h, 9)
        t.expect(h.sender).to.be_type("function")
        h.sender("role1/9", "RAWBYTES")
        t.expect(h.gate_ops[#h.gate_ops]).to.equal({ "local", "push", 9, "RAWBYTES" })
    end)

    t.it("the sender drops a package for a session that is gone", function()
        local h = harness()
        local _, key = bind(h, 9)
        h.session.unbind(key)
        local before = #h.gate_ops
        h.sender(key, "RAWBYTES")
        t.expect(#h.gate_ops).to.equal(before)
    end)
end)
