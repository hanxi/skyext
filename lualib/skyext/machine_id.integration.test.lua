local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

if os.getenv("SKYTEST_INTEGRATION") ~= "1" then
    return
end

local etcd = require "skyext.etcd"
local root = fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir())
local lock_source = fs.join(root, "lualib/skyext/distributed_lock.lua")
local lease_source = fs.join(root, "service/node_lease.lua")
local id_source = fs.join(root, "lualib/skyext/machine_id.lua")
local unique = string.format("%d_%d_%d", os.time(), skynet.self(), math.random(1, 1000000000))
local etcd_config = {
    http_host = os.getenv("ETCD_ENDPOINTS") or "http://127.0.0.1:2379",
    key_prefix = "/skyext-integration/machine_id/" .. unique .. "/",
}

local function load_module(source, imports)
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    return assert(loadfile(source, "t", env))()
end

local etcd_imports = {
    new = function(cfg)
        return assert(etcd.new(cfg))
    end,
}
local config_imports = {
    get_table = function()
        return etcd_config
    end,
}

-- 起一份真的 node_lease 服务实例，返回 skyext.node_lease 那层的客户端视角。
-- 不拿假租约糊弄：这个测试要验的就是真租约被吊销后整条失效链路还通不通。
local function new_lease(node, log)
    local CMD
    local on_lost = {}
    local epoch = 0

    load_module(lease_source, {
        skynet = setmetatable({
            start = function(fn)
                node.lease_start = fn
            end,
        }, { __index = skynet }),
        ["skyext.etcd"] = {
            new = function(cfg)
                local client = assert(etcd.new(cfg))
                node.client = client
                -- 记下租约号，后面要靠吊销它来制造“号被抢走”的局面
                local grant = client.grant
                client.grant = function(self, ttl)
                    local ret, err = grant(self, ttl)
                    node.leaseid = ret and ret.body and ret.body.ID
                    return ret, err
                end
                return client
            end,
        },
        ["skyext.config"] = config_imports,
        ["skyext.timer"] = {
            repeat_delayed = function(_, _, fn)
                node.heartbeat = fn
                return { cancel = function() end }
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(cmd)
                CMD = cmd
            end,
        },
        ["skyext.event_channel_api"] = {
            init = function() end,
            publish = function(name, ...)
                if name ~= "lease_lost" then
                    return
                end
                for _, fn in ipairs(on_lost) do
                    fn(...)
                end
            end,
        },
        ["skyext.log"] = log,
    })
    node.lease_start()

    local function snapshot()
        local s = CMD.get()
        if s then
            epoch = s.epoch
        end
        return s
    end
    return {
        valid = function()
            return snapshot() ~= nil
        end,
        id = function()
            local s = snapshot()
            return s and s.leaseid
        end,
        epoch = function()
            snapshot()
            return epoch
        end,
        on_lost = function(_, fn)
            on_lost[#on_lost + 1] = fn
        end,
    }
end

-- 每个 node 模拟一个独立进程：自带一个节点租约，锁挂在它上面
local function new_node(node_name)
    local node = {}
    local noop = function() end
    local log = { info = noop, warn = noop, error = noop }

    node.lock = load_module(lock_source, {
        skynet = setmetatable({
            init = function(fn)
                node.init = fn
            end,
        }, { __index = skynet }),
        ["skyext.etcd"] = etcd_imports,
        ["skyext.config"] = config_imports,
        ["skyext.node_lease"] = new_lease(node, log),
        ["skyext.log"] = log,
    })
    node.init()

    node.machine_id = load_module(id_source, {
        skynet = setmetatable({
            fork = function(fn)
                node.forked = fn
            end,
            sleep = function()
                error("unexpected claim retry")
            end,
        }, { __index = skynet }),
        ["skyext.distributed_lock"] = node.lock,
        ["skyext.config"] = {
            get = function()
                return node_name
            end,
        },
        ["skyext.log"] = log,
    })
    return node
end

t.describe("machine id etcd integration", function()
    t.it("hands two processes different slots out of the same range", function()
        -- 同名两个进程会从同一个位置开始探测，第二个必须真的看到 etcd 上的占用
        local first = new_node("itnode")
        local second = new_node("itnode")
        local slot_a = first.machine_id.new("snowflake", 64)
        local slot_b = second.machine_id.new("snowflake", 64)
        slot_a:acquire()
        slot_b:acquire()

        t.expect(slot_a.id).to.exist()
        t.expect(slot_b.id).to.equal((slot_a.id + 1) % 64)
        t.expect(slot_a:valid()).to.equal(true)
        t.expect(slot_b:valid()).to.equal(true)
    end)

    t.it("drops the slot when the lease is revoked and claims another one", function()
        local node = new_node("itnode-revoke")
        local slot = node.machine_id.new("snowflake", 64)
        slot:acquire()
        local lost = slot.id
        t.expect(slot:valid()).to.equal(true)

        -- 租约没了，etcd 上那把锁也就跟着消失，这个号随时可能被别人接手
        t.expect(node.client:revoke(node.leaseid).status).to.equal(200)
        node.heartbeat()
        t.expect(slot:valid()).to.equal(false)
        t.expect(slot.id).to.be_nil()

        assert(node.forked, "no reclaim scheduled")()
        t.expect(slot:valid()).to.equal(true)
        -- 丢过的号不原地捡回来
        t.expect(slot.id == lost).to.equal(false)
    end)
end)
