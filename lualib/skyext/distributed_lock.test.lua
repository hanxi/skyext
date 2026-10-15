local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local crypt = require "skynet.crypt"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/distributed_lock.lua")

local function harness(opts)
    opts = opts or {}
    local h = { now = 0, revision = 0, lease = 0, locks = {}, grants = 0 }
    local client = {}
    function client:grant(ttl)
        t.expect(ttl).to.equal(30)
        h.grants = h.grants + 1
        if h.fail_grant then
            return nil, "no quorum"
        end
        h.lease = h.lease + 1
        return { status = 200, body = { ID = h.lease } }
    end
    function client:keepalive(lease)
        h.keepalives = (h.keepalives or 0) + 1
        if h.fail_keepalive then
            return nil, "no quorum"
        end
        return { status = 200, body = { result = { TTL = 30, ID = lease } } }
    end
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
                                        value = crypt.base64encode(existing.value),
                                    },
                                }
                            or {},
                    },
                },
            }
        end
        return reply
    end

    local imports = {
        skynet = {
            init = function(fn)
                h.init = fn
            end,
            now = function()
                return h.now
            end,
        },
        ["skyext.etcd"] = {
            new = function()
                return client
            end,
        },
        ["skyext.timer"] = {
            repeat_delayed = function(name, sec, fn)
                h.heartbeat_name = name
                h.heartbeat_interval = sec
                h.heartbeat = fn
            end,
        },
        ["skyext.config"] = {
            get_table = function()
                return {}
            end,
        },
        ["skyext.log"] = { info = function() end, error = function() end },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.lock = assert(loadfile(source, "t", env))()
    h.fail_grant = opts.fail_grant
    h.init()
    h.fail_grant = nil
    return h
end

t.describe("distributed lock lease and fencing", function()
    t.it("returns a fenced handle only with a live lease and never revives an expired one", function()
        local h = harness()
        local ok, first = h.lock.try_lock("role:7", "owner")
        t.expect(ok).to.equal(true)
        t.expect(first.fence).to.equal(1)
        t.expect(h.lock.is_valid(first)).to.equal(true)
        local _, same = h.lock.try_lock("role:7", "owner")
        t.expect(same).to.equal(first)
        t.expect(h.transactions).to.equal(1)

        h.now = 2800
        t.expect(h.lock.is_valid(first)).to.equal(false)
        t.expect(first.valid).to.equal(false)
        t.expect(h.lock.try_lock("role:7", "owner")).to.equal(false)
        h.locks[first.my_key] = nil -- etcd expires the old lease and key
        h.heartbeat()
        local acquired, successor = h.lock.try_lock("role:7", "successor")
        t.expect(acquired).to.equal(true)
        t.expect(successor.fence).to.be_gt(first.fence)
        t.expect(h.lock.is_valid(first)).to.equal(false)
        t.expect(h.lock.unlock("role:7", first)).to.equal(false)
        t.expect(h.lock.is_valid(successor)).to.equal(true)
    end)

    t.it("invalidates all handles once when keepalive fails", function()
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
        h.fail_keepalive = true
        h.heartbeat()
        t.expect(calls).to.equal(2)
        t.expect(h.lock.is_valid(first)).to.equal(false)
        t.expect(h.lock.is_valid(second)).to.equal(false)
        h.heartbeat()
        t.expect(calls).to.equal(2)
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

    -- 回归：租约以前是心跳定时器异步申请的，模块加载完到第一轮心跳之间
    -- 所有 try_lock 都会失败。snowflake 抢机器号正好落在这个窗口里。
    t.it("holds a usable lease as soon as init returns", function()
        local h = harness()
        t.expect(h.grants).to.equal(1)
        local ok, handle = h.lock.try_lock("role:9", "owner")
        t.expect(ok).to.equal(true)
        t.expect(h.lock.is_valid(handle)).to.equal(true)
        -- 心跳只续租，不会再批一个租约出来
        t.expect(h.heartbeat_name).to.equal("distributed_lock_heartbeat")
        t.expect(h.heartbeat_interval).to.equal(10)
        h.heartbeat()
        t.expect(h.grants).to.equal(1)
        t.expect(h.keepalives).to.equal(1)
        t.expect(h.lock.is_valid(handle)).to.equal(true)
    end)

    t.it("starts anyway when etcd cannot grant a lease and recovers on the next heartbeat", function()
        local h = harness({ fail_grant = true })
        t.expect(h.grants).to.equal(1)
        local ok, err = h.lock.try_lock("role:9", "owner")
        t.expect(ok).to.equal(false)
        t.expect(err).to.equal("etcd lease unavailable")

        h.heartbeat()
        t.expect(h.grants).to.equal(2)
        t.expect(h.keepalives).to.be_nil()
        t.expect(h.lock.try_lock("role:9", "owner")).to.equal(true)
    end)

    t.it("锁被别的节点占着时如实返回持锁节点名", function()
        local h = harness()
        -- 另一个节点先拿到了锁：etcd 里是它写的裸字符串，响应里 base64 过一道
        h.locks["/skynet/lock/entity/role/7"] = { revision = 41, lease = 999, value = "rolenode2" }
        local ok, reason, owner = h.lock.try_lock("entity/role/7", "rolenode1")
        t.expect(ok).to.equal(false)
        t.expect(reason).to.equal("lock held")
        -- 回归保护：这里曾经对裸字符串做 cjson.decode，owner 恒为 nil，
        -- 上层据此做的实体交接从来没触发过
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
