local lcov = require "scripts.lib.lcov"

local function usage()
    print([[用法: ./bin/skyext test [options] [file|directory...]
  --match TEXT     按路径子串过滤测试文件
  --cov            收集 Lua 覆盖率（LCOV；有 genhtml 时也生成 HTML）
  --cov-c          收集 C 覆盖率（需 Linux/GCC 插桩构建及 lcov）
  --timeout SECS   每个文件的超时秒数（默认 120）
  --conf FILE      自定义 skynet 配置
默认扫描 lualib/、service/、example/、sdk/、test/。]])
end

local function parse(args)
    local options = { targets = {}, timeout = tonumber(os.getenv("SKYTEST_TIMEOUT")) or 120 }
    local i = 1
    while i <= #args do
        local item = args[i]
        if item == "--match" or item == "--timeout" or item == "--conf" then
            assert(args[i + 1], "missing value for " .. item)
            options[item:sub(3)] = args[i + 1]
            i = i + 2
        elseif item == "--cov" then
            options.cov = true
            i = i + 1
        elseif item == "--cov-c" then
            options.cov_c = true
            i = i + 1
        elseif item == "--help" or item == "-h" then
            options.help = true
            i = i + 1
        else
            assert(item:sub(1, 1) ~= "-", "unknown option: " .. item)
            options.targets[#options.targets + 1] = item
            i = i + 1
        end
    end
    options.timeout = assert(tonumber(options.timeout), "invalid timeout")
    assert(options.timeout > 0 and options.timeout < 4000000, "timeout must be positive")
    return options
end

local function discover(ctx, options)
    local fs = ctx.fs
    local targets = options.targets
    if #targets == 0 then
        targets = { "lualib", "service", "example", "sdk", "test" }
    end
    local found = {}
    for _, target in ipairs(targets) do
        local path = fs.mode(target) and fs.absolute(target) or fs.join(ctx.root, target)
        local mode = fs.mode(path)
        if mode == "file" then
            found[path] = true
        elseif mode == "directory" then
            for _, item in
                ipairs(fs.walk(path, function(relative)
                    -- example/tools/ 下有配套子模块（gamepass/goscon/phaser-game），里面的
                    -- node_modules、.git 等目录不属于 Lua 测试发现范围，且含跨目录符号链接
                    local name = relative:match("[^/]+$")
                    if name == "node_modules" or name:match("^%.") then
                        return false
                    end
                    return true
                end))
            do
                if item.mode == "file" and item.relative:match("%.test%.lua$") then
                    found[item.path] = true
                end
            end
        elseif #options.targets > 0 then
            error("test target not found: " .. target)
        end
    end
    local files = {}
    for path in pairs(found) do
        local display = path:gsub("\\", "/")
        local root = ctx.root:gsub("\\", "/") .. "/"
        if display:sub(1, #root) == root then
            display = display:sub(#root + 1)
        end
        if not options.match or display:find(options.match, 1, true) then
            files[#files + 1] = display
        end
    end
    table.sort(files)
    return files
end

local function temp_config(ctx)
    local fs = ctx.fs
    local name = string.format(".skytest_%d_%d.conf.lua", os.time(), math.random(1, 2147483647))
    local path = fs.join(ctx.game, "etc", name)
    assert(not fs.mode(path), "temporary config already exists: " .. path)
    local root = ctx.root:gsub("\\", "/") .. "/"
    fs.write(
        path,
        string.format(
            [[root = %q
skyext_root = root
game_root = root .. "example/"
start = "skytest_runner"
app_config_loaded = "true"
include "paths.conf.lua"
thread = 4
harbor = 0
bootstrap = "snlua bootstrap"
logservice = "snlua"
logger = "logger"
]],
            root
        )
    )
    return path
end

local function coverage(ctx, dir, run_dir)
    local fs = ctx.fs
    local traces = {}
    for _, item in ipairs(fs.walk(run_dir)) do
        if item.mode == "file" and item.relative:match("%.info$") then
            traces[#traces + 1] = item.path
        end
    end
    assert(#traces > 0, "no coverage tracefiles generated")
    local merged = lcov.merge(traces)
    local filtered = lcov.merge(traces, lcov.project_source)
    local _, total, hit = lcov.stats(filtered)
    assert(total > 0, "no project coverage data found")
    fs.mkdir(dir)
    lcov.write(fs.join(dir, "lua_coverage.info"), merged)
    local clean = fs.join(dir, "lua_coverage_clean.info")
    lcov.write(clean, filtered)
    local html = fs.join(dir, "html")
    local ok, code = pcall(ctx.process.run, {
        "genhtml",
        clean,
        "--output-directory",
        html,
        "--title",
        "skyext coverage",
        "--legend",
        "--no-function-coverage",
    }, { cwd = ctx.root })
    if not ok or code == 127 then
        io.stderr:write("genhtml 未安装，跳过 HTML 报告\n")
    else
        assert(code == 0, "genhtml failed")
    end
    local files = lcov.stats(filtered)
    print(string.format("覆盖率: %.1f%% (%d/%d 行, %d 文件)", hit * 100 / total, hit, total, files))
    print("lcov: " .. clean)
    if ok and code == 0 then
        print("报告: " .. fs.join(html, "index.html"))
    end
end

local function run_lcov(ctx, args)
    local code = ctx.process.run(args, { cwd = ctx.root })
    assert(code == 0, "lcov failed; install lcov and rebuild with make build C_COVERAGE=1")
end

local function c_coverage_start(ctx, dir, run_dir)
    ctx.fs.mkdir(dir)
    run_lcov(ctx, { "lcov", "--zerocounters", "--directory", ctx.root })
    run_lcov(ctx, {
        "lcov",
        "--capture",
        "--initial",
        "--directory",
        ctx.root,
        "--output-file",
        ctx.fs.join(run_dir, "initial.info"),
    })
end

-- lcov 2.x 读取 tracefile 时会做函数/行计数一致性校验，gcov 数据可能触发
-- inconsistent 报错；因此 capture 之后改用 scripts/lib/lcov.lua 合并与过滤
-- （只保留 SF/DA 行数据），行为在 lcov 1.x/2.x 下一致。
local function c_source_filter(root)
    local prefixes = { root .. "/lualib-src/", root .. "/service-src/" }
    return function(source)
        for _, prefix in ipairs(prefixes) do
            if source:sub(1, #prefix) == prefix then
                return true
            end
        end
        return false
    end
end

-- 多个进程退出时并发合并同一份 .gcda 会损坏计数器（负数计数，lcov 2.x 报
-- negative 错误）。因此每个测试进程通过 GCOV_PREFIX 把 gcov 数据写入相互隔离
-- 的目录，再逐目录 capture：某个目录的数据损坏（如进程被 SIGKILL）时只丢弃
-- 该目录，不影响整体结果。
local function c_capture(ctx, directory, output)
    local ok, code = pcall(ctx.process.run, {
        "lcov",
        "--capture",
        "--directory",
        directory,
        "--external",
        "--quiet",
        "--output-file",
        output,
    }, { cwd = ctx.root })
    if ok and code == 0 then
        return true
    end
    io.stderr:write("警告: 跳过 " .. directory .. " 的 C 覆盖率数据（gcda 损坏或缺少 gcno）\n")
    return false
end

local function c_build_tree_has_gcda(fs, root)
    for _, dir in ipairs({ "luaclib", "luaclib/skytest", "cservice" }) do
        local path = fs.join(root, dir)
        if fs.mode(path) == "directory" then
            for _, name in ipairs(fs.entries(path)) do
                if name:match("%.gcda$") then
                    return true
                end
            end
        end
    end
    return false
end

-- lcov 2.x 的 geninfo 要求 .gcno 与 .gcda 同目录（1.x 会按 gcda 内记录的绝对
-- 路径寻找）。GCOV_PREFIX 数据树的布局是「树前缀 + gcda 绝对路径」，因此在
-- capture 前把构建树中的 .gcno 镜像拷贝到数据树对应位置，两个版本行为一致。
local function c_mirror_gcno(fs, root, tree)
    for _, dir in ipairs({ "luaclib", "luaclib/skytest", "cservice" }) do
        local source_dir = fs.join(root, dir)
        if fs.mode(source_dir) == "directory" then
            local target_dir = fs.join(tree .. root, dir)
            local created = false
            for _, name in ipairs(fs.entries(source_dir)) do
                if name:match("%.gcno$") then
                    if not created then
                        fs.mkdir(target_dir)
                        created = true
                    end
                    fs.copy(fs.join(source_dir, name), fs.join(target_dir, name))
                end
            end
        end
    end
end

local function c_gcda_dirs(fs, root, gcov_root)
    local dirs = {}
    -- 未继承 GCOV_PREFIX 的进程（正常不应出现）会写入构建树，一并捕获
    if c_build_tree_has_gcda(fs, root) then
        dirs[#dirs + 1] = root
    end
    if fs.mode(gcov_root) == "directory" then
        for _, name in ipairs(fs.entries(gcov_root)) do
            local path = fs.join(gcov_root, name)
            if fs.mode(path) == "directory" then
                dirs[#dirs + 1] = path
            end
        end
    end
    return dirs
end

local function c_coverage(ctx, dir, run_dir)
    local fs = ctx.fs
    local clean = fs.join(dir, "c_coverage.info")
    local traces = { fs.join(run_dir, "initial.info") }
    local dirs = c_gcda_dirs(fs, ctx.root, fs.join(run_dir, "gcov"))
    for index, source in ipairs(dirs) do
        if source ~= ctx.root then
            c_mirror_gcno(fs, ctx.root, source)
        end
        local output = fs.join(run_dir, string.format("capture%03d.info", index))
        if c_capture(ctx, source, output) then
            traces[#traces + 1] = output
        end
    end
    local merged = lcov.merge(traces, c_source_filter(ctx.root))
    local files, total, hit = lcov.stats(merged)
    assert(total > 0 and hit > 0, "no C coverage data; rebuild with make build C_COVERAGE=1")
    lcov.write(clean, merged)
    local html = fs.join(dir, "html-c")
    local ok, code = pcall(ctx.process.run, {
        "genhtml",
        clean,
        "--output-directory",
        html,
        "--title",
        "skyext C coverage",
        "--legend",
    }, { cwd = ctx.root })
    if not ok or code == 127 then
        io.stderr:write("genhtml 未安装，跳过 C HTML 报告\n")
    else
        assert(code == 0, "genhtml failed for C coverage")
    end
    print(string.format("C 覆盖率: %.1f%% (%d/%d 行, %d 文件)", hit * 100 / total, hit, total, files))
    print("lcov: " .. clean)
    if ok and code == 0 then
        print("报告: " .. fs.join(html, "index.html"))
    end
end

return function(ctx, _, args)
    local options = parse(args)
    if options.help then
        usage()
        return 0
    end
    local files = discover(ctx, options)
    if #files == 0 then
        print("No test files found.")
        return 0
    end
    local fs = ctx.fs
    local binary = fs.join(ctx.root, "bin", package.config:sub(1, 1) == "\\" and "skynet.exe" or "skynet")
    assert(fs.mode(binary) == "file", "未构建 skynet，请先执行 make build")

    local config = options.conf
    local created_config
    if config then
        config = fs.mode(config) == "file" and fs.absolute(config) or fs.join(ctx.root, config)
        assert(fs.mode(config) == "file", "config not found: " .. config)
    else
        config = temp_config(ctx)
        created_config = config
        local name = config:match("[^/\\]+$")
        config = fs.join("example", "etc", name)
    end

    local cov_dir = fs.join(ctx.root, os.getenv("SKYTEST_COV_OUTPUT_DIR") or "coverage")
    local run_dir = options.cov and fs.temporary_dir()
    -- gcov 数据树必须位于仓库之外：否则根目录 capture 会递归扫到它们（重复计数，
    -- 且 lcov 2.x 因树内缺 .gcno 直接报错）
    local c_run_dir = options.cov_c and fs.temporary_dir(os.getenv("TMPDIR") or "/tmp")

    local ok, result = xpcall(function()
        if options.cov_c then
            c_coverage_start(ctx, cov_dir, c_run_dir)
        end
        local passed, failed, errors = 0, 0, 0
        local failed_files = {}
        for index, file in ipairs(files) do
            print("▶ " .. file)
            local env = { SKYTEST_FILE = file }
            if options.cov then
                env.SKYTEST_COV = "1"
                env.SKYTEST_COV_OUTPUT_DIR = run_dir
                env.SKYTEST_COV_SOURCE_DIRS = os.getenv("SKYTEST_COV_SOURCE_DIRS") or "lualib/,service/,example/lualib/"
                -- `.test/` 是夹具目录约定（如 process.test/），里面是被测数据不是产品代码
                env.SKYTEST_COV_EXCLUDE = os.getenv("SKYTEST_COV_EXCLUDE") or "skynet/,.test.lua,.test/,example/build/"
            end
            if options.cov_c then
                -- 每个测试进程写入独立的 gcov 数据树，避免 .gcda 并发合并损坏
                local prefix = fs.join(c_run_dir, "gcov", string.format("t%03d", index))
                fs.mkdir(prefix)
                env.GCOV_PREFIX = prefix
                env.GCOV_PREFIX_STRIP = "0"
            end
            local code, timed_out = ctx.process.run({ binary, config }, {
                cwd = ctx.root,
                env = env,
                timeout = options.timeout,
            })
            if code == 0 then
                passed = passed + 1
            else
                if timed_out then
                    print(string.format("TIMEOUT after %g s", options.timeout))
                end
                if code == 2 then
                    errors = errors + 1
                else
                    failed = failed + 1
                end
                failed_files[#failed_files + 1] = file
            end
            print("")
        end
        if options.cov then
            coverage(ctx, cov_dir, run_dir)
        end
        if options.cov_c then
            c_coverage(ctx, cov_dir, c_run_dir)
        end
        print(string.format("%d files, %d passed, %d failed, %d errors", #files, passed, failed, errors))
        for _, file in ipairs(failed_files) do
            print("  " .. file)
        end
        return failed == 0 and errors == 0 and 0 or 1
    end, debug.traceback)
    if created_config then
        assert(os.remove(created_config), "cannot remove temporary config: " .. created_config)
    end
    if run_dir then
        fs.remove_tree(run_dir)
    end
    if c_run_dir then
        fs.remove_tree(c_run_dir)
    end
    if not ok then
        error(result, 0)
    end
    return result
end
