local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/entity/router.lua")

-- router 把"实体落在哪个节点"算完之后分成本地 / 跨节点两条路，
-- 这里把 skynet 与 cluster 都换成记录器，断言走的是哪条路、带了什么参数
local function harness(opts)
    opts = opts or {}
    local h = { calls = {} }

    local function record(tag, ...)
        local entry = table.pack(...)
        entry.tag = tag
        h.calls[#h.calls + 1] = entry
        return entry
    end

    local fake_skynet = {
        call = function(...)
            record("skynet.call", ...)
            return "called"
        end,
        send = function(...)
            if opts.local_send_error then
                error(opts.local_send_error)
            end
            record("skynet.send", ...)
        end,
    }
    local fake_cluster = {
        call = function(...)
            record("cluster.call", ...)
            return "called"
        end,
        send = function(...)
            if opts.remote_send_error then
                error(opts.remote_send_error)
            end
            record("cluster.send", ...)
        end,
    }
    local fake_config = {
        get = function(key)
            h.config_keys = h.config_keys or {}
            h.config_keys[#h.config_keys + 1] = key
            return "node1"
        end,
    }
    local fake_types = {
        calc_node = function(_, entity_id)
            -- 偶数 id 落本节点，奇数 id 落远端，方便一个用例里同时覆盖两条路
            return entity_id % 2 == 0 and "node1" or "node2"
        end,
        calc_agent_index = function()
            return 3
        end,
        format_agent_service_name = function(type_name, idx)
            return string.format(".entity_agent:%s:%d", type_name, idx)
        end,
    }
    local fake_msg = {
        save = function(type_name, entity_id, cmd, args)
            h.saved = { type_name = type_name, entity_id = entity_id, cmd = cmd, args = args }
            return opts.msg_id or 99
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        ["skyext.config"] = fake_config,
        ["skyext.entity.types"] = fake_types,
        ["skyext.entity.reliable_msg"] = fake_msg,
        ["skyext.log"] = {
            warn = function(msg, ...)
                h.warned = { msg = msg, ... }
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.router = assert(loadfile(source, "t", env))()
    return h
end

t.describe("entity.router", function()
    t.describe("call", function()
        t.it("本节点的实体直接走 skynet.call", function()
            local h = harness()
            local ret = h.router.call("role", 2, "ping", 1, 2)
            t.expect(ret).to.equal("called")
            local c = h.calls[1]
            t.expect(c.tag).to.equal("skynet.call")
            t.expect(c[1]).to.equal(".entity_agent:role:3")
            t.expect(c[2]).to.equal("lua")
            t.expect(c[3]).to.equal("entity_call")
            t.expect(c[4]).to.equal(2)
            t.expect(c[5]).to.equal("ping")
            t.expect(c[6]).to.equal(1)
            t.expect(c[7]).to.equal(2)
        end)

        t.it("外节点的实体走 cluster.call", function()
            local h = harness()
            h.router.call("role", 1, "ping")
            local c = h.calls[1]
            t.expect(c.tag).to.equal("cluster.call")
            t.expect(c[1]).to.equal("node2")
            t.expect(c[2]).to.equal(".entity_agent:role:3")
            t.expect(c[3]).to.equal("entity_call")
            t.expect(c[4]).to.equal(1)
            t.expect(c[5]).to.equal("ping")
        end)
    end)

    t.describe("send", function()
        t.it("本节点的实体直接走 skynet.send", function()
            local h = harness()
            h.router.send("role", 2, "ping", "x")
            local c = h.calls[1]
            t.expect(c.tag).to.equal("skynet.send")
            t.expect(c[3]).to.equal("entity_send")
            t.expect(c[4]).to.equal(2)
            t.expect(c[5]).to.equal("ping")
            t.expect(c[6]).to.equal("x")
        end)

        t.it("外节点的实体走 cluster.send", function()
            local h = harness()
            h.router.send("role", 1, "ping")
            local c = h.calls[1]
            t.expect(c.tag).to.equal("cluster.send")
            t.expect(c[1]).to.equal("node2")
            t.expect(c[3]).to.equal("entity_send")
        end)
    end)

    t.describe("poke_reliable", function()
        t.it("本节点投出 __deliver_reliable 唤醒", function()
            local h = harness()
            t.expect(h.router.poke_reliable("role", 2)).to.be_truthy()
            local c = h.calls[1]
            t.expect(c.tag).to.equal("skynet.send")
            t.expect(c[1]).to.equal(".entity_agent:role:3")
            t.expect(c[3]).to.equal("__deliver_reliable")
            t.expect(c[4]).to.equal(2)
            t.expect(c.n).to.equal(4)
        end)

        t.it("外节点通过 cluster 投出唤醒", function()
            local h = harness()
            t.expect(h.router.poke_reliable("role", 1)).to.be_truthy()
            local c = h.calls[1]
            t.expect(c.tag).to.equal("cluster.send")
            t.expect(c[1]).to.equal("node2")
            t.expect(c[2]).to.equal(".entity_agent:role:3")
            t.expect(c[3]).to.equal("__deliver_reliable")
            t.expect(c[4]).to.equal(1)
        end)

        -- 唤醒失败不该把异常抛给调用方：消息已经落库，重试定时器会补上
        t.it("本节点服务不存在时返回 false 而不是抛错", function()
            local h = harness({ local_send_error = "service not found" })
            t.expect(h.router.poke_reliable("role", 2)).to.equal(false)
        end)

        t.it("外节点不可达时返回 false 而不是抛错", function()
            local h = harness({ remote_send_error = "node down" })
            t.expect(h.router.poke_reliable("role", 1)).to.equal(false)
        end)

        t.it("只返回成功与否，不把 pcall 的多余返回值带出来", function()
            local h = harness()
            local a, b = h.router.poke_reliable("role", 2)
            t.expect(a).to.equal(true)
            t.expect(b).to.be_nil()
        end)
    end)

    t.describe("reliable_send", function()
        t.it("先落库再唤醒，并返回 msg_id", function()
            local h = harness({ msg_id = 1234 })
            local msg_id = h.router.reliable_send("role", 2, "mail", { 1, 2 })
            t.expect(msg_id).to.equal(1234)
            t.expect(h.saved.type_name).to.equal("role")
            t.expect(h.saved.entity_id).to.equal(2)
            t.expect(h.saved.cmd).to.equal("mail")
            t.expect(h.saved.args[2]).to.equal(2)
            t.expect(h.calls[1].tag).to.equal("skynet.send")
            t.expect(h.calls[1][3]).to.equal("__deliver_reliable")
            t.expect(h.warned).to.be_nil()
        end)

        -- 唤醒只是加速，消息已经落库，不能因为唤醒失败就让调用方以为没发出去
        t.it("唤醒失败仍然返回 msg_id 并记一条告警", function()
            local h = harness({ msg_id = 77, remote_send_error = "node down" })
            local msg_id = h.router.reliable_send("role", 1, "mail", {})
            t.expect(msg_id).to.equal(77)
            t.expect(h.warned).to.exist()
            t.expect(h.warned.msg).to.match("retry on load")
        end)
    end)
end)
