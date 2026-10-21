local t = require "skytest"
local skynet = require "skynet"
local queue = require "skynet.queue"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local errcode = require "skyext.errcode"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/entity_agent.lua")

local function harness(opts)
    opts = opts or {}
    local h = {
        events = {},
        bound = {},
        calls = {},
        deliveries = 0,
        cluster_calls = 0,
        registered_modules = {},
    }
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
                return false, h.with_entity_error, h.with_entity_owner
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
    function fake_mgr:unload_all()
        h.events[#h.events + 1] = "unload_all"
        return h.unload_remaining or 0
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
    function fake_mgr:deliver_pending(id, opts)
        t.expect(id).to.equal(7)
        h.deliveries = h.deliveries + 1
        h.deliver_opts = opts
        if h.with_entity_error then
            return false, h.with_entity_error, h.with_entity_owner
        end
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
    function fake_cluster.call(node, agent, command, id, ...)
        h.cluster_call = { node, agent, command, id, ... }
        h.cluster_calls = h.cluster_calls + 1
        if h.cluster_error then
            error(h.cluster_error)
        end
        if h.release_clears_lock then
            -- 上一个持有者真的放了手：之后的重试应该能拿到实体
            h.with_entity_error = nil
            h.lock_error = nil
        end
        if command ~= "unload_entity" then
            -- 持锁节点对转发请求的回复
            return table.unpack(h.remote_reply or { true }, 1, h.remote_reply and h.remote_reply.n or 1)
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
            NOT_LOADED = "not loaded",
            new = function()
                return fake_mgr
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                if key == "cluster_node_name" then
                    return "node-a"
                end
            end,
        },
        ["skyext.entity.client_ext"] = fake_client,
        ["skyext.log"] = { info = noop, warn = noop, error = noop },
        ["skyext.errcode"] = errcode,
        ["skynet.cluster"] = fake_cluster,
        ["entity_handler.role"] = h.handler,
        ["skyext.sproto_api"] = {
            register_module = function(name, module, request)
                t.expect(module).to.equal(fake_client)
                h.registered_modules[#h.registered_modules + 1] = { name = name, request = request }
            end,
        },
    }
    for name, mod in pairs(opts.module_sources or {}) do
        imports[name] = mod
    end
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))("role", "1")
    h.boot()
    h.start_conf = { modules_path = "modules", modules = opts.modules or {}, watchdog = 123 }
    if not opts.manual_start then
        h.CMD.start(h.start_conf)
    end
    return h
end

