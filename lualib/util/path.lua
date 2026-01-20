local M = {}

-- 检测操作系统路径分隔符
local path_sep = package.config:sub(1, 1) -- Windows 是 '\', Unix 是 '/'

-- 拼接路径
-- 支持 Windows 和 Unix 平台
-- @param ... 路径片段
-- @return string 拼接后的路径
function M.join(...)
    local parts = { ... }
    if #parts == 0 then
        return ""
    end

    -- 过滤空字符串
    local filtered = {}
    for _, part in ipairs(parts) do
        if part and part ~= "" then
            table.insert(filtered, part)
        end
    end

    if #filtered == 0 then
        return ""
    end

    -- 拼接路径
    local path = table.concat(filtered, path_sep)

    -- 规范化路径
    -- 将多个连续的分隔符替换为单个
    if path_sep == "\\" then
        -- Windows 平台
        path = path:gsub("\\+", "\\")
        -- 处理混合使用的斜杠
        path = path:gsub("/", "\\")
    else
        -- Unix 平台
        path = path:gsub("/+", "/")
    end

    return path
end

return M
