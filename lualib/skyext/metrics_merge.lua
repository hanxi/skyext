-- 把各服务上报的指标快照合成一份。
--
-- 同名同标签的曲线一律相加：计数器相加是天然的，gauge 相加也正是想要的——
-- 4 个 dbmgr 各报 3 个脏实体，关心的是全节点有 12 个，而不是某一个有几个。
-- 需要区分来源时在业务侧加标签，不要指望这里保留服务地址（实体服务有上千个，
-- 按地址打标签会把时间序列数量打爆）。
local M = {}

local accumulator = {}
accumulator.__index = accumulator

local function series_key(labels)
    local names = {}
    for name in pairs(labels or {}) do
        names[#names + 1] = name
    end
    table.sort(names)
    local parts = {}
    for _, name in ipairs(names) do
        parts[#parts + 1] = name .. "=" .. tostring(labels[name])
    end
    return table.concat(parts, "\0")
end

local function copy_labels(labels)
    local result = {}
    for name, value in pairs(labels or {}) do
        result[name] = tostring(value)
    end
    return result
end

function M.new()
    return setmetatable({ metrics = {}, conflicts = {} }, accumulator)
end

-- @return metric 或 nil（类型冲突时）
function accumulator:_metric(name, help, kind, buckets)
    local metric = self.metrics[name]
    if not metric then
        metric = { name = name, help = help or name, kind = kind, buckets = buckets, series = {} }
        self.metrics[name] = metric
        return metric
    end
    if metric.kind ~= kind then
        -- 两个服务拿同一个名字声明了不同类型的指标，合不了：
        -- 丢掉后来的那个，并把冲突记下来让调用方报出去
        if not self.conflicts[name] then
            self.conflicts[name] = true
            self.conflict_list = self.conflict_list or {}
            self.conflict_list[#self.conflict_list + 1] = name
        end
        return nil
    end
    return metric
end

local function get_series(metric, labels)
    local key = series_key(labels)
    local series = metric.series[key]
    if not series then
        series = { labels = copy_labels(labels) }
        metric.series[key] = series
    end
    return series
end

-- 累加一个 counter / gauge 样本
function accumulator:add(name, help, kind, labels, value)
    local metric = self:_metric(name, help, kind)
    if not metric then
        return
    end
    local series = get_series(metric, labels)
    series.value = (series.value or 0) + value
end

-- 取最大值而不是累加，用于"队列里最长的那个有多长"这类问题
function accumulator:max(name, help, labels, value)
    local metric = self:_metric(name, help, "gauge")
    if not metric then
        return
    end
    local series = get_series(metric, labels)
    if series.value == nil or value > series.value then
        series.value = value
    end
end

function accumulator:add_histogram(name, help, buckets, labels, count, sum, counts)
    local metric = self:_metric(name, help, "histogram", buckets)
    if not metric then
        return
    end
    if #(metric.buckets or {}) ~= #(buckets or {}) then
        -- 桶边界不一样的直方图没法相加，累积桶会对不上
        if not self.conflicts[name] then
            self.conflicts[name] = true
            self.conflict_list = self.conflict_list or {}
            self.conflict_list[#self.conflict_list + 1] = name
        end
        return
    end
    local series = get_series(metric, labels)
    series.count = (series.count or 0) + count
    series.sum = (series.sum or 0) + sum
    local merged = series.counts
    if not merged then
        merged = {}
        for i = 1, #buckets do
            merged[i] = 0
        end
        series.counts = merged
    end
    for i = 1, #buckets do
        merged[i] = merged[i] + (counts and counts[i] or 0)
    end
end

-- 吃掉一个服务上报的整份快照（skyext.metrics.collect 的返回值）
function accumulator:add_snapshot(snapshot)
    if type(snapshot) ~= "table" then
        return
    end
    for _, metric in ipairs(snapshot) do
        for _, sample in ipairs(metric.samples or {}) do
            if metric.kind == "histogram" then
                self:add_histogram(
                    metric.name,
                    metric.help,
                    metric.buckets,
                    sample.labels,
                    sample.count or 0,
                    sample.sum or 0,
                    sample.counts
                )
            else
                self:add(metric.name, metric.help, metric.kind, sample.labels, sample.value or 0)
            end
        end
    end
end

-- @return snapshot, conflicts  snapshot 可直接交给 skyext.metrics_text 渲染
function accumulator:result()
    local result = {}
    for _, metric in pairs(self.metrics) do
        local samples = {}
        for _, series in pairs(metric.series) do
            samples[#samples + 1] = series
        end
        result[#result + 1] = {
            name = metric.name,
            help = metric.help,
            kind = metric.kind,
            buckets = metric.buckets,
            samples = samples,
        }
    end
    return result, self.conflict_list
end

return M
