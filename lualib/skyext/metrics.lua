-- 进程内指标采集。
--
-- 每个 skynet 服务是独立的 Lua 虚拟机，指标先在本地累加（纯内存自增，热路径上
-- 不发消息），抓取时由 .metrics 服务逐个拉走再合并。推模式每次自增都要发一条
-- 消息，热路径上扛不住。
--
-- 挂到 .metrics 的动作在 skyext.cmd_api 分发消息时自动完成，这里只管累加。
local M = {}

-- Prometheus 的命名规则：指标名允许冒号（给 recording rule 用），标签名不允许
local NAME_PATTERN = "^[%a_:][%w_:]*$"
local LABEL_PATTERN = "^[%a_][%w_]*$"

-- 默认分桶按秒给，覆盖 5ms 到 10s：再快的没必要分，再慢的归到 +Inf 一样能看出来
M.DEFAULT_BUCKETS = { 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 }

local g_metrics = {} -- name -> metric

local function check_name(name)
    if type(name) ~= "string" or not name:match(NAME_PATTERN) then
        error("invalid metric name: " .. tostring(name), 3)
    end
end

local function check_labels(label_names)
    if label_names == nil then
        return {}
    end
    if type(label_names) ~= "table" then
        error("label names must be an array", 3)
    end
    for _, label in ipairs(label_names) do
        if type(label) ~= "string" or not label:match(LABEL_PATTERN) then
            error("invalid label name: " .. tostring(label), 3)
        end
    end
    return label_names
end

-- 标签值拼成一个 key。按声明顺序取值，所以不用排序，顺序天然稳定。
local function label_key(metric, labels)
    local names = metric.label_names
    if #names == 0 then
        return ""
    end
    local parts = {}
    for i = 1, #names do
        local value = labels and labels[names[i]]
        if value == nil then
            -- 漏传标签会让两条本该分开的曲线叠在一起，宁可报错也不要默默合并
            error(string.format("metric '%s' is missing label '%s'", metric.name, names[i]), 3)
        end
        parts[i] = tostring(value)
    end
    return table.concat(parts, "\0")
end

local function label_table(metric, labels)
    local result = {}
    for _, name in ipairs(metric.label_names) do
        result[name] = tostring(labels[name])
    end
    return result
end

local function new_metric(kind, name, help, label_names, mt)
    check_name(name)
    label_names = check_labels(label_names)
    local existing = g_metrics[name]
    if existing then
        -- 同名指标在同一个服务里被声明两次：类型或标签不一致说明是重名事故，
        -- 一致则当成同一个指标复用（模块被 require 两次是常事）
        if existing.kind ~= kind or #existing.label_names ~= #label_names then
            error(string.format("metric '%s' is already declared as %s", name, existing.kind), 3)
        end
        for i, label in ipairs(label_names) do
            if existing.label_names[i] ~= label then
                error(string.format("metric '%s' is already declared with other labels", name), 3)
            end
        end
        return existing
    end
    local metric = setmetatable({
        kind = kind,
        name = name,
        help = help or name,
        label_names = label_names,
        series = {}, -- label_key -> series
    }, mt)
    g_metrics[name] = metric
    return metric
end

local function get_series(metric, labels, init)
    local key = label_key(metric, labels)
    local series = metric.series[key]
    if not series then
        series = init()
        series.labels = label_table(metric, labels or {})
        metric.series[key] = series
    end
    return series
end

local counter = {}
counter.__index = counter

local function zero()
    return { value = 0 }
end

-- @param value 增量，默认 1，不能为负：计数器只增不减，减了下游算出来的速率是错的
function counter:inc(value, labels)
    value = value or 1
    if value < 0 then
        error("counter can not decrease: " .. self.name, 2)
    end
    local series = get_series(self, labels, zero)
    series.value = series.value + value
end

local gauge = {}
gauge.__index = gauge

function gauge:set(value, labels)
    get_series(self, labels, zero).value = value
end

function gauge:inc(value, labels)
    local series = get_series(self, labels, zero)
    series.value = series.value + (value or 1)
end

function gauge:dec(value, labels)
    local series = get_series(self, labels, zero)
    series.value = series.value - (value or 1)
end

local histogram = {}
histogram.__index = histogram

function histogram:observe(value, labels)
    local series = get_series(self, labels, function()
        local counts = {}
        for i = 1, #self.buckets do
            counts[i] = 0
        end
        return { count = 0, sum = 0, counts = counts }
    end)
    series.count = series.count + 1
    series.sum = series.sum + value
    local buckets = self.buckets
    for i = 1, #buckets do
        if value <= buckets[i] then
            -- 只记落入的那一档，累加成累积桶是导出时的事：
            -- 每次观测都去更新所有上界会让热路径的开销跟桶数成正比
            series.counts[i] = series.counts[i] + 1
            return
        end
    end
    -- 超过最大上界的只计入 +Inf，+Inf 的数量就是 count
end

-- @param name 指标名，按 Prometheus 约定以 _total 结尾
function M.counter(name, help, label_names)
    return new_metric("counter", name, help, label_names, counter)
end

function M.gauge(name, help, label_names)
    return new_metric("gauge", name, help, label_names, gauge)
end

-- @param buckets 升序排列的桶上界，默认 M.DEFAULT_BUCKETS
function M.histogram(name, help, label_names, buckets)
    buckets = buckets or M.DEFAULT_BUCKETS
    if type(buckets) ~= "table" or #buckets == 0 then
        error("histogram buckets must be a non-empty array", 2)
    end
    for i = 2, #buckets do
        if buckets[i] <= buckets[i - 1] then
            error("histogram buckets must be sorted ascending: " .. name, 2)
        end
    end
    local metric = new_metric("histogram", name, help, label_names, histogram)
    metric.buckets = metric.buckets or buckets
    return metric
end

-- 本服务当前所有指标的快照，用于跨服务传输。
-- 返回的是普通表，可以直接 skynet.pack。
function M.collect()
    local result = {}
    for _, metric in pairs(g_metrics) do
        local samples = {}
        for _, series in pairs(metric.series) do
            if metric.kind == "histogram" then
                local counts = {}
                for i = 1, #series.counts do
                    counts[i] = series.counts[i]
                end
                samples[#samples + 1] =
                    { labels = series.labels, count = series.count, sum = series.sum, counts = counts }
            else
                samples[#samples + 1] = { labels = series.labels, value = series.value }
            end
        end
        result[#result + 1] = {
            name = metric.name,
            help = metric.help,
            kind = metric.kind,
            buckets = metric.buckets,
            samples = samples,
        }
    end
    return result
end

-- 仅供测试：清空本虚拟机里的全部指标
function M._reset()
    g_metrics = {}
end

return M
