local t = require "skytest"
local skynet = require "skynet"
local queue = require "skynet.queue"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local errcode = require "skyext.errcode"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/entity_agent.lua")

local function harness()
    local h = { events = {}, bound = {}, calls = {}, deliveries = 0 }
    local noop = function() end
    local gates = {}
    local entity = { id = 7, data = { name = "before" } }
    h.entity = entity
    local fake_mgr = {}
    function fake_mgr:with_entity(id, f)
        t.expect(id).to.equal(7)
        local gate = gates[id]
        if not gate then
            gate = queue()
            gates[id] = gate
        end
        return gate(function()
            if h.with_entity_error then
                return false, h.with_entity_error
            end
            local result = table.pack(f(entity))
            return true, table.unpack(result, 1, result.n)
        end)
    end
    function fake_mgr:with_loaded_entity(id, f)
        t.expect(id).to.equal(7)
        if h.lease_expired then
            return false, "expired"
        end
        return self:with_entity(id, f)
    end
    function fake_mgr:try_ensure_loaded(id)
        t.expect(id).to.equal(7)
        return not h.lock_error, h.lock_error, h.owner
    end
    function fake_mgr:unload(id)
        t.expect(id).to.equal(7)
        h.events[#h.events + 1] = "unload"
        return h.unload_ok ~= false
    end
    function fake_mgr:deliver_pending(id)
        t.expect(id).to.equal(7)
        h.deliveries = h.deliveries + 1
        return h.deliver_ok ~= false, h.deliver_error
    end
    h.mgr = fake_mgr

    local fake_client = {}
    function fake_client.init(manager)
        t.expect(manager).to.equal(fake_mgr)
    end
    function fake_client.get_entity(fd)
        return h.bound[fd]
    end
    function fake_client.bind(fd, e)
        h.bound[fd] = e
        e.fd = fd
        h.events[#h.events + 1] = "bind"
    end
    function fake_client.unbind(fd)
        local e = h.bound[fd]
        h.bound[fd] = nil
        if e then
            e.fd = nil
        end
        h.events[#h.events + 1] = "unbind"
    end
    function fake_client.unbind_kick(fd, expected_entity)
        t.expect(expected_entity).to.equal(h.bound[fd])
        fake_client.unbind(fd)
        h.events[#h.events + 1] = "kick"
    end

    local fake_cluster = {}
    function fake_cluster.call(node, agent, command, id)
        h.cluster_call = { node, agent, command, id }
        if h.cluster_error then
            error(h.cluster_error)
        end
        return h.cluster_released ~= false
    end

    h.handler = {
        handlers = {
            change = function(e, value)
                h.events[#h.events + 1] = "handler-start"
                if h.pause_handler then
                    skynet.sleep(5)
                end
                e.data.name = value
                h.events[#h.events + 1] = "handler-end"
                return value, nil, 3
            end,
        },
        on_bind_client = function(_, fd)
            h.events[#h.events + 1] = "on_bind:" .. fd
        end,
        on_unbind_client = function()
            h.events[#h.events + 1] = "on_unbind"
        end,
    }
    local fake_skynet = setmetatable({
        start = function(fn)
            h.boot = fn
        end,
        register = function(name)
            h.registered = name
        end,
        call = function(addr, _, command)
            h.forward = { addr, command }
        end,
        self = function()
            return 200
        end,
    }, { __index = skynet })
    local imports = {
        skynet = fake_skynet,
        ["skyext.cmd_api"] = {
            dispatch = function(commands)
                h.CMD = commands
            end,
        },
        ["skyext.entity.types"] = {
            get = function()
                return { client_enabled = true }
            end,
            format_agent_service_name = function()
                return ".entity_agent:role:1"
            end,
            calc_agent_index = function()
                return 1
            end,
        },
        ["skyext.entity.entitymgr"] = {
            new = function()
                return fake_mgr
            end,
        },
        ["skyext.entity.client_ext"] = fake_client,
        ["skyext.log"] = { info = noop, warn = noop, error = noop },
        ["skyext.errcode"] = errcode,
        ["skynet.cluster"] = fake_cluster,
        ["entity_handler.role"] = h.handler,
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))("role", "1")
    h.boot()
    h.CMD.start({ modules_path = "modules", modules = {}, watchdog = 123 })
    return h
end

t.describe("entity_agent serialized ingress", function()
    t.it("runs RPC handlers through the entity gate and preserves multiple return values", function()
        local h = harness()
        local a, b, c = h.CMD.entity_call(7, "change", "new")
        t.expect(a).to.equal("new")
        t.expect(b).to.be_nil()
        t.expect(c).to.equal(3)
        t.expect(h.entity.data.name).to.equal("new")
        h.with_entity_error = "no lease"
        t.expect(h.CMD.entity_call(7, "change", "ignored")).to.equal(errcode.LOCK_FAILED)
        t.expect(h.entity.data.name).to.equal("new")
    end)

    t.it("serializes concurrent entity_call and entity_send handlers for one entity", function()
        local h = harness()
        h.pause_handler = true
        local done = 0
        skynet.fork(function()
            h.CMD.entity_call(7, "change", "first")
            done = done + 1
        end)
        skynet.sleep(1)
        skynet.fork(function()
            h.CMD.entity_send(7, "change", "second")
            done = done + 1
        end)
        for _ = 1, 30 do
            if done == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(done).to.equal(2)
        t.expect(h.events).to.equal({ "handler-start", "handler-end", "handler-start", "handler-end" })
        t.expect(h.entity.data.name).to.equal("second")
    end)

    t.it("does not bind a client while a handler owns the entity gate", function()
        local h = harness()
        h.pause_handler = true
        local done = 0
        skynet.fork(function()
            h.CMD.entity_call(7, "change", "first")
            done = done + 1
        end)
        skynet.sleep(1)
        skynet.fork(function()
            t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.OK)
            done = done + 1
        end)
        skynet.sleep(1)
        t.expect(h.bound[9]).to.be_nil()
        for _ = 1, 30 do
            if done == 2 then
                break
            end
            skynet.sleep(1)
        end
        t.expect(done).to.equal(2)
        t.expect(h.events).to.equal({ "handler-start", "handler-end", "bind", "on_bind:9" })
    end)

    t.it("wakes ordered persistent delivery instead of executing or acknowledging inline", function()
        local h = harness()
        t.expect(h.CMD.__deliver_reliable(7, 11, "missing", { "ignored" })).to.equal(true)
        t.expect(h.deliveries).to.equal(1)
        t.expect(h.events).to.equal({})
        h.deliver_ok = false
        h.deliver_error = "persistence failed"
        t.expect(h.CMD.__deliver_reliable(7)).to.equal(false)
        t.expect(h.deliveries).to.equal(2)
    end)

    t.it("remote handoff uses a verified owner and requires confirmed unload", function()
        local h = harness()
        h.lock_error = "etcd unavailable"
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.LOCK_FAILED)
        t.expect(h.cluster_call).to.be_nil()
        h.lock_error = "lock held"
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.LOCK_FAILED)
        h.owner = "node-b"
        h.cluster_released = false
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.IN_OTHER_NODE)
        t.expect(h.cluster_call).to.equal({ "node-b", ".entity_agent:role:1", "unload_entity", 7 })
        t.expect(h.bound[9]).to.be_nil()
        h.cluster_error = "node down"
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.IN_OTHER_NODE)
        h.cluster_error = nil
        h.cluster_released = true
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.OK)
        t.expect(h.bound[9]).to.equal(h.entity)
        t.expect(h.forward).to.equal({ 123, "forward" })
    end)

    t.it("disconnect respects the entity gate and unbinds an expired client", function()
        local h = harness()
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.OK)
        h.CMD.disconnect(9)
        t.expect(h.bound[9]).to.be_nil()
        t.expect(h.events[#h.events]).to.equal("on_unbind")
        h.CMD.bind_client(7, 10)
        h.lease_expired = true
        h.CMD.disconnect(10)
        t.expect(h.bound[10]).to.be_nil()
        t.expect(h.events[#h.events]).to.equal("unbind")
    end)

    t.it("propagates unload success or failure to the remote handoff caller", function()
        local h = harness()
        h.unload_ok = false
        t.expect(h.CMD.unload_entity(7)).to.equal(false)
        h.unload_ok = true
        t.expect(h.CMD.unload_entity(7)).to.equal(true)
    end)
end)
