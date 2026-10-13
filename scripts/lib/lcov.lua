local fs = require "skyext.util.fs"

local M = {}

function M.parse(path)
    local sources = {}
    local source
    for line in fs.read(path):gmatch("[^\r\n]+") do
        if line:sub(1, 3) == "SF:" then
            source = line:sub(4)
            sources[source] = sources[source] or {}
        elseif line:sub(1, 3) == "DA:" then
            assert(source, "DA without SF in " .. path)
            local number, hits = line:match("^DA:(%d+),(-?%d+)")
            assert(number and hits, "invalid DA in " .. path .. ": " .. line)
            number, hits = tonumber(number), tonumber(hits)
            -- gcov 并发合并数据可能产生负计数；lcov 2.x 的官方处理
            -- （--ignore-errors negative）是按 0 计，这里保持同一语义
            if hits < 0 then
                hits = 0
            end
            sources[source][number] = (sources[source][number] or 0) + hits
        elseif line == "end_of_record" then
            source = nil
        end
    end
    return sources
end

function M.merge(files, accept)
    local merged = {}
    for _, path in ipairs(files) do
        for source, lines in pairs(M.parse(path)) do
            if not accept or accept(source) then
                merged[source] = merged[source] or {}
                for number, hits in pairs(lines) do
                    merged[source][number] = (merged[source][number] or 0) + hits
                end
            end
        end
    end
    return merged
end

function M.stats(sources)
    local files, found, hit = 0, 0, 0
    for _, lines in pairs(sources) do
        files = files + 1
        for _, count in pairs(lines) do
            found = found + 1
            if count > 0 then
                hit = hit + 1
            end
        end
    end
    return files, found, hit
end

function M.write(path, sources)
    local output = { "TN:" }
    local names = {}
    for source in pairs(sources) do
        names[#names + 1] = source
    end
    table.sort(names)
    for _, source in ipairs(names) do
        output[#output + 1] = "SF:" .. source
        local numbers = {}
        for number in pairs(sources[source]) do
            numbers[#numbers + 1] = number
        end
        table.sort(numbers)
        local hit = 0
        for _, number in ipairs(numbers) do
            local count = sources[source][number]
            output[#output + 1] = string.format("DA:%d,%d", number, count)
            if count > 0 then
                hit = hit + 1
            end
        end
        output[#output + 1] = "LF:" .. #numbers
        output[#output + 1] = "LH:" .. hit
        output[#output + 1] = "end_of_record"
    end
    fs.write(path, table.concat(output, "\n") .. "\n")
end

function M.project_source(source)
    if source:sub(1, 2) ~= "./" then
        return false
    end
    for _, prefix in ipairs({ "./example/etc/", "./example/hotfix/", "./example/tools/", "./example/res/" }) do
        if source:sub(1, #prefix) == prefix then
            return false
        end
    end
    return true
end

return M
