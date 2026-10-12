local M = {}

function M.run_file(filepath)
    local chunk, err = loadfile(filepath)
    if not chunk then
        io.write(string.format("[skytest] ERROR: failed to load %s: %s\n", filepath, tostring(err)))
        return 2
    end

    local t = require "skytest"

    local ok, load_err = xpcall(chunk, debug.traceback)
    if not ok then
        t._cleanup()
        io.write(string.format("[skytest] ERROR: failed to execute %s: %s\n", filepath, tostring(load_err)))
        return 2
    end

    local ran, results = xpcall(t.run, debug.traceback)
    t._cleanup()
    if not ran then
        io.write(string.format("[skytest] ERROR: failed to run %s: %s\n", filepath, tostring(results)))
        return 1
    end
    if results.failed > 0 or results.has_hook_error then
        return 1
    end
    return 0
end

return M