t.describe("entity_agent serialized ingress", function()
    t.it("runs RPC handlers through the entity gate and preserves multiple return values", function()
        local h = harness()
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ true, "new", nil, 3, n = 4 })
        t.expect(h.entity.data.name).to.equal("new")
        h.with_entity_error = "no lease"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "ignored"))).to.equal({ false, "no lease", n = 2 })
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

    t.it("does not hand off to itself when its previous process still holds the lock", function()
        local h = harness()
        h.lock_error = "lock held"
        h.owner = "node-a"
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.LOCK_FAILED)
        t.expect(h.cluster_calls).to.equal(0)
    end)

    t.it("reports a missing entity instead of a lock failure", function()
        local h = harness()
        h.lock_error = "not found"
        t.expect(h.CMD.bind_client(7, 9)).to.equal(errcode.ENTITY_NOT_FOUND)
    end)

    t.it("forwards a call to the node holding the lock instead of taking the entity", function()
        -- 集群成员变化后路由指到了这里，但实体还在上一个节点上：转过去执行，不卸载
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.remote_reply = table.pack(true, "remote")
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ true, "remote", n = 2 })
        t.expect(h.cluster_call).to
            .equal({ "node-b", ".entity_agent:role:1", "entity_call_loaded", 7, "change", "new" })
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.events).to.equal({})
        t.expect(h.entity.data.name).to.equal("before")
    end)

    t.it("runs locally once more when the holder has already unloaded the entity", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.release_clears_lock = true
        h.remote_reply = table.pack(false, "not loaded")
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ true, "new", nil, 3, n = 4 })
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.entity.data.name).to.equal("new")
    end)

    t.it("gives up after one forward so two nodes cannot bounce a request", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.remote_reply = table.pack(false, "not loaded")
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "lock held", n = 2 })
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.entity.data.name).to.equal("before")
    end)

    t.it("raises a failed forward instead of retrying it locally", function()
        -- 分不清是没送到还是对方 handler 执行到一半，重试可能让副作用发生两次
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.cluster_error = "node down"
        t.expect(function()
            h.CMD.entity_call(7, "change", "new")
        end).to
            .throw("node down")
        t.expect(h.cluster_calls).to.equal(1)
        t.expect(h.entity.data.name).to.equal("before")
    end)

    t.it("does not forward without an owner, to itself, or for other failures", function()
        local h = harness()
        h.with_entity_error = "lock held"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "lock held", n = 2 })
        h.with_entity_owner = "node-a"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "lock held", n = 2 })
        h.with_entity_error = "entity lease expired"
        h.with_entity_owner = "node-b"
        t.expect(table.pack(h.CMD.entity_call(7, "change", "new"))).to.equal({ false, "entity lease expired", n = 2 })
        t.expect(h.cluster_calls).to.equal(0)
    end)

    t.it("entity_send is forwarded the same way", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        h.CMD.entity_send(7, "change", "sent")
        t.expect(h.cluster_call).to
            .equal({ "node-b", ".entity_agent:role:1", "entity_call_loaded", 7, "change", "sent" })
        t.expect(h.events).to.equal({})
    end)

    t.it("forwarded calls only touch an entity that is already loaded", function()
        local h = harness()
        t.expect(table.pack(h.CMD.entity_call_loaded(7, "change", "fwd"))).to.equal({ true, "fwd", nil, 3, n = 4 })
        h.lease_expired = true
        t.expect(table.pack(h.CMD.entity_call_loaded(7, "change", "late"))).to.equal({ false, "expired", n = 2 })
        t.expect(h.entity.data.name).to.equal("fwd")
    end)

    t.it("wakes reliable delivery on the node holding the lock", function()
        local h = harness()
        h.with_entity_error = "lock held"
        h.with_entity_owner = "node-b"
        t.expect(h.CMD.__deliver_reliable(7)).to.equal(true)
        t.expect(h.cluster_call).to.equal({ "node-b", ".entity_agent:role:1", "deliver_reliable_loaded", 7 })
        h.with_entity_error = nil
        t.expect(h.CMD.deliver_reliable_loaded(7)).to.equal(true)
        t.expect(h.deliver_opts).to.equal({ loaded_only = true })
    end)

    t.it("shutdown unloads every entity and reports what is left", function()
        local h = harness()
        t.expect(h.CMD.shutdown()).to.equal(0)
        h.unload_remaining = 2
        t.expect(h.CMD.shutdown()).to.equal(2)
        t.expect(h.events).to.equal({ "unload_all", "unload_all" })
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

t.describe("entity_agent module loading", function()
    local MODULES = {
        { name = "bag", init = true, request = true },
        { name = "mail", init = false, request = true },
        { name = "note", init = true, request = false },
    }

    local function sources()
        return {
            ["modules.bag"] = { new = function() end },
            ["modules.bag.request"] = { use = function() end },
            ["modules.mail.request"] = { read = function() end },
            ["modules.note"] = { new = function() end },
        }
    end

    t.it("registers exactly the request modules that exist on disk", function()
        local src = sources()
        local h = harness({ modules = MODULES, module_sources = src })
        t.expect(h.registered_modules).to.equal({
            { name = "bag", request = src["modules.bag.request"] },
            { name = "mail", request = src["modules.mail.request"] },
        })
    end)

    t.it("only keeps init modules that expose new", function()
        local h = harness({
            modules = {
                { name = "bag", init = true, request = false },
                { name = "plain", init = true, request = false },
            },
            module_sources = {
                ["modules.bag"] = { new = function() end },
                ["modules.plain"] = { helper = function() end },
            },
        })
        t.expect(h.registered_modules).to.equal({})
    end)

    -- 回归：路径配错时 require 失败必须炸掉启动。
    -- 以前这里是 pcall 吞掉的，结果协议一个都没注册，客户端只能看到超时。
    t.it("fails agent start when a request module cannot be loaded", function()
        local src = sources()
        src["modules.mail.request"] = nil
        local h = harness({ modules = MODULES, module_sources = src, manual_start = true })
        t.expect(function()
            h.CMD.start(h.start_conf)
        end).to
            .throw("modules.mail.request")
        t.expect(h.registered_modules).to.equal({ { name = "bag", request = src["modules.bag.request"] } })
    end)

    t.it("fails agent start when an init module cannot be loaded", function()
        local src = sources()
        src["modules.bag"] = nil
        local h = harness({ modules = MODULES, module_sources = src, manual_start = true })
        t.expect(function()
            h.CMD.start(h.start_conf)
        end).to
            .throw("modules.bag")
    end)

    t.it("rejects a request module that does not return a table", function()
        local src = sources()
        src["modules.mail.request"] = function() end
        local h = harness({ modules = MODULES, module_sources = src, manual_start = true })
        t.expect(function()
            h.CMD.start(h.start_conf)
        end).to
            .throw("modules%.mail%.request must return a table")
    end)
end)
