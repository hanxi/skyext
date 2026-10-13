local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/client_ext.lua")

local function harness(opts)
    opts = opts or {}
    local h = { kicks = {}, gate_calls = 0 }
    local noop = function() end

    h.entity = { type_name = "role", id = 7 }

    local fake_mgr = {}
    -- 行为对齐 entitymgr:with_loaded_entity：进不去串行队列时返回 false, reason，
    -- 处理期间丢租约同样返回 false
    function fake_mgr:with_loaded_entity(id, f)
        h.gate_calls = h.gate_calls + 1
        h.gate_id = id
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

    local fake_skynet = setmetatable({
        localname = function(name)
            t.expect(name).to.equal(".gate")
            return 100
        end,
        call = function(addr, proto, cmd, fd)
            t.expect(addr).to.equal(100)
            t.expect(proto).to.equal("lua")
            t.expect(cmd).to.equal("kick")
            h.kicks[#h.kicks + 1] = fd
        end,
    }, { __index = skynet })

    local imports = {
        skynet = fake_skynet,
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.client_ext = assert(loadfile(source, "t", env))()
    if not opts.no_mgr then
        h.client_ext.init(fake_mgr)
    end
    h.mgr = fake_mgr
    return h
end

t.describe("client_ext request gating", function()
    t.it("runs the handler inside the entity gate and keeps all of its return values", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        local ok, a, b = h.client_ext.with_request(9, function()
            return "pack", 3
        end)
        t.expect(ok).to.equal(true)
        t.expect(a).to.equal("pack")
        t.expect(b).to.equal(3)
        t.expect(h.gate_id).to.equal(7)
    end)

    t.it("reports success when the handler produced nothing", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        local ok, result = h.client_ext.with_request(9, function() end)
        t.expect(ok).to.equal(true)
        t.expect(result).to.be_nil()
    end)

    t.it("rejects with a reason instead of silently dropping unbound requests", function()
        local h = harness()
        local ran = false
        local ok, reason = h.client_ext.with_request(9, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client not bound")
        t.expect(ran).to.equal(false)
        t.expect(h.gate_calls).to.equal(0)
    end)

    t.it("rejects requests that arrive before the entity manager is ready", function()
        local h = harness({ no_mgr = true })
        h.client_ext.bind(9, h.entity)
        local ok, reason = h.client_ext.with_request(9, function() end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("entity manager not ready")
    end)

    t.it("rejects when the entity is gone or its lease expired", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        h.not_loaded = true
        local ran = false
        local ok, reason = h.client_ext.with_request(9, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("entity not loaded or lease expired")
        t.expect(ran).to.equal(false)

        h.not_loaded = false
        h.expire_during = true
        local ok2, reason2 = h.client_ext.with_request(9, function()
            return "pack"
        end)
        t.expect(ok2).to.equal(false)
        t.expect(reason2).to.equal("entity lease expired during handler")
    end)

    t.it("rejects a request whose connection was unbound while it waited in the queue", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        local ran = false
        h.before_handler = function()
            h.client_ext.unbind(9)
        end
        local ok, reason = h.client_ext.with_request(9, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
        t.expect(h.touched).to.equal(7)
    end)

    t.it("rejects a request whose fd was rebound to another entity while it waited", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        local ran = false
        h.before_handler = function()
            h.client_ext.unbind(9)
            h.client_ext.bind(9, { type_name = "role", id = 7 })
        end
        local ok, reason = h.client_ext.with_request(9, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
    end)

    t.it("rejects when the gate handed over a reloaded entity instance", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        h.active = { type_name = "role", id = 7 }
        local ran = false
        local ok, reason = h.client_ext.with_request(9, function()
            ran = true
        end)
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("client binding revoked")
        t.expect(ran).to.equal(false)
    end)

    t.it("lets handler errors propagate so the caller can answer the client", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        t.expect(function()
            h.client_ext.with_request(9, function()
                error("boom")
            end)
        end).to
            .throw("boom")
    end)
end)

t.describe("client_ext disconnect", function()
    t.it("kicks without unbinding so the normal disconnect flow still runs", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        h.client_ext.reject_client(9, "client binding revoked")
        t.expect(h.kicks).to.equal({ 9 })
        t.expect(h.client_ext.get_entity(9)).to.equal(h.entity)
        t.expect(h.entity.fd).to.equal(9)
        t.expect(h.touched).to.be_nil()
    end)

    t.it("unbinds and kicks when the entity side drops the connection", function()
        local h = harness()
        h.client_ext.bind(9, h.entity)
        t.expect(h.client_ext.unbind_kick(9, h.entity)).to.equal(true)
        t.expect(h.kicks).to.equal({ 9 })
        t.expect(h.client_ext.get_entity(9)).to.be_nil()
        t.expect(h.entity.fd).to.be_nil()
        t.expect(h.touched).to.equal(7)
    end)

    t.it("does not disconnect a new binding when an old entity kick runs late", function()
        local h = harness()
        local old_entity = { type_name = "role", id = 7 }
        h.client_ext.bind(9, old_entity)
        old_entity.fd = nil
        h.client_ext.bind(9, h.entity)

        t.expect(h.client_ext.unbind_kick(9, old_entity)).to.equal(false)
        t.expect(h.client_ext.get_entity(9)).to.equal(h.entity)
        t.expect(h.entity.fd).to.equal(9)
        t.expect(h.kicks).to.equal({})
        t.expect(h.touched).to.be_nil()
    end)
end)
