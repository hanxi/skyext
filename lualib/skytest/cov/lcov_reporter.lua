local M = {}

function M.generate(stats, test_name)
    local parts = {}
    parts[#parts + 1] = "TN:" .. (test_name or "")

    local sources = {}
    for source in pairs(stats) do
        sources[#sources + 1] = source
    end
    table.sort(sources)

    for _, source in ipairs(sources) do
        local lines = stats[source]

        -- Strip the leading '@' from source if present
        local filename = source
        if filename:sub(1, 1) == "@" then
            filename = filename:sub(2)
        end

        parts[#parts + 1] = "SF:" .. filename

        local sorted_lines = {}
        for line in pairs(lines) do
            sorted_lines[#sorted_lines + 1] = line
        end
        table.sort(sorted_lines)

        local lines_hit = 0
        local lines_found = #sorted_lines

        for _, line in ipairs(sorted_lines) do
            local count = lines[line]
            parts[#parts + 1] = string.format("DA:%d,%d", line, count)
            if count > 0 then
                lines_hit = lines_hit + 1
            end
        end

        parts[#parts + 1] = "LH:" .. lines_hit
        parts[#parts + 1] = "LF:" .. lines_found
        parts[#parts + 1] = "end_of_record"
    end

    return table.concat(parts, "\n") .. "\n"
end

function M.write(stats, filepath, test_name)
    local content = M.generate(stats, test_name)
    local f = io.open(filepath, "w")
    if not f then
        return nil, "cannot open " .. filepath
    end
    f:write(content)
    f:close()
    return true
end

return M
