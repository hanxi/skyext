local checksum = require "skyext.hotfix_checksum"

local function usage()
    print([[用法: ./bin/skyext hotfix refresh <patch-dir>
热更目录与包内 update_files 的路径都相对于工程根目录（skynet 的 root），
与 GM hotfix 接口的 hotfix_dir 取值完全一致，例如 example/hotfix/20260120-patch1。
重新计算 checksum 并更新 hotfix.conf.lua 的 time。]])
end

return function(ctx, _, args)
    if not args[1] or args[1] == "-h" or args[1] == "--help" then
        usage()
        return 0
    end
    assert(args[1] == "refresh" and args[2] and not args[3], "用法: hotfix refresh <patch-dir>")
    local dir = args[2]:gsub("\\", "/"):gsub("/+$", "")
    assert(
        dir ~= "" and not dir:match("^/") and not dir:match("^%a:"),
        "热更目录必须是相对于工程根目录的相对路径"
    )
    for segment in dir:gmatch("[^/]+") do
        assert(segment ~= "." and segment ~= "..", "热更目录不能包含 . 或 ..")
    end

    local fs = ctx.fs
    local path = fs.join(ctx.root, dir, "hotfix.conf.lua")
    local original = fs.read(path)
    local chunk = assert(load(original, "@" .. path, "t"))
    local config = assert(chunk())
    assert(type(config) == "table", "hotfix.conf.lua 必须返回 table")
    local value, err = checksum.compute(config, dir, ctx.root)
    assert(value, err)
    local now = os.date("%Y-%m-%d %H:%M:%S")
    local updated, times = original:gsub('(time%s*=%s*)"[^"]*"', function(prefix)
        return prefix .. string.format("%q", now)
    end)
    local checksums
    updated, checksums = updated:gsub('(checksum%s*=%s*)"[^"]*"', function(prefix)
        return prefix .. string.format("%q", value)
    end)
    assert(times == 1 and checksums == 1, "hotfix.conf.lua 必须各有一个 time 和 checksum 字段")
    local verify = assert(load(updated, "@" .. path, "t"))()
    assert(type(verify) == "table" and verify.time == now and verify.checksum == value, "热更配置校验失败")
    fs.write(path, updated)
    print(string.format("已刷新 %s: time=%s checksum=%s", path, now, value))
    return 0
end
