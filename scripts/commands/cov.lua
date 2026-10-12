local lcov = require "scripts.lib.lcov"

local function usage()
    print([=[用法:
  ./bin/skyext cov merge -o <output> <input...>
  ./bin/skyext cov check <tracefile> [--threshold N]
  ./bin/skyext cov summary <tracefile>
  ./bin/skyext cov html <tracefile> [output-dir]]=])
end

return function(ctx, _, args)
    local action = args[1]
    if not action or action == "-h" or action == "--help" then
        usage()
        return 0
    end
    if action == "merge" then
        local output, files = nil, {}
        local i = 2
        while i <= #args do
            if args[i] == "-o" or args[i] == "--output" then
                output = assert(args[i + 1], "missing merge output path")
                i = i + 2
            else
                if ctx.fs.mode(args[i]) == "file" and #ctx.fs.read(args[i]) > 0 then
                    files[#files + 1] = args[i]
                end
                i = i + 1
            end
        end
        assert(output and #files > 0, "用法: cov merge -o <output> <input...>")
        for _, file in ipairs(files) do
            assert(ctx.fs.absolute(file) ~= ctx.fs.absolute(output), "output cannot be a merge input")
        end
        lcov.write(output, lcov.merge(files))
        print(string.format("合并 %d 个文件 -> %s", #files, output))
        return 0
    end
    local input = assert(args[2], "缺少 tracefile")
    assert(ctx.fs.mode(input) == "file", "tracefile not found: " .. input)
    if action == "html" then
        assert(not args[4], "用法: cov html <tracefile> [output-dir]")
        local output = args[3] or "coverage/html"
        ctx.fs.mkdir(output)
        local argv =
            { "genhtml", input, "--output-directory", output, "--quiet", "--title", "skyext coverage", "--legend" }
        local code = ctx.process.run(argv)
        assert(code == 0, "genhtml failed (install lcov/genhtml to generate an HTML report)")
        print("HTML report: " .. ctx.fs.join(output, "index.html"))
        return 0
    end
    if action == "summary" or action == "check" then
        local files, found, hit = lcov.stats(lcov.parse(input))
        local pct = found > 0 and hit * 100 / found or 0
        if action == "summary" then
            assert(not args[3], "用法: cov summary <tracefile>")
            print(string.format("Coverage: %.1f%% (%d/%d lines, %d files)", pct, hit, found, files))
            return 0
        end
        local threshold = 0
        if args[3] then
            assert(
                (args[3] == "--threshold" or args[3] == "--fail-under") and args[4] and not args[5],
                "用法: cov check <tracefile> [--threshold N]"
            )
            threshold = assert(tonumber(args[4]), "invalid coverage threshold")
            assert(threshold >= 0 and threshold <= 100, "coverage threshold must be 0..100")
        end
        print(string.format("Coverage: %.1f%% (%d/%d), threshold: %g%%", pct, hit, found, threshold))
        if found == 0 or pct + 1e-9 < threshold then
            io.stderr:write("FAIL: coverage below threshold or no data\n")
            return 1
        end
        print("PASS")
        return 0
    end
    error("unknown cov command: " .. action)
end
