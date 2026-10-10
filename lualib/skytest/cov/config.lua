local M = {}

local defaults = {
    enabled = false,
    output_dir = "./coverage",
    statsfile = "skytest_cov.stats",
    include = {},
    exclude = {},
    source_dirs = {},
    service_name = ".skytest_cov",
    flush_interval = 10,
}

local function to_patterns(s)
    if not s or s == "" then return {} end
    local t = {}
    for p in s:gmatch("[^,;]+") do
        t[#t + 1] = p:match("^%s*(.-)%s*$")
    end
    return t
end

function M.load()
    local cfg = {}
    for k, v in pairs(defaults) do
        cfg[k] = v
    end

    local ok, skynet = pcall(require, "skynet")
    if ok then
        local getenv = skynet.getenv
        if getenv("skytest_cov_output_dir") then
            cfg.output_dir = getenv("skytest_cov_output_dir")
        end
        if getenv("skytest_cov_include") then
            cfg.include = to_patterns(getenv("skytest_cov_include"))
        end
        if getenv("skytest_cov_exclude") then
            cfg.exclude = to_patterns(getenv("skytest_cov_exclude"))
        end
        if getenv("skytest_cov_source_dirs") then
            cfg.source_dirs = to_patterns(getenv("skytest_cov_source_dirs"))
        end
    end

    if os.getenv("SKYTEST_COV") then
        cfg.enabled = os.getenv("SKYTEST_COV") ~= "0"
    end
    if os.getenv("SKYTEST_COV_OUTPUT_DIR") then
        cfg.output_dir = os.getenv("SKYTEST_COV_OUTPUT_DIR")
    end
    if os.getenv("SKYTEST_COV_INCLUDE") then
        cfg.include = to_patterns(os.getenv("SKYTEST_COV_INCLUDE"))
    end
    if os.getenv("SKYTEST_COV_EXCLUDE") then
        cfg.exclude = to_patterns(os.getenv("SKYTEST_COV_EXCLUDE"))
    end
    if os.getenv("SKYTEST_COV_SOURCE_DIRS") then
        cfg.source_dirs = to_patterns(os.getenv("SKYTEST_COV_SOURCE_DIRS"))
    end
    if os.getenv("SKYTEST_COV_FLUSH_INTERVAL") then
        cfg.flush_interval = tonumber(os.getenv("SKYTEST_COV_FLUSH_INTERVAL")) or cfg.flush_interval
    end

    return cfg
end

local _cfg

function M.get()
    if not _cfg then
        _cfg = M.load()
    end
    return _cfg
end

M.enabled = os.getenv("SKYTEST_COV") and os.getenv("SKYTEST_COV") ~= "0"

return M
