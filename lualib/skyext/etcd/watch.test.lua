local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"
local cjson = require "cjson.safe"
local codec = require "skyext.etcd.codec"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/etcd/watch.lua")

-- opts.chunks 是依次返回的 HTTP chunk；opts.status 是流的响应码
local function harness(opts)
    opts = opts or {}
    local h = { posts = {}, closed = 0, failures = {} }

    local chunks = opts.chunks or {}
    local idx = 0
    local stream = setmetatable({ status = opts.status or 200 }, {
        __call = function()
            idx = idx + 1
            return chunks[idx]
        end,
    })
    stream.close = function()
        h.closed = h.closed + 1
    end

    local fake_transport = {}
    function fake_transport.post_stream(cli, uri, body, timeout)
        h.posts[#h.posts + 1] = { uri = uri, body = body, timeout = timeout }
        if opts.stream_error then
            return nil, opts.stream_error
        end
        return { cli = cli, stream = stream, endpoint = { http_host = "http://a:2379" } }
    end
    function fake_transport.report_failure(_, host)
        h.failures[#h.failures + 1] = host
    end

    local modules = {
        ["skyext.etcd.transport"] = fake_transport,
        ["skyext.log"] = {
            warn = function() end,
            error = function() end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return modules[name] or require(name)
        end,
    }, { __index = _G })
    h.watch = assert(loadfile(source, "t", env))().methods
    h.cli = { key_prefix = "/tenant/", timeout = 5 }
    return h
end

local function event_chunk(events)
    return cjson.encode({ result = { events = events } })
end

t.describe("etcd.watch", function()
    t.describe("建流", function()
        t.it("watch 只盯单个 key，不带 range_end", function()
            local h = harness()
            local w <close> = h.watch.watch(h.cli, "node/a")
            t.expect(h.posts[1].uri).to.equal("/v3/watch")
            local req = h.posts[1].body.create_request
            t.expect(codec.decode_base64(req.key)).to.equal("/tenant/node/a")
            t.expect(req.range_end).to.be_nil()
            t.expect(w).to.exist()
        end)

        t.it("watchdir 按前缀盯整个目录", function()
            local h = harness()
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local req = h.posts[1].body.create_request
            t.expect(codec.decode_base64(req.key)).to.equal("/tenant/node/")
            t.expect(codec.decode_base64(req.range_end)).to.equal("/tenant/node0")
            t.expect(w).to.exist()
        end)

        t.it("透传 start_revision 等参数", function()
            local h = harness()
            local w <close> = h.watch.watchdir(h.cli, "node/", { start_revision = 42, prev_kv = true, watch_id = 7 })
            local req = h.posts[1].body.create_request
            t.expect(req.start_revision).to.equal(42)
            t.expect(req.prev_kv).to.equal(true)
            t.expect(req.watch_id).to.equal(7)
            t.expect(w).to.exist()
        end)

        t.it("key 不是字符串时报错", function()
            local h = harness()
            local w, err = h.watch.watch(h.cli, 123)
            t.expect(w).to.be_nil()
            t.expect(err).to.match("string")
        end)

        -- 调用方用的是 <close> 变量，建流失败也得给一个能关的对象
        t.it("建流失败时返回可关闭的空壳与错误", function()
            local h = harness({ stream_error = "node down" })
            local w, err = h.watch.watchdir(h.cli, "node/")
            t.expect(err).to.equal("node down")
            t.expect(w).to.exist()
            t.expect(select(2, w())).to.match("not initialized")
            t.expect(function()
                local scoped <close> = w
                t.expect(scoped).to.exist()
            end).to_not
                .throw()
        end)
    end)

    t.describe("读事件", function()
        t.it("解码 PUT 事件的 key 与 value", function()
            local h = harness({
                chunks = {
                    event_chunk({
                        {
                            type = "PUT",
                            kv = { key = codec.encode_base64("/tenant/node/a"), value = codec.encode_value({ x = 1 }) },
                        },
                    }),
                },
            })
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local body = assert(w())
            local ev = body.result.events[1]
            t.expect(ev.kv.key).to.equal("/tenant/node/a")
            t.expect(ev.kv.value.x).to.equal(1)
        end)

        -- DELETE 事件没有 value，解码不能在这上面炸
        t.it("DELETE 事件没有 value 也能解码，并补上默认事件类型", function()
            local h = harness({
                chunks = {
                    event_chunk({ { type = "DELETE", kv = { key = codec.encode_base64("/tenant/node/a") } } }),
                    event_chunk({ { kv = { key = codec.encode_base64("/tenant/node/b") } } }),
                },
            })
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local body = assert(w())
            t.expect(body.result.events[1].kv.value).to.be_nil()
            t.expect(body.result.events[1].type).to.equal("DELETE")
            -- etcd 的 PUT 事件不带 type 字段
            t.expect(assert(w()).result.events[1].type).to.equal("PUT")
        end)

        t.it("解码 prev_kv", function()
            local h = harness({
                chunks = {
                    event_chunk({
                        {
                            type = "PUT",
                            kv = { key = codec.encode_base64("/tenant/a"), value = codec.encode_value(2) },
                            prev_kv = { key = codec.encode_base64("/tenant/a"), value = codec.encode_value(1) },
                        },
                    }),
                },
            })
            local w <close> = h.watch.watchdir(h.cli, "")
            local ev = assert(w()).result.events[1]
            t.expect(ev.prev_kv.key).to.equal("/tenant/a")
            t.expect(ev.prev_kv.value).to.equal(1)
        end)

        t.it("没有事件的通知原样返回", function()
            local h = harness({ chunks = { cjson.encode({ result = { header = { revision = 9 } } }) } })
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local body = assert(w())
            t.expect(body.result.header.revision).to.equal(9)
        end)

        t.it("etcd 返回业务错误时带出来", function()
            local h = harness({
                chunks = { cjson.encode({ error = "etcdserver: mvcc: required revision has been compacted" }) },
            })
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local body, err = w()
            t.expect(body).to.be_nil()
            t.expect(err).to.match("compacted")
        end)

        t.it("非 200 的流直接返回状态码", function()
            local h = harness({ status = 500, chunks = { "oops" } })
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local body, err = w()
            t.expect(body).to.be_nil()
            t.expect(err).to.equal(500)
        end)

        -- 解不出 JSON 说明这个端点返回的东西不对，摘掉它换一个
        t.it("chunk 解不出 JSON 时摘除端点", function()
            local h = harness({ chunks = { "not json" } })
            local w <close> = h.watch.watchdir(h.cli, "node/")
            local body, err = w()
            t.expect(body).to.be_nil()
            t.expect(err).to.match("decode json failed")
            t.expect(h.failures[1]).to.equal("http://a:2379")
        end)
    end)

    t.describe("关闭", function()
        t.it("离开作用域时关掉底层流", function()
            local h = harness()
            do
                local w <close> = h.watch.watchdir(h.cli, "node/")
                t.expect(w).to.exist()
            end
            t.expect(h.closed).to.equal(1)
        end)

        t.it("重复关闭不会重复关流", function()
            local h = harness()
            local w = h.watch.watchdir(h.cli, "node/")
            local mt = getmetatable(w)
            mt.__close(w)
            mt.__close(w)
            t.expect(h.closed).to.equal(1)
        end)
    end)
end)
