local skynet = require "skynet"
local collector = require "skytest.cov.collector"
local config = require "skytest.cov.config"
local lcov_reporter = require "skytest.cov.lcov_reporter"
local source_lines = require "skytest.cov.source_lines"
local fs = require "skyext.util.fs"

local CMD = {}
local central_stats = {}
local dirty = false

local function merge_stats(other)
    for source, lines in pairs(other) do
        if not central_stats[source] then
            central_stats[source] = {}
        end
        local my_lines = central_stats[source]
        for line, count in pairs(lines) do
            my_lines[line] = (my_lines[line] or 0) + count
        end
    end
    dirty = true
end

local function list_snlua_services()
    local ok, list = pcall(skynet.call, ".launcher", "lua", "LIST")
    if not ok then
        skynet.error("[skytest.cov] failed to enumerate services: " .. tostring(list))
        return {}
    end
    local addrs = {}
    for addr, info in pairs(list) do
        if type(info) == "string" and info:find("^snlua") then
            addrs[#addrs + 1] = addr
        end
    end
    return addrs
end

local function collect_from_all()
    local addrs = list_snlua_services()
    skynet.error(string.format("[skytest.cov] collecting from %d snlua services", #addrs))

    local collected = 0
    local failed = 0

    for _, addr in ipairs(addrs) do
        local ok, data = pcall(skynet.call, addr, "debug", "SKYTEST_COV_DUMP")
        if ok and data then
            merge_stats(data)
            collected = collected + 1
        else
            failed = failed + 1
        end
    end

    skynet.error(string.format("[skytest.cov] collected: %d, failed: %d", collected, failed))
    return collected, failed
end

local function apply_filters(stats)
    local cfg = config.get()
    if #cfg.include == 0 and #cfg.exclude == 0 then
        return stats
    end

    local filtered = {}
    for source, lines in pairs(stats) do
        if collector.should_track(source) then
            filtered[source] = lines
        end
    end
    return filtered
end

local function build_report_stats()
    local cfg = config.get()
    local stats = apply_filters(central_stats)

    -- If source_dirs configured, merge with baseline for stable denominator
    if #cfg.source_dirs > 0 then
        local baseline = source_lines.scan(cfg.source_dirs, cfg.exclude)
        stats = source_lines.merge_with_stats(baseline, stats)
    end

    return stats
end

local function save_stats()
    local cfg = config.get()
    local output_dir = cfg.output_dir

    fs.mkdir(output_dir)

    local report_stats = build_report_stats()

    -- Write lcov (unique per process to avoid overwrites)
    local pid = tostring(math.floor(skynet.time() * 1000)) .. "_" .. tostring(math.random(10000))
    local lcov_path = output_dir .. "/coverage_" .. pid .. ".info"
    local content = lcov_reporter.generate(report_stats)
    local f = io.open(lcov_path, "w")
    if not f then
        skynet.error("[skytest.cov] cannot write to " .. lcov_path)
        return nil, report_stats
    end
    f:write(content)
    f:close()

    -- Write raw stats (batch write for efficiency)
    local stats_path = output_dir .. "/" .. cfg.statsfile
    local sf = io.open(stats_path, "w")
    if sf then
        local parts = {}
        for source, lines in pairs(central_stats) do
            for line, count in pairs(lines) do
                parts[#parts + 1] = string.format("%s:%d:%d\n", source, line, count)
            end
        end
        sf:write(table.concat(parts))
        sf:close()
    end

    dirty = false
    skynet.error("[skytest.cov] saved lcov to " .. lcov_path)
    return lcov_path, report_stats
end

function CMD.REPORT(source_stats)
    merge_stats(source_stats)
end

function CMD.DUMP()
    collect_from_all()
    local path, report_stats = save_stats()

    local file_count = 0
    local total_lines = 0
    local covered_lines = 0
    for _, lines in pairs(report_stats) do
        file_count = file_count + 1
        for _, count in pairs(lines) do
            total_lines = total_lines + 1
            if count > 0 then
                covered_lines = covered_lines + 1
            end
        end
    end

    local pct = total_lines > 0 and string.format("%.1f%%", covered_lines / total_lines * 100) or "N/A"
    skynet.error(
        string.format(
            "[skytest.cov] coverage: %s (%d/%d lines in %d files)",
            pct,
            covered_lines,
            total_lines,
            file_count
        )
    )

    return {
        files = file_count,
        total_lines = total_lines,
        covered_lines = covered_lines,
        coverage = pct,
        output = path,
    }
end

function CMD.STATUS()
    local file_count = 0
    local line_count = 0
    for _, lines in pairs(central_stats) do
        file_count = file_count + 1
        for _ in pairs(lines) do
            line_count = line_count + 1
        end
    end
    return {
        files = file_count,
        lines = line_count,
    }
end

function CMD.RESET()
    central_stats = {}
    return true
end

function CMD.FLUSH()
    collect_from_all()
    return save_stats()
end

skynet.start(function()
    -- Auto-flush on exit: save whatever is already collected (don't re-enumerate,
    -- .launcher may already be gone during shutdown).
    local sentinel = setmetatable({}, {
        __gc = function()
            pcall(function()
                if next(central_stats) then
                    save_stats()
                    skynet.error("[skytest.cov] auto-flushed on exit")
                end
            end)
        end,
    })
    debug.getregistry()["skytest_cov_flush_sentinel"] = sentinel

    skynet.register(".skytest_cov")

    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if not f then
            skynet.error("[skytest.cov] unknown command: " .. tostring(cmd))
            if session ~= 0 then
                skynet.ret(skynet.pack(nil, "unknown command"))
            end
            return
        end

        if cmd == "REPORT" then
            f(...)
            return
        end

        local result = f(...)
        if session ~= 0 then
            skynet.ret(skynet.pack(result))
        end
    end)

    -- Periodic auto-flush: collect and save every flush_interval seconds.
    -- This ensures data is persisted even if the process is killed without
    -- running Lua GC (SIGTERM/SIGKILL).
    local cfg = config.get()
    local flush_interval = cfg.flush_interval or 10
    local function auto_flush()
        while true do
            skynet.sleep(flush_interval * 100)
            if not dirty then
                goto continue
            end
            local ok, err = pcall(function()
                collect_from_all()
                save_stats()
            end)
            if not ok then
                skynet.error("[skytest.cov] auto-flush error: " .. tostring(err))
            end
            ::continue::
        end
    end
    skynet.fork(auto_flush)

    skynet.error("[skytest.cov] central service started")
end)
