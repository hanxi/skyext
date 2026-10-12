local skynet = require "skynet"
local collector = require "skytest.cov.collector"
local config = require "skytest.cov.config"
local chook = require "skytest.hook"

local M = {}

local function find_upvalue(fn, name)
    local i = 1
    while true do
        local n, v = debug.getupvalue(fn, i)
        if n == nil then
            return nil, nil
        end
        if n == name then
            return i, v
        end
        i = i + 1
    end
end

local function patch_coroutine_hook()
    local warnings = {}

    -- Step 1: Find co_create via skynet.fork's upvalues
    local co_create_idx, old_co_create = find_upvalue(skynet.fork, "co_create")
    if not co_create_idx or not old_co_create then
        warnings[#warnings + 1] = "cannot find upvalue 'co_create' in skynet.fork"
        return false, warnings
    end

    -- Step 2: Wrap co_create itself so the hook is installed on EVERY coroutine
    -- it returns — both newly created and reused from the pool.
    local stats = collector.stats
    local function new_co_create(f)
        local co = old_co_create(f)
        chook.install_on(co, stats)
        return co
    end

    -- Lua 5.4 shared upvalues: replacing co_create propagates to all functions
    -- in skynet.lua that reference the same local (skynet.fork, dispatch, etc).
    debug.setupvalue(skynet.fork, co_create_idx, new_co_create)

    -- Verify on skynet.fork
    local _, check = find_upvalue(skynet.fork, "co_create")
    if check ~= new_co_create then
        warnings[#warnings + 1] = "setupvalue appeared to succeed but readback mismatch"
        return false, warnings
    end

    -- Step 3: Also patch coroutine.create globally for user code
    local raw_create = coroutine.create
    rawset(coroutine, "create", chook.wrap_create(raw_create, stats))

    return true, warnings
end

local function probe_coroutine_hook()
    -- Fork a probe coroutine that executes a known function.
    -- If the hook is working, the probe function's lines will appear in stats.
    local probe_source
    local probe_line
    local function probe_fn()
        local info = debug.getinfo(1, "Sl")
        probe_source = info.source
        probe_line = info.currentline
    end

    skynet.fork(probe_fn)
    -- The fork enqueues the coroutine; it won't run until we yield.
    -- Use skynet.sleep(0) to let the scheduler run the fork.
    skynet.sleep(0)

    if not probe_source then
        return false, "probe coroutine did not execute"
    end

    -- The probe source may be filtered by the global C filter if another
    -- service called set_filter first (write-once CAS race). Tolerate this:
    -- if other sources have data, the hook mechanism works.
    local file_stats = collector.stats[probe_source]
    if not file_stats then
        if next(collector.stats) then
            return true
        end
        return false, string.format("no stats recorded for probe source %s", probe_source)
    end

    if not file_stats[probe_line] or file_stats[probe_line] <= 0 then
        return false, string.format("probe line %s:%d has zero hits", probe_source, probe_line)
    end

    return true
end

local function install_exit_anchor()
    -- Use a GC sentinel to report data when the service exits.
    -- In Lua 5.4 we can use a to-be-closed variable or __gc on a table.
    local sentinel = setmetatable({}, {
        __gc = function()
            pcall(collector.report_to_central)
        end,
    })
    -- Keep sentinel alive in the registry so it's only collected when the VM shuts down.
    debug.getregistry()["skytest_cov_exit_sentinel"] = sentinel
end

function M.setup()
    local cfg = config.get()
    if not cfg.enabled then
        return
    end

    -- Install C hook on the main coroutine (no filter yet — probe needs to run unfiltered)
    chook.start(collector.stats)

    -- Patch coroutine creation to auto-install hooks on new coroutines
    local ok, warnings = patch_coroutine_hook()
    if not ok then
        for _, w in ipairs(warnings) do
            skynet.error("[skytest.cov] WARNING: " .. w)
        end
        skynet.error("[skytest.cov] coroutine hook patching failed; only main coroutine will be covered")
    end

    -- Register debug command for central service to pull data
    collector.register_debug_cmd()

    -- Install exit anchor
    install_exit_anchor()

    -- Self-check: verify coroutine hook works (must run before filter is applied)
    local probe_ok, probe_err = probe_coroutine_hook()
    if not probe_ok then
        skynet.error("[skytest.cov] WARNING: coroutine probe failed: " .. tostring(probe_err))
        skynet.error("[skytest.cov] coroutine coverage may be incomplete")
    end

    -- Now apply C-level path filters (after probe passed)
    if #cfg.include > 0 or #cfg.exclude > 0 then
        chook.set_filter(#cfg.include > 0 and cfg.include or nil, #cfg.exclude > 0 and cfg.exclude or nil)
    end

    -- Start central service (uniqueservice ensures only one instance).
    -- Retry with backoff: service_mgr may not be ready during early bootstrap.
    -- Temporarily mute print to suppress traceback noise from pcall'd failures
    -- (skyext's loader patches error() to print+traceback on every call).
    skynet.fork(function()
        local addr
        for attempt = 1, 5 do
            local start_ok, ret = pcall(skynet.uniqueservice, "skytest_cov")
            if start_ok then
                addr = ret
                break
            end
            if attempt < 5 then
                skynet.sleep(50 * attempt)
            end
        end
        if addr then
            skynet.error("[skytest.cov] central service ready: " .. skynet.address(addr))
        else
            skynet.error("[skytest.cov] WARNING: central service unavailable; data only in per-service stats")
        end
    end)

    skynet.error(
        "[skytest.cov] installed successfully" .. (ok and ", coroutine hook active" or ", coroutine hook DEGRADED")
    )
end

return M
