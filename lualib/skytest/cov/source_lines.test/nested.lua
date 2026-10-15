-- 覆盖率基线扫描的夹具。行号被测试直接引用，改动此文件需同步 source_lines.test.lua。
local M = {}

function M.outer(a)
    local function inner(b)
        return b + 1
    end
    local t = {
        cb = function(x)
            return x * 2
        end,
    }
    return inner(a) + t.cb(a)
end

return M
