local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local codec = require "skyext.etcd.codec"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/distributed_lock.lua")

local function harness(opts)
    opts = opts or {}
    local h = { revision = 0, locks = {} }
    local client = {}
    function client:txn(compare, success, failure)
        h.transactions = (h.transactions or 0) + 1
        local rule = assert(compare[1])
        t.expect(rule.target).to.equal("CREATE")
        local existing = h.locks[rule.key]
        local matched = (existing and existing.revision or 0) == rule.create_revision
        local chosen = matched and success or failure
        local operation = chosen and chosen[1]
        local reply = { status = 200, body = { succeeded = matched } }
        if matched and operation and operation.requestPut then
            h.revision = h.revision + 1
            local put = operation.requestPut
            h.locks[rule.key] = { revision = h.revision, lease = put.lease, value = put.value }
            reply.body.header = { revision = h.revision }
        elseif matched and operation and operation.requestDeleteRange then
            t.expect(operation.requestDeleteRange.key).to.equal(rule.key)
            h.locks[rule.key] = nil
        elseif not matched and operation and operation.requestRange then
            reply.body.responses = {
                {
                    response_range = {
                        kvs = existing
                                and {
                                    {
                                        create_revision = existing.revision,
                                        lease = existing.lease,
                                        -- 和真实客户端一样：值先 JSON 再 base64
                                        value = codec.encode_value(existing.value),
                                    },
                                }
                            or {},
                    },
                },
            }
        end
        return reply
    end

    -- 节点级租约的替身。租约的申请与续租归 node_lease 服务管（见 service/node_lease.test.lua），
    -- 这里只模拟它对外的三个状态：还活着、换了一代、没了。
    local lease = { id = "lease-1", epoch = 1, alive = not opts.no_lease, on_lost = {} }
    h.lease = lease
    -- 租约失效：node_lease 会先置失效再广播，订阅方据此隔离
    function h.lose_lease(reason)
        lease.alive = false
        for _, fn in ipairs(lease.on_lost) do
            fn(lease.epoch, reason or "test")
        end
    end
    -- 重新批了一个租约：etcd 已经把旧租约上的锁键全删了
    function h.regrant()
        lease.alive = true
        lease.epoch = lease.epoch + 1
        lease.id = "lease-" .. lease.epoch
    end

    local noop = function() end
    local imports = {
        skynet = {
            init = function(fn)
                h.init = fn
            end,
        },
        ["skyext.etcd"] = {
            new = function()
                return client
            end,
        },
        ["skyext.node_lease"] = {
            valid = function()
                return lease.alive
            end,
            id = function()
                return lease.alive and lease.id or nil
            end,
            epoch = function()
                return lease.epoch
            end,
            on_lost = function(_, fn)
                lease.on_lost[#lease.on_lost + 1] = fn
            end,
        },
        ["skyext.config"] = {
            get_table = function()
                return {}
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.lock = assert(loadfile(source, "t", env))()
    h.init()
    return h
end

t.describe("distributed lock fencing", function()
    t.it("returns a fenced handle only with a live lease and never revives an expired one", function()
        local h = harness()
        local ok, first = h.lock.try_lock("role:7", "owner")
        t.expect(ok).to.equal(true)
        t.expect(first.fence).to.equal(1)
        t.expect(h.lock.is_valid(first)).to.equal(true)
        local _, same = h.lock.try_lock("role:7", "owner")
        t.expect(same).to.equal(first)
        t.expect(h.transactions).to.equal(1)

        h.lose_lease("deadline elapsed")
        t.expect(h.lock.is_valid(first)).to.equal(false)
        t.expect(first.valid).to.equal(false)
        t.expect(h.lock.try_lock("role:7", "owner")).to.equal(false)

        h.locks[first.my_key] = nil -- etcd 随旧租约一起删掉了锁键
        h.regrant()
        local acquired, successor = h.lock.try_lock("role:7", "successor")
        t.expect(acquired).to.equal(true)
        t.expect(successor.fence).to.be_gt(first.fence)
        t.expect(h.lock.is_valid(first)).to.equal(false)
        t.expect(h.lock.unlock("role:7", first)).to.equal(false)
        t.expect(h.lock.is_valid(successor)).to.equal(true)
    end)

    -- 换代即失效：新租约下旧锁键已经被 etcd 删了，别的节点随时可能接手同一个实体，
    -- 旧句柄的 fence 绝不能继续当成有效
    t.it("invalidates handles from a superseded lease epoch", function()
        local h = harness()
        local _, handle = h.lock.try_lock("role:7", "owner")
        h.regrant()
        t.expect(h.lock.is_valid(handle)).to.equal(false)
    end)

    t.it("invalidates every handle exactly once when the node lease is lost", function()
        local h = harness()
        local calls = 0
        local _, first = h.lock.try_lock("role:1", "owner", function(expired)
            t.expect(expired.valid).to.equal(false)
            calls = calls + 1
        end)
        local _, second = h.lock.try_lock("role:2", "owner", function(expired)
            t.expect(expired.valid).to.equal(false)
            calls = calls + 1
        end)
        h.lose_lease()
        t.expect(calls).to.equal(2)
        t.expect(h.lock.is_valid(first)).to.equal(false)
        t.expect(h.lock.is_valid(second)).to.equal(false)
        h.lose_lease()
        t.expect(calls).to.equal(2)
    end)

    t.it("refuses to lock while the node lease is unavailable", function()
        local h = harness({ no_lease = true })
        local ok, err = h.lock.try_lock("role:9", "owner")
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("etcd lease unavailable")
    end)

    t.it("releases the held revision without firing an expiry callback", function()
        local h = harness()
        local expired = 0
        local _, handle = h.lock.try_lock("role:4", "owner", function()
            expired = expired + 1
        end)
        t.expect(h.lock.unlock("role:4", handle)).to.equal(true)
        t.expect(h.locks[handle.my_key]).to.be_nil()
        t.expect(h.lock.is_valid(handle)).to.equal(false)
        t.expect(expired).to.equal(0)
    end)

    t.it("does not delete a successor's key when the compare-and-delete fails", function()
        local h = harness()
        local expired = 0
        local _, first = h.lock.try_lock("role:3", "old", function()
            expired = expired + 1
        end)
        h.revision = h.revision + 1
        h.locks[first.my_key] = { revision = h.revision, lease = 99, value = "other" }
        t.expect(h.lock.unlock("role:3", first)).to.equal(false)
        t.expect(h.locks[first.my_key].value).to.equal("other")
        t.expect(expired).to.equal(1)
        t.expect(h.lock.is_valid(first)).to.equal(false)
        local acquired = h.lock.try_lock("role:3", "old")
        t.expect(acquired).to.equal(false)
    end)

    t.it("锁被别的节点占着时如实返回持锁节点名", function()
        local h = harness()
        -- 另一个节点先拿到了锁：它写的是节点名，响应里是 JSON 再 base64
        h.locks["/skynet/lock/entity/role/7"] = { revision = 41, lease = 999, value = "rolenode2" }
        local ok, reason, owner = h.lock.try_lock("entity/role/7", "rolenode1")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("lock held")
        -- 回归保护：这里曾经只解 base64，拿到带引号的 "\"rolenode2\""，
        -- 上层的交接和转发全打到不存在的节点上
        t.expect(owner).to.equal("rolenode2")
    end)

    t.it("持锁方没写锁值时 owner 是 nil 而不是空串", function()
        local h = harness()
        h.locks["/skynet/lock/entity/role/7"] = { revision = 41, lease = 999, value = "" }
        local ok, reason, owner = h.lock.try_lock("entity/role/7", "rolenode1")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("lock held")
        t.expect(owner).to.be_nil()
    end)
end)

t.describe("distributed lock shutdown", function()
    -- 租约是节点级的，本节点别的服务还挂在上面，所以这里只是本服务停止加锁。
    -- 锁键真正从 etcd 消失是 node_shutdown 撤销节点租约的时候。
    t.it("drops every lock without expiry callbacks and refuses new ones", function()
        local h = harness()
        local expired = 0
        local _, handle = h.lock.try_lock("machine_id/snowflake/3", "node", function()
            expired = expired + 1
        end)
        t.expect(h.lock.shutdown()).to.equal(true)
        t.expect(h.lock.is_valid(handle)).to.equal(false)
        -- 主动放手不是失租：machine_id 收到过期回调会去重新抢号
        t.expect(expired).to.equal(0)
        t.expect(table.pack(h.lock.try_lock("role:1", "node"))).to.equal({ false, "lock service closed", n = 2 })
        t.expect(h.lock.shutdown()).to.equal(true)
    end)
end)
