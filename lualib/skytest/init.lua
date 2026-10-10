local skynet = require "skynet"
local socket = require "skynet.socket"
local expect = require "skytest.expect"
local reporter = require "skytest.reporter"

local t = {}

local root_suites = {}
local current_suite = nil
local child_pids = {}

local function new_suite(name)
    return {
        name = name,
        before_all_fn = nil,
        after_all_fn = nil,
        before_each_fn = nil,
        after_each_fn = nil,
        items = {},
    }
end

function t.describe(name, fn)
    local suite = new_suite(name)
    if current_suite then
        table.insert(current_suite.items, { type = "suite", suite = suite })
    else
        table.insert(root_suites, suite)
    end
    local parent = current_suite
    current_suite = suite
    fn()
    current_suite = parent
end

function t.it(name, fn)
    if not current_suite then
        error("[skytest] it() must be called inside describe()")
    end
    table.insert(current_suite.items, { type = "test", name = name, fn = fn })
end

function t.before_all(fn)
    if not current_suite then
        error("[skytest] before_all() must be called inside describe()")
    end
    current_suite.before_all_fn = fn
end

function t.after_all(fn)
    if not current_suite then
        error("[skytest] after_all() must be called inside describe()")
    end
    current_suite.after_all_fn = fn
end

function t.before_each(fn)
    if not current_suite then
        error("[skytest] before_each() must be called inside describe()")
    end
    current_suite.before_each_fn = fn
end

function t.after_each(fn)
    if not current_suite then
        error("[skytest] after_each() must be called inside describe()")
    end
    current_suite.after_each_fn = fn
end

t.expect = expect

t.http = setmetatable({}, {
    __index = function(self, key)
        local http = require "skytest.http"
        for k, v in pairs(http) do
            self[k] = v
        end
        return self[key]
    end,
})

function t.wait_for_port(port, timeout)
    timeout = timeout or 5
    local deadline = skynet.now() + timeout * 100
    while true do
        local ok, fd = pcall(socket.open, "127.0.0.1", port)
        if ok and fd then
            socket.close(fd)
            return
        end
        if skynet.now() >= deadline then
            error(string.format("[skytest] wait_for_port(%d) timed out after %ds", port, timeout))
        end
        skynet.sleep(5)
    end
end

function t.start_skynet(opts)
    opts = opts or {}
    local root = os.getenv("SKYTEST_ROOT") or "."

    local test_file = os.getenv("SKYTEST_FILE") or ""
    local test_dir = nil
    local base = test_file:match("(.+)%.test%.lua$")
    if base then
        local dir = base .. ".test"
        local ok = os.execute(string.format("test -d %q", dir))
        if ok then
            test_dir = root .. "/" .. dir
        end
    end

    local conf_lines = {
        string.format('root = "%s/"', root),
        string.format('skyext_root = root'),
        string.format('game_root = root .. "example/"'),
        'include "paths.conf.lua"',
        'thread = 4',
        'harbor = 0',
        'bootstrap = "snlua bootstrap"',
        string.format('start = "%s"', opts.start or ""),
        'logservice = "snlua"',
        'logger = "logger"',
    }

    if test_dir then
        table.insert(conf_lines, string.format('luaservice = luaservice .. "%s/?.lua;"', test_dir))
    end

    if opts.env then
        for k, v in pairs(opts.env) do
            table.insert(conf_lines, string.format('%s = "%s"', k, tostring(v)))
        end
    end

    local conf_path = os.tmpname()
    local f = io.open(conf_path, "w")
    f:write(table.concat(conf_lines, "\n") .. "\n")
    f:close()

    local env_str = ""
    if os.getenv("SKYTEST_COV") then
        env_str = "SKYTEST_COV=1 "
        local cov_dir = os.getenv("SKYTEST_COV_OUTPUT_DIR")
        if cov_dir then
            env_str = env_str .. string.format("SKYTEST_COV_OUTPUT_DIR=%q ", cov_dir)
        end
    end

    local cmd = string.format("%s%q %q & echo $!", env_str, root .. "/bin/skynet", conf_path)
    local handle = io.popen(cmd)
    local pid = handle:read("*l")
    handle:close()

    if pid then
        pid = tonumber(pid)
        if pid then
            table.insert(child_pids, { pid = pid, conf = conf_path })
        end
    end

    return pid
