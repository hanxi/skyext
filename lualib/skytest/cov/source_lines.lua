local M = {}

local function scan_file(filepath)
    local f, err = loadfile(filepath)
    if not f then
        return nil, err
    end

    local info = debug.getinfo(f, "SL")
    if not info or not info.activelines then
        return {}
    end

    local lines = {}
    for line in pairs(info.activelines) do
        lines[line] = true
    end
    return lines
end

local function list_lua_files(dir, exclude_patterns)
    local files = {}
    local handle = io.popen(string.format('find %q -name "*.lua" -type f 2>/dev/null', dir))
    if not handle then
        return files
    end

    for path in handle:lines() do
        local skip = false
        if exclude_patterns then
            for _, pat in ipairs(exclude_patterns) do
                if path:find(pat, 1, true) then
                    skip = true
                    break
                end
            end
        end
        if not skip then
            files[#files + 1] = path
        end
    end
    handle:close()
    table.sort(files)
    return files
end

function M.scan(source_dirs, exclude_patterns)
    local baseline = {}

    for _, dir in ipairs(source_dirs) do
        local files = list_lua_files(dir, exclude_patterns)
        for _, filepath in ipairs(files) do
            local lines = scan_file(filepath)
            if lines then
                local source_key = "@./" .. filepath:gsub("^%./", "")
                baseline[source_key] = {}
                for line in pairs(lines) do
                    baseline[source_key][line] = 0
                end
            end
        end
    end

    return baseline
end

local cached_cwd_pattern
local function get_cwd_pattern()
    if cached_cwd_pattern == nil then
        local cwd = os.getenv("PWD") or ""
        if cwd ~= "" then
            cached_cwd_pattern = "^" .. cwd:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "/"
        else
            cached_cwd_pattern = false
        end
    end
    return cached_cwd_pattern
end

local function normalize_source(source)
    local s = source:gsub("^@", "")
    s = s:gsub("^%./", "")
    local pat = get_cwd_pattern()
    if pat then
        s = s:gsub(pat, "")
    end
    return s
end

function M.merge_with_stats(baseline, stats)
    local merged = {}

    -- Start with baseline (all executable lines at count 0)
    for source, lines in pairs(baseline) do
        merged[source] = {}
        for line, count in pairs(lines) do
            merged[source][line] = count
        end
    end

    -- Build normalized-path → baseline-key lookup
    local norm_to_baseline = {}
    for source in pairs(merged) do
        norm_to_baseline[normalize_source(source)] = source
    end

    -- Overlay actual hit counts from stats
    for source, lines in pairs(stats) do
        local target = merged[source]
        if not target then
            local norm = normalize_source(source)
            local bkey = norm_to_baseline[norm]
            if bkey then
                target = merged[bkey]
            end
        end
        if target then
            for line, count in pairs(lines) do
                target[line] = (target[line] or 0) + count
            end
        else
            merged[source] = {}
            for line, count in pairs(lines) do
                merged[source][line] = count
            end
        end
    end

    return merged
end

return M
