-- 把指标快照渲染成 Prometheus 文本格式（text/plain; version=0.0.4）。
local M = {}

M.CONTENT_TYPE = "text/plain; version=0.0.4; charset=utf-8"

-- 整数不写小数点，浮点用 %.17g 保证往返不丢精度
local function format_number(value)
    if value ~= value then
        return "NaN"
    end
    if value == math.huge then
        return "+Inf"
    end
    if value == -math.huge then
        return "-Inf"
    end
    if math.type(value) == "integer" or value % 1 == 0 and math.abs(value) < 2 ^ 53 then
        return string.format("%d", value)
    end
    return string.format("%.17g", value)
end

local ESCAPE = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n" }

local function escape(value)
    return (value:gsub('[\\"\n]', ESCAPE))
end

-- 标签按名字排序输出：同一条曲线每次抓取的文本要一样，不然 diff 和缓存都没法用
local function format_labels(labels, extra_name, extra_value)
    local names = {}
    for name in pairs(labels or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        parts[#parts + 1] = string.format('%s="%s"', name, escape(tostring(labels[name])))
    end
    if extra_name then
        parts[#parts + 1] = string.format('%s="%s"', extra_name, extra_value)
    end
    if #parts == 0 then
        return ""
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function sample_order(a, b)
    return a.sort_key < b.sort_key
end

local function sorted_samples(metric)
    local samples = {}
    for _, sample in ipairs(metric.samples) do
        local names = {}
        for name in pairs(sample.labels or {}) do
            names[#names + 1] = name
        end
        table.sort(names)
        local parts = {}
        for _, name in ipairs(names) do
            parts[#parts + 1] = name .. "=" .. tostring(sample.labels[name])
        end
        sample.sort_key = table.concat(parts, "\0")
        samples[#samples + 1] = sample
    end
    table.sort(samples, sample_order)
    return samples
end

local function render_histogram(out, metric, sample)
    local cumulative = 0
    for i, upper in ipairs(metric.buckets or {}) do
        cumulative = cumulative + (sample.counts and sample.counts[i] or 0)
        out[#out + 1] = string.format(
            "%s_bucket%s %s",
            metric.name,
            format_labels(sample.labels, "le", format_number(upper)),
            format_number(cumulative)
        )
    end
    -- +Inf 桶等于总观测数：超过最大上界的观测只会落在这里
    out[#out + 1] = string.format(
        "%s_bucket%s %s",
        metric.name,
        format_labels(sample.labels, "le", "+Inf"),
        format_number(sample.count)
    )
    out[#out + 1] = string.format("%s_sum%s %s", metric.name, format_labels(sample.labels), format_number(sample.sum))
    out[#out + 1] =
        string.format("%s_count%s %s", metric.name, format_labels(sample.labels), format_number(sample.count))
end

-- @param snapshot 指标数组，元素形如 { name, help, kind, buckets, samples }
function M.render(snapshot)
    local metrics = {}
    for _, metric in ipairs(snapshot) do
        metrics[#metrics + 1] = metric
    end
    table.sort(metrics, function(a, b)
        return a.name < b.name
    end)

    local out = {}
    for _, metric in ipairs(metrics) do
        local samples = sorted_samples(metric)
        -- 没有任何样本的指标仍然输出 HELP/TYPE：下游能看出"有这个指标但还没数据"，
        -- 比指标凭空消失好排查
        out[#out + 1] = string.format("# HELP %s %s", metric.name, (metric.help or metric.name):gsub("\n", " "))
        out[#out + 1] = string.format("# TYPE %s %s", metric.name, metric.kind)
        for _, sample in ipairs(samples) do
            if metric.kind == "histogram" then
                render_histogram(out, metric, sample)
            else
                out[#out + 1] =
                    string.format("%s%s %s", metric.name, format_labels(sample.labels), format_number(sample.value))
            end
        end
    end
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

return M
