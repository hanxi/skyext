local M = {}

local function indent(depth)
    return string.rep("  ", depth)
end

function M.describe_start(name, depth)
    io.write(indent(depth) .. name .. "\n")
end

function M.it_pass(name, duration_ms, depth)
    io.write(string.format("%s\027[32m✓\027[0m %s (%dms)\n", indent(depth), name, duration_ms))
end

function M.it_fail(name, duration_ms, err, depth)
    io.write(string.format("%s\027[31m✗\027[0m %s (%dms)\n", indent(depth), name, duration_ms))
    local lines = tostring(err):gmatch("[^\n]+")
    for line in lines do
        io.write(indent(depth + 1) .. line .. "\n")
    end
end

function M.it_skip(name, reason, depth)
    io.write(string.format("%s\027[36m- %s\027[0m", indent(depth), name))
    if reason then
        io.write(" (" .. reason .. ")")
    end
    io.write("\n")
end

function M.summary(passed, failed, total_ms)
    io.write("\n")
    if passed > 0 then
        io.write(string.format("  \027[32m%d passing\027[0m (%dms)\n", passed, total_ms))
    end
    if failed > 0 then
        io.write(string.format("  \027[31m%d failing\027[0m\n", failed))
    end
    if passed == 0 and failed == 0 then
        io.write("  0 tests\n")
    end
end

return M
