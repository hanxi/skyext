local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local codec = require "skyext.etcd.codec"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd/kv.lua")

local function harness(opts)
    opts = opts or {}
    local h = { posts = {} }

    local fake_transport = {}
    function fake_transport.post(_, uri, body, timeout)
        h.posts[#h.posts + 1] = { uri = uri, body = body, timeout = timeout }
        if opts.on_post then
            return opts.on_post(h)
        end
        return { status = 200, body = { header = { revision = 7 } } }
    end

    local modules = { ["skyext.etcd.transport"] = fake_transport }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    h.kv = assert(loadfile(source, "t", env))().methods
    h.cli = { key_prefix = opts.key_prefix or "/tenant/", timeout = 5 }
    return h
end

local function last(h)
    return h.posts[#h.posts]
end

local function key_of(doc)
    return codec.decode_base64(doc.key)
end

local function value_of(doc)
    return codec.decode_value(doc.value)
end

t.describe("etcd.kv", function()
    t.describe("set", function()
        t.it("key 带前缀，value 先 JSON 再 base64", function()
            local h = harness()
            assert(h.kv.set(h.cli, "a/b", { x = 1 }))
            local post = last(h)
            t.expect(post.uri).to.equal("/v3/kv/put")
            t.expect(key_of(post.body)).to.equal("/tenant/a/b")
            t.expect(value_of(post.body).x).to.equal(1)
        end)

        t.it("透传 lease 与 prev_kv", function()
            local h = harness()
            h.kv.set(h.cli, "a", 1, { lease = "7587848", prev_kv = true, timeout = 2 })
            t.expect(last(h).body.lease).to.equal("7587848")
            t.expect(last(h).body.prev_kv).to.equal(true)
            t.expect(last(h).timeout).to.equal(2)
        end)

        t.it("没传超时就用客户端默认超时", function()
            local h = harness()
            h.kv.set(h.cli, "a", 1)
            t.expect(last(h).timeout).to.equal(5)
        end)

        t.it("空 key 直接报错，不发请求", function()
            local h = harness()
            local res, err = h.kv.set(h.cli, "", 1)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("empty")
            t.expect(#h.posts).to.equal(0)
        end)
    end)

    t.describe("get", function()
        t.it("读单个 key 并解码返回值", function()
            local h = harness({
                on_post = function()
                    return {
                        status = 200,
                        body = {
                            kvs = {
                                { key = codec.encode_base64("/tenant/a"), value = codec.encode_value({ x = 1 }) },
                            },
                        },
                    }
                end,
            })
            local res = assert(h.kv.get(h.cli, "a"))
            t.expect(last(h).uri).to.equal("/v3/kv/range")
            t.expect(key_of(last(h).body)).to.equal("/tenant/a")
            t.expect(last(h).body.range_end).to.be_nil()
            t.expect(res.body.kvs[1].key).to.equal("/tenant/a")
            t.expect(res.body.kvs[1].value.x).to.equal(1)
        end)

        t.it("非 200 不去解码，避免在错误响应上二次报错", function()
            local h = harness({
                on_post = function()
                    return { status = 404, body = { error = "not found" } }
                end,
            })
            local res = assert(h.kv.get(h.cli, "a"))
            t.expect(res.body.error).to.equal("not found")
        end)
    end)

    t.describe("readdir", function()
        t.it("按前缀扫描，range_end 建在完整 key 上", function()
            local h = harness()
            h.kv.readdir(h.cli, "node/")
            local post = last(h)
            t.expect(key_of(post.body)).to.equal("/tenant/node/")
            t.expect(codec.decode_base64(post.body.range_end)).to.equal("/tenant/node0")
        end)

        t.it("透传分页与排序参数", function()
            local h = harness()
            h.kv.readdir(h.cli, "node/", { limit = 10, sort_order = "ASCEND", keys_only = true, revision = 3 })
            local post = last(h)
            t.expect(post.body.limit).to.equal(10)
            t.expect(post.body.sort_order).to.equal("ASCEND")
            t.expect(post.body.keys_only).to.equal(true)
            t.expect(post.body.revision).to.equal(3)
        end)
    end)

    t.describe("delete 与 rmdir", function()
        t.it("delete 只删单个 key", function()
            local h = harness()
            h.kv.delete(h.cli, "a")
            t.expect(last(h).uri).to.equal("/v3/kv/deleterange")
            t.expect(key_of(last(h).body)).to.equal("/tenant/a")
            t.expect(last(h).body.range_end).to.be_nil()
        end)

        t.it("rmdir 删整个前缀", function()
            local h = harness()
            h.kv.rmdir(h.cli, "node/")
            t.expect(codec.decode_base64(last(h).body.range_end)).to.equal("/tenant/node0")
        end)
    end)

    t.describe("setnx / setx / mod", function()
        t.it("setnx 比较 create_revision=0，命中成功分支才写", function()
            local h = harness()
            h.kv.setnx(h.cli, "lock", "owner", { lease = "42" })
            local body = last(h).body
            t.expect(last(h).uri).to.equal("/v3/kv/txn")
            t.expect(body.compare[1].target).to.equal("CREATE")
            t.expect(body.compare[1].create_revision).to.equal(0)
            t.expect(key_of(body.compare[1])).to.equal("/tenant/lock")
            t.expect(value_of(body.success[1].requestPut)).to.equal("owner")
            t.expect(body.success[1].requestPut.lease).to.equal("42")
            t.expect(body.failure).to.be_nil()
        end)

        t.it("setx 写在失败分支，key 已存在时才生效", function()
            local h = harness()
            h.kv.setx(h.cli, "lock", "owner")
            local body = last(h).body
            t.expect(body.success).to.be_nil()
            t.expect(value_of(body.failure[1].requestPut)).to.equal("owner")
        end)

        t.it("mod 用 mod_revision 做乐观锁", function()
            local h = harness()
            h.kv.mod(h.cli, "node/a", { v = 1 }, { mod_revision = 99, lease = "42" })
            local body = last(h).body
            t.expect(body.compare[1].target).to.equal("MOD")
            t.expect(body.compare[1].mod_revision).to.equal(99)
            t.expect(value_of(body.success[1].requestPut).v).to.equal(1)
        end)

        -- 少了 mod_revision 的 mod 会退化成无条件覆盖，必须拦住
        t.it("mod 缺少 mod_revision 时报错", function()
            local h = harness()
            local res, err = h.kv.mod(h.cli, "a", 1, {})
            t.expect(res).to.be_nil()
            t.expect(err).to.match("mod_revision")
            t.expect(#h.posts).to.equal(0)
        end)
    end)

    t.describe("txn", function()
        t.it("compare、成功分支、失败分支里的 key 都加前缀", function()
            local h = harness()
            assert(h.kv.txn(h.cli, {
                { target = "CREATE", key = "lock/a", create_revision = 0 },
            }, {
                { requestDeleteRange = { key = "lock/a" } },
            }, {
                { requestPut = { key = "lock/a", value = "node-a", lease = 1 } },
                { requestRange = { key = "lock/a" } },
            }))
            local body = last(h).body
            t.expect(last(h).uri).to.equal("/v3/kv/txn")
            t.expect(key_of(body.compare[1])).to.equal("/tenant/lock/a")
            t.expect(body.compare[1].create_revision).to.equal(0)
            t.expect(key_of(body.success[1].requestDeleteRange)).to.equal("/tenant/lock/a")
            t.expect(key_of(body.failure[1].requestPut)).to.equal("/tenant/lock/a")
            t.expect(value_of(body.failure[1].requestPut)).to.equal("node-a")
            t.expect(body.failure[1].requestPut.lease).to.equal(1)
            t.expect(key_of(body.failure[2].requestRange)).to.equal("/tenant/lock/a")
        end)

        t.it("compare 里的 value 也编码", function()
            local h = harness()
            h.kv.txn(h.cli, {
                { target = "VALUE", key = "a", result = "EQUAL", value = "mine" },
            }, {
                { requestDeleteRange = { key = "a" } },
            }, nil)
            t.expect(value_of(last(h).body.compare[1])).to.equal("mine")
        end)

        -- 原始规则表是调用方的，编码不能就地改写，否则重试时 key 会被二次加前缀
        t.it("不改写调用方传进来的表", function()
            local h = harness()
            local compare = { { target = "CREATE", key = "lock/a", create_revision = 0 } }
            local success = { { requestPut = { key = "lock/a", value = "node-a" } } }
            h.kv.txn(h.cli, compare, success, nil)
            t.expect(compare[1].key).to.equal("lock/a")
            t.expect(success[1].requestPut.key).to.equal("lock/a")
            t.expect(success[1].requestPut.value).to.equal("node-a")
        end)

        t.it("compare 为空时报错", function()
            local h = harness()
            local res, err = h.kv.txn(h.cli, {}, { { requestRange = { key = "a" } } }, nil)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("compare")
            t.expect(#h.posts).to.equal(0)
        end)

        t.it("两个分支都为空时报错", function()
            local h = harness()
            local res, err = h.kv.txn(h.cli, { { target = "CREATE", key = "a", create_revision = 0 } }, nil, nil)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("same time")
        end)

        t.it("分支里的 key 不合法时报错且不发请求", function()
            local h = harness()
            local res, err = h.kv.txn(h.cli, {
                { target = "CREATE", key = "a", create_revision = 0 },
            }, {
                { requestPut = { key = "", value = 1 } },
            }, nil)
            t.expect(res).to.be_nil()
            t.expect(err).to.match("empty")
            t.expect(#h.posts).to.equal(0)
        end)
    end)

    t.it("没有配置前缀时 key 原样使用", function()
        local h = harness({ key_prefix = "" })
        h.kv.set(h.cli, "/node/a", 1)
        t.expect(key_of(last(h).body)).to.equal("/node/a")
    end)
end)
