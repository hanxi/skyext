-- 密钥/口令强度校验。
-- 仓库里的示例配置和文档都用的是公开默认值，谁拿到源码都能用它伪造登录态、
-- 执行 GM 指令。这里把这些值集中成黑名单，并给出统一的判定入口，
-- 避免每个用到密钥的地方各写一套（或者干脆不写）。
local M = {}

-- 最小可用长度。低于这个长度的密钥即便不在黑名单里也认为不可用。
M.MIN_LENGTH = 16

-- 已知的示例值/占位符（全部小写比较，见 normalize）
local PLACEHOLDERS = {
    -- 仓库示例配置与文档里出现过的默认值
    ["change_me_to_random_token"] = true,
    ["your_access_secret"] = true,
    -- 常见的占位写法
    ["changeme"] = true,
    ["change_me"] = true,
    ["replace_me"] = true,
    ["todo"] = true,
    ["secret"] = true,
    ["password"] = true,
    ["admin"] = true,
    ["test"] = true,
    ["example"] = true,
    ["123456"] = true,
    ["12345678"] = true,
    ["1234567890"] = true,
}

local function normalize(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""):lower())
end

-- 是否是已知的占位符/示例值
function M.is_placeholder(value)
    if type(value) ~= "string" then
        return false
    end
    return PLACEHOLDERS[normalize(value)] == true
end

-- 校验一个密钥是否可用。
-- @param value 配置里读到的原始值
-- @param opts  { min_length = n, allow_insecure = bool }
--   allow_insecure: 明确允许弱密钥（仅本地开发），此时不拒绝，只在第二个返回值里给出原因
-- @return ok, reason
--   ok 为 true 表示可以使用；reason 在 ok 为 true 时是"可用但不安全"的告警，
--   在 ok 为 false 时是拒绝原因
function M.check(value, opts)
    opts = opts or {}
    local min_length = opts.min_length or M.MIN_LENGTH
    if type(value) ~= "string" or value == "" then
        return false, "not configured"
    end
    if M.is_placeholder(value) then
        local reason = "still a well-known placeholder value"
        if opts.allow_insecure then
            return true, reason
        end
        return false, reason
    end
    if #value < min_length then
        local reason = string.format("shorter than %d characters", min_length)
        if opts.allow_insecure then
            return true, reason
        end
        return false, reason
    end
    return true
end

-- 校验失败直接抛错，用于"拿不到可用密钥就没法继续"的启动路径
function M.assert_valid(value, name, opts)
    local ok, reason = M.check(value, opts)
    if not ok then
        error(string.format("%s is unusable: %s", name or "secret", reason), 2)
    end
    return value
end

return M
