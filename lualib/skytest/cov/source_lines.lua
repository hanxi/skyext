local lfs = require "lfs"
local hook = require "skytest.hook"

local M = {}

-- 用 hook.proto_lines 而不是 debug.getinfo(f,"L").activelines：后者只给顶层
-- chunk 的行，嵌套函数体一行都不包含，当分母用会让覆盖率凭空虚高。
local function scan_file(filepath)
    local f, err = loadfile(filepath)
    if not f then
        return nil, err
    end
    return hook.proto_lines(f)
end

local function list_lua_files(dir, exclude_patterns)
    local files = {}
    local sep = package.config:sub(1, 1)
    local function excluded(path)
        for _, pat in ipairs(exclude_patterns or {}) do
            if path:find(pat, 1, true) then
                return true
            end
        end
        return false
    end
    local function visit(path)
        if excluded(path) then
            return
        end
        local mode = lfs.symlinkattributes(path, "mode")
        if mode == "file" then
            if path:match("%.lua$") then
                files[#files + 1] = path
            end
        elseif mode == "directory" then
            local names = {}
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    names[#names + 1] = name
                end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                visit(path:gsub("[/\\]$", "") .. sep .. name)
            end
        end
    end
    if lfs.attributes(dir, "mode") == "directory" then
        visit(dir)
    end
    return files
end

-- 返回 baseline, failures。扫描失败的文件必须报上去：静默跳过等于把整个文件
-- 从分母里抹掉，覆盖率会因为「编不过」而变好看。
function M.scan(source_dirs, exclude_patterns)
    local baseline = {}
    local failures = {}

    for _, dir in ipairs(source_dirs) do
        local files = list_lua_files(dir, exclude_patterns)
        for _, filepath in ipairs(files) do
            local lines, err = scan_file(filepath)
            if lines then
                local source_key = "@./" .. filepath:gsub("^%./", ""):gsub("\\", "/")
                baseline[source_key] = {}
                for line in pairs(lines) do
                    baseline[source_key][line] = 0
                end
            else
                failures[#failures + 1] = { path = filepath, err = err }
            end
        end
    end

    return baseline, failures
end

local cached_cwd_pattern
local function get_cwd_pattern()
    if cached_cwd_pattern == nil then
        local cwd = lfs.currentdir():gsub("\\", "/")
        cached_cwd_pattern = "^" .. cwd:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. "/"
    end
    return cached_cwd_pattern
end

local function normalize_source(source)
    local s = source:gsub("^@", ""):gsub("\\", "/")
    s = s:gsub("^%./", "")
    local pat = get_cwd_pattern()
    if pat then
        s = s:gsub(pat, "")
    end
    return s
end

-- 分母只由 baseline 决定。执行到的行一律只往 baseline 已有的行上叠加命中数，
-- 绝不因为「跑到了」就把一行或一个文件补进分母——那会让分母恒等于被执行过的
-- 行集合，于是每个加载过的文件都是 100%。
--
-- 返回 merged, diagnostics。diagnostics.unknown_sources 是有命中但不在 baseline
-- 里的文件（多半是 source_dirs/exclude 配错），orphan_lines 是文件在 baseline 里
-- 但行不在的计数（正常应为 0，非 0 说明基线扫描有漏）。
function M.merge_with_stats(baseline, stats)
    local merged = {}

    for source, lines in pairs(baseline) do
        merged[source] = {}
        for line, count in pairs(lines) do
            merged[source][line] = count
        end
    end

    local norm_to_baseline = {}
    for source in pairs(merged) do
        norm_to_baseline[normalize_source(source)] = source
    end

    local unknown_sources = {}
    local orphan_lines = 0

    for source, lines in pairs(stats) do
        local target = merged[source]
        if not target then
            local bkey = norm_to_baseline[normalize_source(source)]
            target = bkey and merged[bkey]
        end
        if target then
            for line, count in pairs(lines) do
                -- baseline 中未命中的行是 0，0 在 Lua 里为真，判断成立
                if target[line] then
                    target[line] = target[line] + count
                else
                    orphan_lines = orphan_lines + 1
                end
            end
        else
            unknown_sources[#unknown_sources + 1] = source
        end
    end

    table.sort(unknown_sources)
    return merged, { unknown_sources = unknown_sources, orphan_lines = orphan_lines }
end

return M
