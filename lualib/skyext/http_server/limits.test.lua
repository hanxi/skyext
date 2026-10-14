local t = require "skytest"
local limits = require "skyext.http_server.limits"

t.describe("http limits 默认值", function()
    t.it("三个来源都没给时用内置默认值", function()
        local l = limits.parse()
        t.expect(l.max_connections).to.equal(1024)
        t.expect(l.read_timeout).to.equal(10)
        t.expect(l.write_timeout).to.equal(10)
        t.expect(l.keepalive_timeout).to.equal(60)
        t.expect(l.keepalive_requests).to.equal(100)
        t.expect(l.request_body_size).to.equal(1024 * 1024)
    end)

    t.it("defaults 返回副本，改动不会污染后续解析", function()
        local d = limits.defaults()
        d.max_connections = 1
        t.expect(limits.parse().max_connections).to.equal(1024)
    end)
end)

t.describe("http limits 优先级", function()
    t.it("实例配置优先于节点默认值", function()
        local l = limits.parse({ max_connections = 10 }, { max_connections = 20 })
        t.expect(l.max_connections).to.equal(10)
    end)

    t.it("实例没给的字段落到节点默认值", function()
        local l = limits.parse({ max_connections = 10 }, { read_timeout = 3 })
        t.expect(l.max_connections).to.equal(10)
        t.expect(l.read_timeout).to.equal(3)
        -- 两边都没给的仍然走内置默认值
        t.expect(l.write_timeout).to.equal(10)
    end)

    t.it("节点默认值为 nil 时不会挡住内置默认值", function()
        local l = limits.parse({}, { read_timeout = nil })
        t.expect(l.read_timeout).to.equal(10)
    end)
end)

t.describe("http limits 校验", function()
    t.it("非法值直接报错而不是静默回退", function()
        -- 静默回退意味着配置名拼错时上限会悄悄变回默认值，排障时完全看不出来
        t.expect(function()
            limits.parse({ max_connections = 0 })
        end).to
            .throw("invalid http max_connections: 0")
        t.expect(function()
            limits.parse({ read_timeout = -1 })
        end).to
            .throw("invalid http read_timeout")
        t.expect(function()
            limits.parse({ request_body_size = "big" })
        end).to
            .throw("invalid http request_body_size: big")
    end)

    t.it("拒绝带小数的数值", function()
        t.expect(function()
            limits.parse({ read_timeout = 1.5 })
        end).to
            .throw("invalid http read_timeout")
    end)

    t.it("接受数字字符串", function()
        local l = limits.parse({ max_connections = "32" })
        t.expect(l.max_connections).to.equal(32)
    end)

    t.it("keepalive_timeout 允许为 0 表示关闭 keep-alive", function()
        local l = limits.parse({ keepalive_timeout = 0 })
        t.expect(l.keepalive_timeout).to.equal(0)
    end)
end)
