local M = {}

local buckets = {}

function M.new(conf)
    local name = conf.name
    local mod = buckets[name]
    if not mod then
        local ok
        ok, mod = pcall(require, "log.bucket." .. name)
        if not ok then
            error("bucket name not found: " .. name .. mod)
        end
        buckets[name] = mod
    end

    local ok, bucket_obj = pcall(mod.new, conf)
    if not ok then
        error("bucket new failed: " .. bucket_obj)
    end
    return bucket_obj
end

-- 保底bucket
local default_bucket = { name = "console" }
function M.get_default()
    return M.new(default_bucket)
end

return M
