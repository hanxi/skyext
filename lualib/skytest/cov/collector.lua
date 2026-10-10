local skynet = require "skynet"
local config = require "skytest.cov.config"

local M = {}

M.stats = {}

local cfg

local function match_patterns(source, patterns)
    for _, pat in ipairs(patterns) do
        if source:find(pat, 1, true) then
            return true
        end
    end
    return false
end

function M.should_track(source)
    if not source or source == "" then return false end
    if source:sub(1, 1) ~= "@" then return false end

    local path = source:sub(2)
    if not cfg then
        cfg = config.get()
    end

    if #cfg.include > 0 then
        if not match_patterns(path, cfg.include) then
            return false
        end
    end

    if #cfg.exclude > 0 then
        if match_patterns(path, cfg.exclude) then
            return false
        end
    end

    return true
end

function M.dump(filtered)
    local snapshot = {}
    for source, lines in pairs(M.stats) do
        if not filtered or M.should_track(source) then
            local file_stats = {}
            for line, count in pairs(lines) do
                file_stats[line] = count
            end
            snapshot[source] = file_stats
        end
    end
    return snapshot
end

function M.merge(other_stats)
    for source, lines in pairs(other_stats) do
        if not M.stats[source] then
            M.stats[source] = {}
        end
        local my_lines = M.stats[source]
        for line, count in pairs(lines) do
            my_lines[line] = (my_lines[line] or 0) + count
        end
    end
end

function M.reset()
    M.stats = {}
end

function M.register_debug_cmd()
    local debug_lib = require "skynet.debug"
    debug_lib.reg_debugcmd("SKYTEST_COV_DUMP", function()
        local data = M.dump()
        skynet.ret(skynet.pack(data))
    end)
end

function M.report_to_central()
    local data = M.dump()
    if not next(data) then return end
    pcall(skynet.send, config.get().service_name, "lua", "REPORT", data)
end

return M
