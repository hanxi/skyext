local bucket = require "log.bucket"
local log = require "log"
local tinsert = table.insert

local bucket_mt = {}
bucket_mt.__index = bucket_mt

function bucket_mt:put(record)
    local buckets = self.buckets
    if not buckets then
        self.default:put(record)
        return true
    end

    local one_ok = false
    for i = 1, #buckets do
        local suc = buckets[i]:put(record)
        if suc then
            one_ok = true
        end
    end

    -- 一个都没成功，丢到默认桶里
    if not one_ok then
        self.default:put(record)
        return true
    end
end

function bucket_mt:init(config)
    assert(not self.buckets, "init repeated")
    local buckets = {}
    for _, conf in pairs(config) do
        log.debug("bucket init", "conf", conf)
        local ok, bucket_obj = pcall(bucket.new, conf)
        if ok then
            tinsert(buckets, bucket_obj)
        else
            log.error("bucket init failed", "conf", conf.conf, "err", bucket_obj)
            return false
        end
    end
    self.buckets = buckets
    return true
end

function bucket_mt:reload()
    for _, b in ipairs(self.buckets) do
        if b.reload then
            b:reload()
        end
    end
end

function bucket_mt:close()
    for _, b in ipairs(self.buckets) do
        if b.close then
            b:close()
        end
    end
end

local M = {}

function M.new(config)
    local obj = {}
    obj.default = bucket.get_default()
    obj = setmetatable(obj, bucket_mt)
    obj:init(config)
    return obj
end

return M
