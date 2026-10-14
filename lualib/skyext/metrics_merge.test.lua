local t = require "skytest"
local merge = require "skyext.metrics_merge"

local function find(snapshot, name)
    for _, metric in ipairs(snapshot) do
        if metric.name == name then
            return metric
        end
    end
end

local function sample_of(snapshot, name, labels)
    local metric = find(snapshot, name)
    if not metric then
        return nil
    end
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

t.describe("metrics_merge 累加", function()
    t.it("同名同标签的样本相加", function()
        local acc = merge.new()
        acc:add("calls_total", "h", "counter", { op = "find" }, 3)
        acc:add("calls_total", "h", "counter", { op = "find" }, 4)
        t.expect(sample_of(acc:result(), "calls_total", { op = "find" }).value).to.equal(7)
    end)

    t.it("标签不同的样本各自成一条曲线", function()
        local acc = merge.new()
        acc:add("calls_total", "h", "counter", { op = "find" }, 3)
        acc:add("calls_total", "h", "counter", { op = "insert" }, 4)

        local snapshot = acc:result()
        t.expect(#find(snapshot, "calls_total").samples).to.equal(2)
        t.expect(sample_of(snapshot, "calls_total", { op = "insert" }).value).to.equal(4)
    end)

    t.it("无标签的样本也能合并", function()
        local acc = merge.new()
        acc:add("total", "h", "gauge", nil, 1)
        acc:add("total", "h", "gauge", nil, 2)

        local sample = sample_of(acc:result(), "total")
        t.expect(sample.value).to.equal(3)
        t.expect(sample.labels).to.equal({})
    end)

    t.it("标签值统一转成字符串", function()
        local acc = merge.new()
        acc:add("a", "h", "gauge", { code = 200 }, 1)
        t.expect(sample_of(acc:result(), "a", { code = "200" })).to.exist()
    end)

    t.it("max 取最大值而不是相加", function()
        local acc = merge.new()
        acc:max("mqlen_max", "h", { service = "dbmgr" }, 3)
        acc:max("mqlen_max", "h", { service = "dbmgr" }, 11)
        acc:max("mqlen_max", "h", { service = "dbmgr" }, 7)
        t.expect(sample_of(acc:result(), "mqlen_max", { service = "dbmgr" }).value).to.equal(11)
    end)

    t.it("max 的第一个值就算是 0 也会被记下来", function()
        local acc = merge.new()
        acc:max("mqlen_max", "h", nil, 0)
        t.expect(sample_of(acc:result(), "mqlen_max").value).to.equal(0)
    end)
end)

t.describe("metrics_merge 直方图", function()
    t.it("count、sum 和每档计数分别相加", function()
        local acc = merge.new()
        acc:add_histogram("latency", "h", { 1, 2 }, { op = "find" }, 2, 1.5, { 1, 1 })
        acc:add_histogram("latency", "h", { 1, 2 }, { op = "find" }, 3, 4.5, { 2, 0 })

        local sample, metric = sample_of(acc:result(), "latency", { op = "find" })
        t.expect(sample.count).to.equal(5)
        t.expect(sample.sum).to.equal(6)
        t.expect(sample.counts).to.equal({ 3, 1 })
        t.expect(metric.buckets).to.equal({ 1, 2 })
    end)

    t.it("桶边界不一致的直方图不合并，记成冲突", function()
        local acc = merge.new()
        acc:add_histogram("latency", "h", { 1, 2 }, nil, 1, 1, { 1, 0 })
        acc:add_histogram("latency", "h", { 1, 2, 3 }, nil, 9, 9, { 9, 9, 9 })

        local snapshot, conflicts = acc:result()
        t.expect(conflicts).to.equal({ "latency" })
        t.expect(sample_of(snapshot, "latency").count).to.equal(1)
    end)
end)

t.describe("metrics_merge 类型冲突", function()
    t.it("同名不同类型的样本被丢掉并记成冲突", function()
        local acc = merge.new()
        acc:add("thing", "h", "counter", nil, 1)
        acc:add("thing", "h", "gauge", nil, 100)

        local snapshot, conflicts = acc:result()
        t.expect(conflicts).to.equal({ "thing" })
        t.expect(find(snapshot, "thing").kind).to.equal("counter")
        t.expect(sample_of(snapshot, "thing").value).to.equal(1)
    end)

    t.it("同一个名字只记一次冲突", function()
        local acc = merge.new()
        acc:add("thing", "h", "counter", nil, 1)
        acc:add("thing", "h", "gauge", nil, 1)
        acc:add("thing", "h", "gauge", nil, 1)

        local _, conflicts = acc:result()
        t.expect(#conflicts).to.equal(1)
    end)

    t.it("没有冲突时第二个返回值是 nil", function()
        local acc = merge.new()
        acc:add("thing", "h", "counter", nil, 1)
        local _, conflicts = acc:result()
        t.expect(conflicts).to.be_nil()
    end)
end)

t.describe("metrics_merge 吃快照", function()
    t.it("合并多个服务上报的快照", function()
        local acc = merge.new()
        local snapshot_of = function(value, count)
            return {
                {
                    name = "calls_total",
                    help = "h",
                    kind = "counter",
                    samples = { { labels = { op = "find" }, value = value } },
                },
                {
                    name = "latency",
                    help = "h",
                    kind = "histogram",
                    buckets = { 1 },
                    samples = { { labels = {}, count = count, sum = count, counts = { count } } },
                },
            }
        end
        acc:add_snapshot(snapshot_of(2, 1))
        acc:add_snapshot(snapshot_of(5, 4))

        local snapshot = acc:result()
        t.expect(sample_of(snapshot, "calls_total", { op = "find" }).value).to.equal(7)
        t.expect(sample_of(snapshot, "latency").count).to.equal(5)
        t.expect(sample_of(snapshot, "latency").counts).to.equal({ 5 })
    end)

    t.it("不是表的上报直接忽略，一个服务回错不该把整次抓取搞崩", function()
        local acc = merge.new()
        t.expect(function()
            acc:add_snapshot(nil)
            acc:add_snapshot("boom")
        end).to_not
            .throw()
        t.expect(acc:result()).to.equal({})
    end)

    t.it("样本缺字段时按 0 算", function()
        local acc = merge.new()
        acc:add_snapshot({
            { name = "a", kind = "counter", samples = { { labels = {} } } },
            { name = "b", kind = "histogram", buckets = { 1 }, samples = { { labels = {} } } },
        })

        local snapshot = acc:result()
        t.expect(sample_of(snapshot, "a").value).to.equal(0)
        t.expect(sample_of(snapshot, "b").count).to.equal(0)
        t.expect(sample_of(snapshot, "b").counts).to.equal({ 0 })
    end)

    t.it("合并结果可以直接交给 metrics_text 渲染", function()
        local metrics_text = require "skyext.metrics_text"
        local acc = merge.new()
        acc:add("calls_total", "how many", "counter", { op = "find" }, 3)
        acc:add("calls_total", "how many", "counter", { op = "find" }, 4)
        t.expect(metrics_text.render(acc:result())).to
            .equal('# HELP calls_total how many\n# TYPE calls_total counter\ncalls_total{op="find"} 7\n')
    end)
end)
