local t = require "skytest"
local metrics_text = require "skyext.metrics_text"

local function lines(snapshot)
    local text = metrics_text.render(snapshot)
    local result = {}
    for line in text:gmatch("[^\n]+") do
        result[#result + 1] = line
    end
    return result, text
end

t.describe("metrics_text 基本格式", function()
    t.it("每个指标都带 HELP 和 TYPE", function()
        local out = lines({
            { name = "calls_total", help = "how many", kind = "counter", samples = { { labels = {}, value = 3 } } },
        })
        t.expect(out).to.equal({
            "# HELP calls_total how many",
            "# TYPE calls_total counter",
            "calls_total 3",
        })
    end)

    t.it("没有样本的指标仍然输出 HELP 和 TYPE", function()
        local out = lines({ { name = "calls_total", help = "h", kind = "counter", samples = {} } })
        t.expect(out).to.equal({ "# HELP calls_total h", "# TYPE calls_total counter" })
    end)

    t.it("help 里的换行压成空格，不然会被当成新的一行", function()
        local out = lines({ { name = "a", help = "one\ntwo", kind = "gauge", samples = {} } })
        t.expect(out[1]).to.equal("# HELP a one two")
    end)

    t.it("以换行结尾", function()
        local _, text = lines({ { name = "a", kind = "gauge", samples = {} } })
        t.expect(text:sub(-1)).to.equal("\n")
    end)

    t.it("help 缺省时用指标名", function()
        local out = lines({ { name = "a", kind = "gauge", samples = {} } })
        t.expect(out[1]).to.equal("# HELP a a")
    end)
end)

t.describe("metrics_text 数值", function()
    t.it("整数不写小数点", function()
        local out = lines({ { name = "a", kind = "gauge", samples = { { labels = {}, value = 42.0 } } } })
        t.expect(out[3]).to.equal("a 42")
    end)

    t.it("小数保留精度", function()
        local out = lines({ { name = "a", kind = "gauge", samples = { { labels = {}, value = 0.125 } } } })
        t.expect(out[3]).to.equal("a 0.125")
    end)

    t.it("特殊值按 Prometheus 的写法", function()
        local out = lines({
            {
                name = "a",
                kind = "gauge",
                samples = {
                    { labels = { k = "nan" }, value = 0 / 0 },
                    { labels = { k = "pinf" }, value = math.huge },
                    { labels = { k = "ninf" }, value = -math.huge },
                },
            },
        })
        t.expect(out[3]).to.equal('a{k="nan"} NaN')
        t.expect(out[4]).to.equal('a{k="ninf"} -Inf')
        t.expect(out[5]).to.equal('a{k="pinf"} +Inf')
    end)
end)

t.describe("metrics_text 标签", function()
    t.it("标签按名字排序，输出才是稳定的", function()
        local out = lines({
            {
                name = "a",
                kind = "gauge",
                samples = { { labels = { zeta = "1", alpha = "2", mid = "3" }, value = 1 } },
            },
        })
        t.expect(out[3]).to.equal('a{alpha="2",mid="3",zeta="1"} 1')
    end)

    t.it("转义反斜杠、引号和换行", function()
        local out = lines({
            { name = "a", kind = "gauge", samples = { { labels = { k = 'back\\slash "q"\nnl' }, value = 1 } } },
        })
        t.expect(out[3]).to.equal('a{k="back\\\\slash \\"q\\"\\nnl"} 1')
    end)

    t.it("没有标签时不输出花括号", function()
        local out = lines({ { name = "a", kind = "gauge", samples = { { labels = {}, value = 1 } } } })
        t.expect(out[3]).to.equal("a 1")
    end)
end)

t.describe("metrics_text 排序", function()
    t.it("指标按名字排序", function()
        local out = lines({
            { name = "zeta", kind = "gauge", samples = {} },
            { name = "alpha", kind = "gauge", samples = {} },
        })
        t.expect(out[1]).to.equal("# HELP alpha alpha")
        t.expect(out[3]).to.equal("# HELP zeta zeta")
    end)

    t.it("同一个指标的样本按标签排序", function()
        local out = lines({
            {
                name = "a",
                kind = "gauge",
                samples = {
                    { labels = { op = "insert" }, value = 1 },
                    { labels = { op = "find" }, value = 2 },
                    { labels = { op = "delete" }, value = 3 },
                },
            },
        })
        t.expect(out[3]).to.equal('a{op="delete"} 3')
        t.expect(out[4]).to.equal('a{op="find"} 2')
        t.expect(out[5]).to.equal('a{op="insert"} 1')
    end)
end)

t.describe("metrics_text 直方图", function()
    t.it("把每档计数渲染成累积桶", function()
        local out = lines({
            {
                name = "latency",
                help = "h",
                kind = "histogram",
                buckets = { 1, 2, 5 },
                samples = { { labels = {}, count = 7, sum = 12.5, counts = { 2, 1, 3 } } },
            },
        })
        t.expect(out).to.equal({
            "# HELP latency h",
            "# TYPE latency histogram",
            'latency_bucket{le="1"} 2',
            'latency_bucket{le="2"} 3',
            'latency_bucket{le="5"} 6',
            'latency_bucket{le="+Inf"} 7',
            "latency_sum 12.5",
            "latency_count 7",
        })
    end)

    t.it("+Inf 桶等于总观测数，超出最大上界的落在这里", function()
        local out = lines({
            {
                name = "latency",
                kind = "histogram",
                buckets = { 1 },
                samples = { { labels = {}, count = 5, sum = 100, counts = { 1 } } },
            },
        })
        t.expect(out[3]).to.equal('latency_bucket{le="1"} 1')
        t.expect(out[4]).to.equal('latency_bucket{le="+Inf"} 5')
    end)

    t.it("le 和业务标签一起输出，sum / count 不带 le", function()
        local out = lines({
            {
                name = "latency",
                kind = "histogram",
                buckets = { 0.5 },
                samples = { { labels = { op = "find" }, count = 1, sum = 0.25, counts = { 1 } } },
            },
        })
        t.expect(out[3]).to.equal('latency_bucket{op="find",le="0.5"} 1')
        t.expect(out[5]).to.equal('latency_sum{op="find"} 0.25')
        t.expect(out[6]).to.equal('latency_count{op="find"} 1')
    end)
end)