end

function t.data_path(filename)
    local test_file = os.getenv("SKYTEST_FILE")
    if not test_file then
        error("[skytest] data_path() requires SKYTEST_FILE to be set")
    end
    local base = test_file:match("(.+)%.test%.lua$")
    if not base then
        error("[skytest] cannot derive .test/ directory from " .. test_file)
    end
    local dir = base .. ".test"
    local h = io.popen("pwd")
    local cwd = h:read("*l")
    h:close()
    return cwd .. "/" .. dir .. "/" .. filename
end

local function run_suite(suite, depth, results)
    reporter.describe_start(suite.name, depth)

    local ba_ok = true
    local ba_err

    if suite.before_all_fn then
        local ok, err = xpcall(suite.before_all_fn, debug.traceback)
        if not ok then
            ba_ok = false
            ba_err = err
        end
    end

    for _, item in ipairs(suite.items) do
        if item.type == "suite" then
            if ba_ok then
                run_suite(item.suite, depth + 1, results)
            else
                reporter.describe_start(item.suite.name, depth + 1)
                for _, sub in ipairs(item.suite.items) do
                    if sub.type == "test" then
                        results.failed = results.failed + 1
                        reporter.it_skip(sub.name, "before_all failed", depth + 2)
                    end
                end
            end
        elseif item.type == "test" then
            if not ba_ok then
                results.failed = results.failed + 1
                reporter.it_fail(item.name, 0, ba_err, depth + 1)
            else
                local be_ok = true
                if suite.before_each_fn then
                    local ok2, err2 = xpcall(suite.before_each_fn, debug.traceback)
                    if not ok2 then
                        be_ok = false
                        results.failed = results.failed + 1
                        reporter.it_fail(item.name, 0, err2, depth + 1)
                    end
                end

                if be_ok then
                    local t0 = skynet.now()
                    local ok3, err3 = xpcall(item.fn, debug.traceback)
                    local elapsed = math.floor((skynet.now() - t0) * 10)

                    if ok3 then
                        results.passed = results.passed + 1
                        reporter.it_pass(item.name, elapsed, depth + 1)
                    else
                        results.failed = results.failed + 1
                        reporter.it_fail(item.name, elapsed, err3, depth + 1)
                    end
                end

                if suite.after_each_fn then
                    local ok4, err4 = xpcall(suite.after_each_fn, debug.traceback)
                    if not ok4 then
                        io.write(string.format("  [skytest] after_each error: %s\n", tostring(err4)))
                        results.has_hook_error = true
                    end
                end
            end
        end
    end

    if ba_ok and suite.after_all_fn then
        local ok5, err5 = xpcall(suite.after_all_fn, debug.traceback)
        if not ok5 then
            io.write(string.format("  [skytest] after_all error: %s\n", tostring(err5)))
            results.has_hook_error = true
        end
    end
end

function t.run()
    local t0 = skynet.now()
    local results = { passed = 0, failed = 0, has_hook_error = false }

    for _, suite in ipairs(root_suites) do
        run_suite(suite, 1, results)
    end

    local total_ms = math.floor((skynet.now() - t0) * 10)
    reporter.summary(results.passed, results.failed, total_ms)

    root_suites = {}
    current_suite = nil

    return results
end

function t._cleanup()
    for _, child in ipairs(child_pids) do
        os.execute("kill " .. child.pid .. " 2>/dev/null")
        os.execute("kill -9 " .. child.pid .. " 2>/dev/null")
        os.remove(child.conf)
    end
    child_pids = {}
end

return t
