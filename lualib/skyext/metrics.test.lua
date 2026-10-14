local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/metrics.lua")

-- 每个用例单独 loadfile 一份：指标表是模块级的，共用会让用例互相污染
local function harness()
    return { metrics = assert(loadfile(source, "t", setmetatable({}, { __index = _G })))() }
end

-- 取某个指标的样本，按标签值找
local function sample_of(snapshot, name, labels)
    for _, metric in ipairs(snapshot) do
        if metric.name == name then
            for _, sample in ipairs(metric.samples) do
                local matched = true
                for key, value in pairs(labels or {}) do
                    if sample.labels[key] ~= value then
                        matched = false
                    end
                end
                if matched then
                    return sample, metric
                end
            end
            return nil, metric
        end
    end
end

t.describe("metrics 命名校验", function()
    t.it("接受 Prometheus 允许的指标名", function()
        local h = harness()
        t.expect(function()
            h.metrics.counter("skyext_http_requests_total")
        end).to_not
            .throw()
        t.expect(function()
            h.metrics.counter("ns:rate_5m")
        end).to_not
            .throw()
    end)

    t.it("拒绝非法的指标名", function()
        local h = harness()
        for _, name in ipairs({ "9lives", "has-dash", "has space", "" }) do
            t.expect(function()
                h.metrics.counter(name)
            end).to
                .throw("invalid metric name")
        end
    end)

    t.it("拒绝非法的标签名", function()
        local h = harness()
        t.expect(function()
            h.metrics.counter("ok_total", "help", { "has-dash" })
        end).to
            .throw("invalid label name")
        -- 指标名可以带冒号，标签名不行
        t.expect(function()
            h.metrics.counter("ok2_total", "help", { "ns:op" })
        end).to
            .throw("invalid label name")
    end)
end)

t.describe("metrics counter", function()
    t.it("默认自增 1，可以指定增量", function()
        local h = harness()
        local c = h.metrics.counter("calls_total")
        c:inc()
        c:inc()
        c:inc(5)
        t.expect(sample_of(h.metrics.collect(), "calls_total").value).to.equal(7)
    end)

    t.it("拒绝负增量", function()
        local h = harness()
        local c = h.metrics.counter("calls_total")
        t.expect(function()
            c:inc(-1)
        end).to
            .throw("counter can not decrease")
    end)

    t.it("不同标签值各自记一条曲线", function()
        local h = harness()
        local c = h.metrics.counter("calls_total", "calls", { "op" })
        c:inc(1, { op = "find" })
        c:inc(2, { op = "insert" })
        c:inc(3, { op = "find" })

        local snapshot = h.metrics.collect()
        t.expect(sample_of(snapshot, "calls_total", { op = "find" }).value).to.equal(4)
        t.expect(sample_of(snapshot, "calls_total", { op = "insert" }).value).to.equal(2)
    end)

    t.it("漏传标签直接报错，而不是悄悄合并成一条曲线", function()
        local h = harness()
        local c = h.metrics.counter("calls_total", "calls", { "op" })
        t.expect(function()
            c:inc(1)
        end).to
            .throw("missing label 'op'")
        t.expect(function()
            c:inc(1, { other = "x" })
        end).to
            .throw("missing label 'op'")
    end)

    t.it("标签值统一转成字符串", function()
        local h = harness()
        local c = h.metrics.counter("calls_total", "calls", { "code" })
        c:inc(1, { code = 200 })
        t.expect(sample_of(h.metrics.collect(), "calls_total", { code = "200" })).to.exist()
    end)
end)

t.describe("metrics gauge", function()
    t.it("set / inc / dec", function()
        local h = harness()
        local g = h.metrics.gauge("conns")
        g:set(10)
        g:inc()
        g:inc(4)
        g:dec(5)
        t.expect(sample_of(h.metrics.collect(), "conns").value).to.equal(10)
    end)

    t.it("允许减到负数：gauge 表示的是瞬时值", function()
        local h = harness()
        local g = h.metrics.gauge("delta")
        g:dec(3)
        t.expect(sample_of(h.metrics.collect(), "delta").value).to.equal(-3)
    end)
end)

