#!/usr/bin/env lua
--
-- Scan source directories and output all executable lines (stable denominator).
-- Usage: lua source_lines.lua <dir1> [dir2 ...] [--exclude pattern1,pattern2]
--
-- Output: one line per executable line: <filepath>:<line>
--

local function scan_file(filepath)
    local f, err = loadfile(filepath)
    if not f then
        io.stderr:write("warning: cannot load " .. filepath .. ": " .. tostring(err) .. "\n")
        return {}
    end

    local lines = {}
    local info = debug.getinfo(f, "SL")
    if info and info.activelines then
        for line in pairs(info.activelines) do
            lines[#lines + 1] = line
        end
    end

    table.sort(lines)
    return lines
end

local function is_lua_file(path)
    return path:match("%.lua$") ~= nil
end

local function scan_dir(dir, exclude_patterns, results)
    local handle = io.popen('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null')
    if not handle then
        return
    end

    for path in handle:lines() do
        local skip = false
        for _, pat in ipairs(exclude_patterns) do
            if path:find(pat, 1, true) then
                skip = true
                break
            end
        end
        if not skip and is_lua_file(path) then
            local lines = scan_file(path)
            for _, line in ipairs(lines) do
                results[#results + 1] = path .. ":" .. line
            end
        end
    end
    handle:close()
end

-- Parse args
local dirs = {}
local excludes = {}
local i = 1
while i <= #arg do
    if arg[i] == "--exclude" then
        i = i + 1
        if arg[i] then
            for pat in arg[i]:gmatch("[^,;]+") do
                excludes[#excludes + 1] = pat:match("^%s*(.-)%s*$")
            end
        end
    else
        dirs[#dirs + 1] = arg[i]
    end
    i = i + 1
end

if #dirs == 0 then
    io.stderr:write("Usage: lua source_lines.lua <dir1> [dir2 ...] [--exclude pat1,pat2]\n")
    os.exit(1)
end

local results = {}
for _, dir in ipairs(dirs) do
    scan_dir(dir, excludes, results)
end

table.sort(results)
for _, line in ipairs(results) do
    print(line)
end
