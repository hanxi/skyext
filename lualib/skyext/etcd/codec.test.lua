local t = require "skytest"
local codec = require "skyext.etcd.codec"

t.describe("etcd.codec", function()
    t.describe("verify_key", function()
        t.it("拒绝非字符串", function()
            local ok, err = codec.verify_key(123)
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("string")
        end)

        t.it("拒绝空字符串", function()
            local ok, err = codec.verify_key("")
            t.expect(ok).to.equal(false)
            t.expect(err).to.match("empty")
        end)

        t.it("接受普通 key", function()
            t.expect(codec.verify_key("a/b")).to.equal(true)
        end)
    end)

    t.describe("real_key", function()
        t.it("拼上前缀", function()
            t.expect(codec.real_key("/tenant/", "a")).to.equal("/tenant/a")
        end)

        t.it("前缀缺失时原样返回", function()
            t.expect(codec.real_key(nil, "a")).to.equal("a")
        end)
    end)

    t.describe("value 编解码", function()
        t.it("value 先 JSON 再 base64，回来还是原值", function()
            local encoded = codec.encode_value({ a = 1, b = "x" })
            local decoded = codec.decode_value(encoded)
            t.expect(decoded.a).to.equal(1)
            t.expect(decoded.b).to.equal("x")
        end)

        t.it("字符串 value 解出来仍是字符串，不会变成裸文本", function()
            t.expect(codec.decode_value(codec.encode_value("node-a"))).to.equal("node-a")
        end)

        t.it("没有 value 的事件解出 nil 而不是报错", function()
            t.expect(codec.decode_value(nil)).to.be_nil()
        end)
    end)

    t.describe("range_end", function()
        t.it("末字节加一得到前缀上界", function()
            t.expect(codec.range_end("/node/")).to.equal("/node0")
        end)

        -- 直接给末字节加一会算出 string.char(256) 并直接报错
        t.it("0xff 结尾向前进位并截断", function()
            t.expect(codec.range_end("ab\xff")).to.equal("ac")
        end)

        t.it("连续 0xff 一次进到位", function()
            t.expect(codec.range_end("a\xff\xff")).to.equal("b")
        end)

        t.it("全 0xff 退化成扫到 keyspace 末尾", function()
            t.expect(codec.range_end("\xff\xff")).to.equal("\0")
        end)

        t.it("空 key 退化成扫到 keyspace 末尾", function()
            t.expect(codec.range_end("")).to.equal("\0")
        end)

        t.it("上界严格大于原 key，否则区间会扫不到任何东西", function()
            for _, key in ipairs({ "a", "/node/", "ab\xff", "a\xff\xff" }) do
                t.expect(codec.range_end(key) > key).to.equal(true)
            end
        end)
    end)

    t.describe("decode_kvs", function()
        t.it("原地解码 key 与 value", function()
            local kvs = {
                { key = codec.encode_base64("/a"), value = codec.encode_value(1) },
                { key = codec.encode_base64("/b"), value = codec.encode_value({ x = 2 }) },
            }
            codec.decode_kvs(kvs)
            t.expect(kvs[1].key).to.equal("/a")
            t.expect(kvs[1].value).to.equal(1)
            t.expect(kvs[2].value.x).to.equal(2)
        end)

        t.it("没有 kvs 时什么都不做", function()
            t.expect(function()
                codec.decode_kvs(nil)
            end).to_not
                .throw()
        end)
    end)
end)
