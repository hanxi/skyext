local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/cluster_discovery.lua")

local NODE_PREFIX = "/skynet/node/"
local ROLE_PREFIX = "/skynet/service/entity:role/"

local function kv(key, value, mod_revision)
    return { key = key, value = value, mod_revision = mod_revision }
end

local function readdir_result(kvs, revision)
    return { body = { kvs = kvs, header = { revision = revision } } }
end

-- etcd 的 revision 走 JSON 的 int64，线上收到的一律是字符串
local function put_event(key, value, mod_revision)
    return { type = "PUT", kv = kv(key, value, mod_revision) }
end

local function delete_event(key)
    return { type = "DELETE", kv = kv(key, nil, nil) }
end

local function batch(events, revision)
    return { result = { events = events, header = { revision = revision } } }
end

local function harness()
    local h = {
        published = {},
        reloads = {},
        forks = {},
        readdirs = {},
        timers = {},
        wakeups = {},
        grants = {},
        keepalives = {},
        setnxs = {},
        gets = {},
        revokes = {},
        mods = {},
        sets = {},
        deletes = {},
        watchdirs = {},
        opens = {},
        watches = {},
    }

    local noop = function() end

    local fake_etcd_client = {}

    function fake_etcd_client:readdir(key)
        h.readdirs[#h.readdirs + 1] = key
        local reply = h.replies[key]
        if type(reply) == "function" then
            reply = reply()
        end
        return reply
    end

    function fake_etcd_client:grant(ttl)
        h.grants[#h.grants + 1] = ttl
        if type(h.grant_reply) == "function" then
            return h.grant_reply(#h.grants)
        end
        return h.grant_reply, h.grant_err
    end

    function fake_etcd_client:keepalive(leaseid)
        h.keepalives[#h.keepalives + 1] = leaseid
        if type(h.keepalive_reply) == "function" then
            return h.keepalive_reply(#h.keepalives)
        end
        return h.keepalive_reply, h.keepalive_err
    end

    function fake_etcd_client:setnx(key, value, opts)
        h.setnxs[#h.setnxs + 1] = { key = key, value = value, opts = opts }
        if type(h.setnx_reply) == "function" then
            return h.setnx_reply(#h.setnxs)
        end
        return h.setnx_reply, h.setnx_err
    end

    function fake_etcd_client:get(key)
        h.gets[#h.gets + 1] = key
        return h.get_reply
    end

    function fake_etcd_client:revoke(lease)
        h.revokes[#h.revokes + 1] = lease
        if h.revoke_fail then
            return nil, "connection refused"
        end
        return { status = 200, body = {} }
    end

    function fake_etcd_client:mod(key, value, opts)
        h.mods[#h.mods + 1] = { key = key, value = value, opts = opts }
        return h.mod_reply, h.mod_err
    end

    function fake_etcd_client:set(key, value, opts)
        h.sets[#h.sets + 1] = { key = key, value = value, opts = opts }
        return h.set_reply, h.set_err
    end

    function fake_etcd_client:delete(key)
        h.deletes[#h.deletes + 1] = key
        return h.delete_reply, h.delete_err
    end

    -- watch 流是个可调用的 to-be-closed 对象，每调一次吐一批事件，吐完返回 nil 收尾
    function fake_etcd_client:watchdir(key, opts)
        h.watchdirs[#h.watchdirs + 1] = { key = key, opts = opts }
        local spec = h.watches[key] or {}
        local closable = { __close = noop }
        if spec.err then
            return setmetatable({}, closable), spec.err
        end
        local batches = spec.batches or {}
        local i = 0
        closable.__call = function()
            i = i + 1
            return batches[i]
        end
        return setmetatable({}, closable)
    end

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
            open = function(port)
                h.opens[#h.opens + 1] = port
            end,
        },
        ["skyext.timer"] = {
            repeat_immediately = function(name, interval, fn)
                local obj = { name = name, interval = interval, fn = fn }
                function obj:cancel()
                    h.timers[self.name] = nil
                end
                function obj:wakeup()
                    h.wakeups[#h.wakeups + 1] = self.name
                end
                h.timers[name] = obj
                return obj
            end,
        },
        ["skyext.event_channel_api"] = {
            init = noop,
            publish = function(channel, service, nodes)
                h.published[#h.published + 1] = { channel = channel, service = service, nodes = nodes }
            end,
        },
        -- 节点级租约的替身。申请与续租归 node_lease 服务管（见 service/node_lease.test.lua），
        -- 这里只模拟它对外的状态。
        ["skyext.node_lease"] = {
            valid = function()
                return h.lease_alive
            end,
            id = function()
                return h.lease_alive and h.lease_id or nil
            end,
            epoch = function()
                return h.lease_epoch
            end,
            on_lost = function(_, fn)
                h.on_lease_lost = fn
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
                elseif key == "cluster_listen_port" then
                    return 7001
                elseif key == "cluster_host" then
                    return "127.0.0.1"
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
        [NODE_PREFIX] = readdir_result({
            kv("/skynet/node/rolenode1", { address = "127.0.0.1:7001" }, "10"),
            kv("/skynet/node/rolenode2", { address = "127.0.0.1:7002" }, "11"),
        }, "11"),
    }

    -- 默认让整条注册链路走通，用例只改自己关心的那一环
    h.lease_alive = true
    h.lease_id = "777"
    h.lease_epoch = 1
    h.setnx_reply = { body = { succeeded = true, header = { revision = "101" } } }
    h.mod_reply = { body = { succeeded = true, header = { revision = "202" } } }
    h.set_reply = { body = { header = { revision = "303" } } }
    h.delete_reply = { body = {} }

    h.start = function()
        assert(loadfile(source, "t", env))()
        h.boot()
    end
    -- 跑一轮心跳 / 一轮租约续期
    h.tick = function()
        h.timers["cluster_discovery_heartbeat"].fn()
    end
    -- 节点租约失效：node_lease 广播，cluster_discovery 据此作废本地的已注册记账
    h.lose_lease = function()
        h.lease_alive = false
        assert(h.on_lease_lost, "lease lost callback not registered")(h.lease_epoch, "test")
    end
    h.regrant_lease = function()
        h.lease_alive = true
        h.lease_epoch = h.lease_epoch + 1
        h.lease_id = "lease-" .. h.lease_epoch
    end
    -- 让后台 watch 循环跑一轮就退出
    h.run_watch = function(fn)
        h.break_loop = true
        local ok, err = pcall(fn)
        h.break_loop = false
        assert(not ok and err == "test-break-loop", "watch loop did not reach sleep: " .. tostring(err))
    end
    return h
end

t.describe("cluster_discovery service discovery", function()
    t.it("reports the nodes serving a registered service, sorted", function()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result({
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
        h.replies[ROLE_PREFIX] = nil

        t.expect(h.CMD.query_service("entity:guild")).to.equal({})
        t.expect(#h.published).to.equal(0)
    end)

    t.it("does not publish a half-resolved snapshot", function()
        local h = harness()
        h.start()
        -- rolenode9 不在节点表里（节点 key 还没同步到），整份快照都不能算数
        h.replies[ROLE_PREFIX] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
            kv("/skynet/service/entity:role/rolenode9", { node_revision = 10 }),
        }, "12")

        t.expect(h.CMD.query_service("entity:role")).to.equal({})
        t.expect(#h.published).to.equal(0)
    end)

    t.it("keeps the previous snapshot when a later query comes back incomplete", function()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
        }, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({ "rolenode1" })

        local watch_loop = h.forks[#h.forks]
        h.replies[ROLE_PREFIX] = readdir_result({
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
        h.replies[ROLE_PREFIX] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 99 }),
        }, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({})
    end)

    t.it("creates one watch loop per service, not one per query", function()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result({}, "12")
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

    t.it("服务 key 不带节点名时整份快照作废", function()
        local h = harness()
        h.start()
        -- "/skynet/service/entity:role/" 这种半截 key 解不出节点名
        h.replies[ROLE_PREFIX] = readdir_result({ kv(ROLE_PREFIX, { node_revision = 10 }) }, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({})
    end)

    t.it("etcd 里一个服务节点都没有时返回空列表并照常广播", function()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result(nil, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({})
        t.expect(h.published[#h.published].nodes).to.equal({})
    end)
end)

-- 节点键和服务键都挂在节点级租约上。本服务自己不申请、不续租租约——从前它和实体锁
-- 各持一个，锁的没了而这里的还在，本节点就会继续留在服务列表里被路由进来，
-- 但每个实体都加不上锁。租约的生命周期测试在 service/node_lease.test.lua。
t.describe("cluster_discovery node lease", function()
    t.it("首轮心跳用节点租约注册节点，再把本地服务写进 etcd", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()

        -- 自己不再 grant：全节点只有 node_lease 一条申请路径
        t.expect(#h.grants).to.equal(0)
        t.expect(#h.keepalives).to.equal(0)
        t.expect(h.setnxs[1].key).to.equal("/skynet/node/rolenode1")
        t.expect(h.setnxs[1].value.address).to.equal("127.0.0.1:7001")
        t.expect(h.setnxs[1].opts).to.equal({ lease = "777" })
        t.expect(h.sets[1].key).to.equal("/skynet/service/entity:role/rolenode1")
        -- 服务项里带的 node_revision 是服务发现端校验新鲜度的唯一依据
        t.expect(h.sets[1].value.node_revision).to.equal(101)
    end)

    t.it("租约不可用时一个字都不往 etcd 写", function()
        local h = harness()
        h.lease_alive = false
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()

        t.expect(#h.setnxs).to.equal(0)
        t.expect(#h.sets).to.equal(0)
    end)

    t.it("租约还在时反复心跳不会重复注册", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        h.tick()
        h.tick()
        t.expect(#h.setnxs).to.equal(1)
        t.expect(#h.sets).to.equal(1)
    end)

    t.it("租约失效后换新租约重新注册节点和服务", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        t.expect(#h.sets).to.equal(1)

        -- 租约没了，etcd 已经把节点键和服务键一并删掉，本地的"已同步"记账全作废
        h.lose_lease()
        h.tick()
        t.expect(#h.setnxs).to.equal(1)

        h.regrant_lease()
        h.setnx_reply = { body = { succeeded = true, header = { revision = "999" } } }
        h.tick()
        t.expect(#h.setnxs).to.equal(2)
        t.expect(h.setnxs[2].opts).to.equal({ lease = "lease-2" })
        -- 节点 revision 换了，本地服务必须跟着重写一遍，否则发现端会按旧 revision 把它判为过期
        t.expect(#h.sets).to.equal(2)
        t.expect(h.sets[2].value.node_revision).to.equal(999)
    end)

    t.it("首次注册节点时按地址里的端口开集群监听，且只开一次", function()
        local h = harness()
        h.start()
        h.tick()
        t.expect(h.opens).to.equal({ 7001 })

        h.lose_lease()
        h.regrant_lease()
        h.tick()
        -- 重新注册时再 open 一次会撞端口
        t.expect(h.opens).to.equal({ 7001 })
    end)

    -- 停服时撤租约是 node_shutdown 的事：租约是节点级的，本节点别的服务还挂在上面
    t.it("停服只停注册，不撤销节点租约", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(#h.revokes).to.equal(0)
        t.expect(h.timers["cluster_discovery_heartbeat"]).to.be_nil()
    end)
end)

t.describe("cluster_discovery node registration conflicts", function()
    t.it("抢不到 key 但 etcd 里是本节点残留时，吊销旧租约后重新注册", function()
        local h = harness()
        h.start()
        h.setnx_reply = function(n)
            if n == 1 then
                return { body = { succeeded = false } }
            end
            return { body = { succeeded = true, header = { revision = "150" } } }
        end
        h.get_reply = {
            body = { kvs = { kv("/skynet/node/rolenode1", { address = "127.0.0.1:7001", lease = 555 }) } },
        }
        h.tick()

        t.expect(h.revokes).to.equal({ "555" })
        t.expect(#h.setnxs).to.equal(2)
    end)

    t.it("同名节点挂着别的地址时拒绝抢占，不去吊销别人的租约", function()
        local h = harness()
        h.start()
        h.setnx_reply = { body = { succeeded = false } }
        h.get_reply = {
            body = { kvs = { kv("/skynet/node/rolenode1", { address = "10.0.0.9:7001", lease = 555 }) } },
        }
        h.CMD.register({ "entity:role" })
        h.tick()

        -- 配置写重了的时候把对方踢下线，比自己起不来更糟
        t.expect(#h.revokes).to.equal(0)
        t.expect(#h.setnxs).to.equal(1)
        t.expect(#h.sets).to.equal(0)
    end)

    t.it("key 已被别人占着且 etcd 里查不到记录时放弃本轮，下一轮再试", function()
        local h = harness()
        h.start()
        h.setnx_reply = { body = { succeeded = false } }
        h.get_reply = { body = { kvs = {} } }
        h.tick()
        t.expect(#h.revokes).to.equal(0)
        t.expect(#h.setnxs).to.equal(1)

        h.tick()
        t.expect(#h.setnxs).to.equal(2)
    end)

    t.it("setnx 直接报错时不走吊销流程", function()
        local h = harness()
        h.start()
        h.setnx_reply = nil
        h.setnx_err = "etcd unavailable"
        h.tick()

        -- 请求压根没到 etcd，不能据此断定 key 是自己的残留
        t.expect(#h.gets).to.equal(0)
        t.expect(#h.revokes).to.equal(0)
    end)
end)

t.describe("cluster_discovery service sync", function()
    t.it("节点 revision 没变时不会每轮心跳都重写一遍 etcd", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        h.tick()
        h.tick()
        t.expect(#h.sets).to.equal(1)
    end)

    t.it("注销后的下一轮心跳把服务 key 从 etcd 删掉", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        h.CMD.unregister({ "entity:role" })
        h.tick()
        t.expect(h.deletes).to.equal({ "/skynet/service/entity:role/rolenode1" })

        -- 删过就不再重复删
        h.tick()
        t.expect(#h.deletes).to.equal(1)
    end)

    t.it("从来没同步成功过的服务被注销时不会发多余的 delete", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.CMD.unregister({ "entity:role" })
        h.tick()
        t.expect(#h.deletes).to.equal(0)
    end)

    t.it("写 etcd 失败时不记成已同步，下一轮继续重试", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.set_reply = nil
        h.set_err = "etcd unavailable"
        h.tick()
        t.expect(#h.sets).to.equal(1)

        -- 记成已同步的话这个服务就再也不会被写进 etcd，对外等于永久消失
        h.tick()
        t.expect(#h.sets).to.equal(2)
    end)

    t.it("删除失败时保留同步记录，下一轮继续重试删除", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        h.CMD.unregister({ "entity:role" })
        h.delete_reply = nil
        h.delete_err = "etcd unavailable"
        h.tick()
        h.tick()
        t.expect(#h.deletes).to.equal(2)
    end)

    t.it("注册和注销都会立刻唤醒心跳，不用干等一个心跳周期", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.CMD.unregister({ "entity:role" })
        t.expect(h.wakeups).to.equal({
            "cluster_discovery_heartbeat",
            "cluster_discovery_heartbeat",
        })
    end)
end)

t.describe("cluster_discovery node watch", function()
    t.it("watch 到新节点上线时把它加进集群地址表", function()
        local h = harness()
        h.start()
        h.watches[NODE_PREFIX] = {
            batches = {
                batch({ put_event("/skynet/node/rolenode3", { address = "127.0.0.1:7003" }, "20") }, "20"),
            },
        }
        h.run_watch(h.forks[1])

        t.expect(h.reloads[#h.reloads]["rolenode3"]).to.equal("127.0.0.1:7003")
    end)

    t.it("watch 到节点下线时把它在集群地址表里标成 false", function()
        local h = harness()
        h.start()
        h.watches[NODE_PREFIX] = { batches = { batch({ delete_event("/skynet/node/rolenode2") }, "20") } }
        h.run_watch(h.forks[1])

        -- 标 false 才会让 skynet.cluster 真的断开，直接去掉 key 只是不再更新
        t.expect(h.reloads[#h.reloads]["rolenode2"]).to.equal(false)
    end)

    t.it("watch 到已知节点换地址时更新集群地址表", function()
        local h = harness()
        h.start()
        h.watches[NODE_PREFIX] = {
            batches = {
                batch({ put_event("/skynet/node/rolenode2", { address = "127.0.0.1:7999" }, "20") }, "20"),
            },
        }
        h.run_watch(h.forks[1])

        -- 回归保护：etcd 的 mod_revision 是 JSON 字符串，首查时被 tonumber 过、watch 事件里没有，
        -- 两者直接比较会抛 "attempt to compare number with string"，
        -- 结果每次已知节点变更都把 watch 流打断，地址更新只能靠 500ms 后的整表重查兜底
        t.expect(h.reloads[#h.reloads]["rolenode2"]).to.equal("127.0.0.1:7999")
    end)

    t.it("watch 事件比本地已知的还旧时不覆盖地址", function()
        local h = harness()
        h.start()
        h.watches[NODE_PREFIX] = {
            batches = {
                batch({ put_event("/skynet/node/rolenode2", { address = "127.0.0.1:6666" }, "5") }, "20"),
            },
        }
        h.run_watch(h.forks[1])

        -- 乱序到达的旧事件会把刚迁移过的节点地址回退到老机器
        t.expect(h.reloads[#h.reloads]["rolenode2"]).to.equal("127.0.0.1:7002")
    end)

    t.it("watch 到解不出节点名的 key 时退出重连，不把半截 key 当节点", function()
        local h = harness()
        h.start()
        local before = #h.reloads
        h.watches[NODE_PREFIX] = {
            batches = {
                batch({ put_event(NODE_PREFIX, { address = "127.0.0.1:7003" }, "20") }, "20"),
                batch({ put_event("/skynet/node/rolenode3", { address = "127.0.0.1:7003" }, "21") }, "21"),
            },
        }
        h.run_watch(h.forks[1])

        -- 只应该有 first_query 那一次 reload，后面那批事件不该被处理
        t.expect(#h.reloads - before).to.equal(1)
        t.expect(h.reloads[#h.reloads]["rolenode3"]).to.be_nil()
    end)

    t.it("建不起 watch 流时退出等下一轮，不会空转", function()
        local h = harness()
        h.start()
        h.watches[NODE_PREFIX] = { err = "stream failed" }
        h.run_watch(h.forks[1])
        t.expect(#h.watchdirs).to.equal(1)
    end)

    t.it("首查节点表失败时根本不去建 watch 流", function()
        local h = harness()
        h.start()
        h.replies[NODE_PREFIX] = nil
        h.run_watch(h.forks[1])
        t.expect(#h.watchdirs).to.equal(0)
    end)

    t.it("节点 key 解不出名字时整份节点表作废，不保留半套", function()
        local h = harness()
        h.start()
        local before = #h.reloads
        h.replies[NODE_PREFIX] = readdir_result({ kv(NODE_PREFIX, { address = "127.0.0.1:7003" }, "10") }, "11")
        h.run_watch(h.forks[1])
        t.expect(#h.reloads).to.equal(before)
    end)

    t.it("etcd 里一个节点都没有时集群地址表跟着清空", function()
        local h = harness()
        h.start()
        h.replies[NODE_PREFIX] = readdir_result(nil, "12")
        h.run_watch(h.forks[1])

        local reloaded = h.reloads[#h.reloads]
        t.expect(reloaded["rolenode1"]).to.be_nil()
        t.expect(reloaded.__nowaiting).to.equal(true)
    end)

    t.it("节点 watch 里抛出的异常被兜住，发现服务不会整个挂掉", function()
        local h = harness()
        h.start()
        h.replies[NODE_PREFIX] = function()
            error("etcd blew up", 0)
        end
        -- run_watch 断言循环跑到了 sleep：异常没被 xpcall 兜住的话这里就到不了
        h.run_watch(h.forks[1])
        t.expect(#h.watchdirs).to.equal(0)
    end)

    t.it("watch 从上次见过的 revision 的下一个开始，不漏事件也不重放", function()
        local h = harness()
        h.start()
        h.watches[NODE_PREFIX] = { batches = {} }
        h.run_watch(h.forks[1])
        t.expect(h.watchdirs[1]).to.equal({ key = NODE_PREFIX, opts = { start_revision = 12 } })
    end)
end)

t.describe("cluster_discovery service watch", function()
    local function started_with_role()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
            kv("/skynet/service/entity:role/rolenode2", { node_revision = 11 }),
        }, "12")
        h.CMD.query_service("entity:role")
        return h, h.forks[#h.forks]
    end

    t.it("服务节点下线时摘掉它并广播新列表", function()
        local h, watch_loop = started_with_role()
        h.watches[ROLE_PREFIX] = {
            batches = { batch({ delete_event("/skynet/service/entity:role/rolenode2") }, "13") },
        }
        h.run_watch(watch_loop)

        t.expect(h.published[#h.published].nodes).to.equal({ "rolenode1" })
        t.expect(h.CMD.query_service("entity:role")).to.equal({ "rolenode1" })
    end)

    t.it("服务节点上线时加进列表并广播", function()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
        }, "12")
        h.CMD.query_service("entity:role")
        local watch_loop = h.forks[#h.forks]

        h.watches[ROLE_PREFIX] = {
            batches = {
                batch({ put_event("/skynet/service/entity:role/rolenode2", { node_revision = 11 }, "13") }, "13"),
            },
        }
        h.run_watch(watch_loop)
        t.expect(h.published[#h.published].nodes).to.equal({ "rolenode1", "rolenode2" })
    end)

    t.it("事件里的节点还没出现在节点表里时整轮放弃，不广播残缺列表", function()
        local h, watch_loop = started_with_role()
        local before = #h.published
        h.watches[ROLE_PREFIX] = {
            batches = {
                batch({ put_event("/skynet/service/entity:role/rolenode9", { node_revision = 11 }, "13") }, "13"),
            },
        }
        h.run_watch(watch_loop)

        -- watch 开头会重跑一次 first_query，那一次广播是正常的；
        -- 处理完事件后绝不能再广播，否则订阅方拿到的是缺了节点的列表
        t.expect(#h.published - before).to.equal(1)
        t.expect(h.published[#h.published].nodes).to.equal({ "rolenode1", "rolenode2" })
    end)

    t.it("服务 key 非法时退出 watch 等重连", function()
        local h, watch_loop = started_with_role()
        local before = #h.published
        h.watches[ROLE_PREFIX] = { batches = { batch({ put_event(ROLE_PREFIX, { node_revision = 10 }, "13") }, "13") } }
        h.run_watch(watch_loop)
        t.expect(#h.published - before).to.equal(1)
        t.expect(h.published[#h.published].nodes).to.equal({ "rolenode1", "rolenode2" })
    end)

    t.it("服务 watch 流建不起来时退出等下一轮", function()
        local h, watch_loop = started_with_role()
        h.watches[ROLE_PREFIX] = { err = "stream failed" }
        h.run_watch(watch_loop)
        t.expect(h.watchdirs[#h.watchdirs].key).to.equal(ROLE_PREFIX)
    end)

    t.it("服务 watch 从首查到的 revision 的下一个开始", function()
        local h, watch_loop = started_with_role()
        h.watches[ROLE_PREFIX] = { batches = {} }
        h.run_watch(watch_loop)
        t.expect(h.watchdirs[#h.watchdirs].opts).to.equal({ start_revision = 13 })
    end)

    t.it("服务 watch 里抛出的异常被兜住，等下一轮重试", function()
        local h, watch_loop = started_with_role()
        h.replies[ROLE_PREFIX] = function()
            error("etcd blew up", 0)
        end
        h.run_watch(watch_loop)
    end)

    t.it("服务项缺 node_revision 时首查抛错，但不会把服务对象锁死在半初始化状态", function()
        local h = harness()
        h.start()
        h.replies[ROLE_PREFIX] = readdir_result({ kv("/skynet/service/entity:role/rolenode1", {}) }, "12")
        t.expect(function()
            h.CMD.query_service("entity:role")
        end).to
            .throw()

        -- inited 不回滚的话这个服务就再也不会建 watch 循环，之后每次查询都只能拿到空列表
        h.replies[ROLE_PREFIX] = readdir_result({
            kv("/skynet/service/entity:role/rolenode1", { node_revision = 10 }),
        }, "12")
        t.expect(h.CMD.query_service("entity:role")).to.equal({ "rolenode1" })
    end)
end)

t.describe("cluster_discovery shutdown", function()
    t.it("停服后不再往 etcd 写，重复调用和后续注册都不报错", function()
        local h = harness()
        h.start()
        h.CMD.register({ "entity:role" })
        h.tick()
        t.expect(h.CMD.shutdown()).to.equal(true)
        t.expect(h.CMD.shutdown()).to.equal(true)
        -- 停服后再有注册/注销也不能因为心跳定时器没了而报错
        h.CMD.register({ "entity:other" })
        h.CMD.unregister({ "entity:other" })
        t.expect(#h.setnxs).to.equal(1)
        t.expect(#h.sets).to.equal(1)
    end)
end)