t.describe("metrics histogram", function()
    t.it("只给落入的那一档计数，累积留到渲染时算", function()
        local h = harness()
        local hist = h.metrics.histogram("latency", "latency", nil, { 1, 2, 3 })
        hist:observe(0.5)
        hist:observe(2.5)

        local sample = sample_of(h.metrics.collect(), "latency")
        t.expect(sample.counts).to.equal({ 1, 0, 1 })
        t.expect(sample.count).to.equal(2)
        t.expect(sample.sum).to.equal(3)
    end)

    t.it("等于上界算落入该桶", function()
        local h = harness()
        local hist = h.metrics.histogram("latency", "latency", nil, { 1, 2 })
        hist:observe(1)
        t.expect(sample_of(h.metrics.collect(), "latency").counts).to.equal({ 1, 0 })
    end)

    t.it("超过最大上界的只进 count，不进任何桶", function()
        local h = harness()
        local hist = h.metrics.histogram("latency", "latency", nil, { 1, 2 })
        hist:observe(100)

        local sample = sample_of(h.metrics.collect(), "latency")
        t.expect(sample.counts).to.equal({ 0, 0 })
        t.expect(sample.count).to.equal(1)
        t.expect(sample.sum).to.equal(100)
    end)

    t.it("默认分桶覆盖 5ms 到 10s", function()
        local h = harness()
        local hist = h.metrics.histogram("latency")
        t.expect(hist.buckets).to.equal(h.metrics.DEFAULT_BUCKETS)
        t.expect(hist.buckets[1]).to.equal(0.005)
        t.expect(hist.buckets[#hist.buckets]).to.equal(10)
    end)

    t.it("拒绝空桶或没有升序排列的桶", function()
        local h = harness()
        t.expect(function()
            h.metrics.histogram("a", "a", nil, {})
        end).to
            .throw("non%-empty array")
        t.expect(function()
            h.metrics.histogram("b", "b", nil, { 1, 1 })
        end).to
            .throw("sorted ascending")
        t.expect(function()
            h.metrics.histogram("c", "c", nil, { 2, 1 })
        end).to
            .throw("sorted ascending")
    end)

    t.it("每条曲线各有一份桶计数", function()
        local h = harness()
        local hist = h.metrics.histogram("latency", "latency", { "op" }, { 1 })
        hist:observe(0.5, { op = "find" })
        hist:observe(5, { op = "insert" })

        local snapshot = h.metrics.collect()
        t.expect(sample_of(snapshot, "latency", { op = "find" }).counts).to.equal({ 1 })
        t.expect(sample_of(snapshot, "latency", { op = "insert" }).counts).to.equal({ 0 })
    end)
end)

t.describe("metrics 重复声明", function()
    t.it("同名同类型同标签返回同一个指标", function()
        local h = harness()
        local a = h.metrics.counter("calls_total", "calls", { "op" })
        local b = h.metrics.counter("calls_total", "calls", { "op" })
        t.expect(a).to.equal(b)
        a:inc(1, { op = "x" })
        b:inc(1, { op = "x" })
        t.expect(sample_of(h.metrics.collect(), "calls_total", { op = "x" }).value).to.equal(2)
    end)

    t.it("同名不同类型报错", function()
        local h = harness()
        h.metrics.counter("thing")
        t.expect(function()
            h.metrics.gauge("thing")
        end).to
            .throw("already declared as counter")
    end)

    t.it("同名不同标签报错", function()
        local h = harness()
        h.metrics.counter("thing", "t", { "op" })
        t.expect(function()
            h.metrics.counter("thing", "t", { "op", "code" })
        end).to
            .throw("already declared as counter")
        t.expect(function()
            h.metrics.counter("thing", "t", { "code" })
        end).to
            .throw("already declared with other labels")
    end)
end)

t.describe("metrics _reset", function()
    t.it("清空本虚拟机里的全部指标", function()
        local h = harness()
        h.metrics.counter("a_total"):inc()
        h.metrics._reset()
        t.expect(h.metrics.collect()).to.equal({})
    end)
end)

t.describe("metrics collect", function()
    t.it("带出渲染需要的元信息", function()
        local h = harness()
        h.metrics.histogram("latency", "how long", { "op" }, { 1 }):observe(0.5, { op = "find" })

        local _, metric = sample_of(h.metrics.collect(), "latency", { op = "find" })
        t.expect(metric.help).to.equal("how long")
        t.expect(metric.kind).to.equal("histogram")
        t.expect(metric.buckets).to.equal({ 1 })
    end)

    t.it("没写 help 时退化成指标名", function()
        local h = harness()
        h.metrics.counter("a_total")
        local _, metric = sample_of(h.metrics.collect(), "a_total")
        t.expect(metric.help).to.equal("a_total")
    end)

    t.it("没有样本的指标也会出现在快照里", function()
        local h = harness()
        h.metrics.counter("a_total", "a", { "op" })
        local _, metric = sample_of(h.metrics.collect(), "a_total")
        t.expect(metric).to.exist()
        t.expect(metric.samples).to.equal({})
    end)

    t.it("快照是拷贝，拿到之后再自增不会改到它", function()
        local h = harness()
        local hist = h.metrics.histogram("latency", "latency", nil, { 1 })
        hist:observe(0.5)
        local snapshot = h.metrics.collect()
        hist:observe(0.5)

        local sample = sample_of(snapshot, "latency")
        t.expect(sample.counts).to.equal({ 1 })
    end)
end)
