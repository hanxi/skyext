local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/cluster_discovery.lua")

local function kv(key, value, mod_revision)
    return { key = key, value = value, mod_revision = mod_revision }
end

local function readdir_result(kvs, revision)
    return { body = { kvs = kvs, header = { revision = revision } } }
end

-- 只覆盖发现（读）这一半：注册、租约续期要连真的 etcd，放在集成测试里
local function harness()
    local h = { published = {}, reloads = {}, forks = {}, readdirs = {} }

    local fake_etcd_client = {}
    function fake_etcd_client:readdir(key)
        h.readdirs[#h.readdirs + 1] = key
        local reply = h.replies[key]
        if type(reply) == "function" then
            reply = reply()
        end
        return reply
    end

    local noop = function() end
    local fake_timer_obj = { cancel = noop, wakeup = noop }

    local imports = {
        skynet = setmetatable({
            -- 心跳和 watch 循环都是死循环，测试里只记下来不跑
            fork = function(fn)
                h.forks[#h.forks + 1] = fn
            end,
            start = function(fn)
                h.boot = fn
            end,
            -- watch 循环是 while true，测试里靠 sleep 抛错把它从中间打断
            sleep = function()
                if h.break_loop then
                    error("test-break-loop", 0)
                end
            end,
        }, { __index = skynet }),
        ["skyext.etcd"] = {
            new = function()
                return fake_etcd_client
            end,
        },
        ["skynet.cluster"] = {
            reload = function(node2address)
                h.reloads[#h.reloads + 1] = node2address
            end,
            open = noop,
        },
        ["skyext.timer"] = {
            repeat_immediately = function()
                return fake_timer_obj
            end,
        },
        ["skyext.event_channel_api"] = {
            init = noop,
            publish = function(channel, service, nodes)
                h.published[#h.published + 1] = { channel = channel, service = service, nodes = nodes }
            end,
        },
        ["skyext.cmd_api"] = {
            dispatch = function(commands)
                h.CMD = commands
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                if key == "cluster_node_name" then
                    return "rolenode1"
                end
                return nil
            end,
            get_table = function()
                return { http_host = "http://127.0.0.1:2379" }
            end,
        },
        ["skyext.log"] = setmetatable({}, {
            __index = function()
                return noop
            end,
        }),
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })

    h.replies = {
        ["/skynet/node/"] = readdir_result({
            kv("/skynet/node/rolenode1", { address = "127.0.0.1:7001" }, "10"),
            kv("/skynet/node/rolenode2", { address = "127.0.0.1:7002" }, "11"),
        }, "11"),
    }

    h.start = function()
        assert(loadfile(source, "t", env))()
        h.boot()
    end
    return h
end

t.describe("cluster_discovery service discovery", function()
    t.it("reports the nodes serving a registered service, sorted", function()
        local h = harness()
        h.start()
        h.replies["/skynet/service/entity:role/"] = readdir_result({
            kv("/skynet/service/entity:role/rolenode2", { node_revision = 11 }),
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
        }, "12")

        -- 节点集合是从哈希表遍历出来的，排序后路由方和日志拿到的才是稳定的列表
        t.expect(h.CMD.query_service("entity:role")).to.equal({ "rolenode1", "rolenode2" })
        t.expect(h.published[#h.published]).to.equal({
            channel = "service_change",
            service = "entity:role",
            nodes = { "rolenode1", "rolenode2" },
        })
    end)

    t.it("answers with an empty list instead of crashing before the first query lands", function()
        -- etcd 在首查时不可用：以前 map_node 还是 nil，query_service 直接炸在 pairs(nil) 上，
        -- 而且 inited 已经置位，之后每次查询都会以同样的方式失败
        local h = harness()
        h.start()
        h.replies["/skynet/service/entity:guild/"] = nil

        t.expect(h.CMD.query_service("entity:guild")).to.equal({})
        t.expect(#h.published).to.equal(0)
    end)

    t.it("does not publish a half-resolved snapshot", function()
        local h = harness()
        h.start()
        -- rolenode9 不在节点表里（节点 key 还没同步到），整份快照都不能算数
        h.replies["/skynet/service/entity:role/"] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
            kv("/skynet/service/entity:role/rolenode9", { node_revision = 10 }),
        }, "12")

        t.expect(h.CMD.query_service("entity:role")).to.equal({})
        t.expect(#h.published).to.equal(0)
    end)

    t.it("keeps the previous snapshot when a later query comes back incomplete", function()
        local h = harness()
        h.start()
        h.replies["/skynet/service/entity:role/"] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
        }, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({ "rolenode1" })

        local watch_loop = h.forks[#h.forks]
        h.replies["/skynet/service/entity:role/"] = readdir_result({
            kv("/skynet/service/entity:role/rolenode9", { node_revision = 10 }),
        }, "13")
        -- watch 循环重入 first_query 失败，不能把已知的节点抹成空集
        h.break_loop = true
        t.expect(select(2, pcall(watch_loop))).to.equal("test-break-loop")
        h.break_loop = false
        t.expect(h.CMD.query_service("entity:role")).to.equal({ "rolenode1" })
    end)

    t.it("rejects a service entry whose node revision is newer than the known node", function()
        local h = harness()
        h.start()
        h.replies["/skynet/service/entity:role/"] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 99 }),
        }, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({})
    end)

    t.it("creates one watch loop per service, not one per query", function()
        local h = harness()
        h.start()
        h.replies["/skynet/service/entity:role/"] = readdir_result({}, "12")
        local before = #h.forks
        h.CMD.query_service("entity:role")
        h.CMD.query_service("entity:role")
        h.CMD.query_service("entity:role")
        t.expect(#h.forks - before).to.equal(1)
    end)

    t.it("publishes the known nodes to skynet cluster at boot", function()
        local h = harness()
        h.start()
        local reloaded = h.reloads[#h.reloads]
        t.expect(reloaded["rolenode1"]).to.equal("127.0.0.1:7001")
        t.expect(reloaded["rolenode2"]).to.equal("127.0.0.1:7002")
        t.expect(reloaded.__nowaiting).to.equal(true)
    end)
end)
