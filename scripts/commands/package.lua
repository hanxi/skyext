local lfs = require "lfs"
local zip = require "scripts.lib.zip"

local function publish(fs, path, entries, writer)
    fs.mkdir(path:match("^(.*)[/\\][^/\\]+$") or ".")
    local temp = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)) .. ".zip"
    assert(not fs.mode(temp), "temporary archive already exists: " .. temp)
    local write_archive = writer or zip.write
    write_archive(temp, entries)
    if fs.mode(path) then
        assert(fs.mode(path) == "file", "archive target is not a file: " .. path)
        assert(os.remove(path))
    end
    assert(os.rename(temp, path))
    print(string.format("打包完成: %s (%d 项)", path, #entries))
end

local function sorted_manifest(manifest)
    local entries = {}
    for _, item in pairs(manifest) do
        entries[#entries + 1] = item
    end
    table.sort(entries, function(a, b)
        return a.relative < b.relative
    end)
    return entries
end

local function package_framework(ctx, args)
    local platform = assert(args[2], "用法: package framework <platform>")
    assert(platform:match("^[%w][%w_-]*$") and not args[3], "invalid framework platform")
    local fs = ctx.fs
    local entries = fs.walk(ctx.root, function(relative)
        local name = relative:match("[^/]+$")
        if
            name:match("^%.git")
            or name == ".claude"
            or name == ".aone_copilot"
            or name == ".vscode"
            or name == ".DS_Store"
            or name == "node_modules" -- sdk/ts 的依赖树：体积大、.bin 里有跨目录符号链接
            or name:match("^%._")
            or name:match("^%.env")
            or name:match("^%.skytest_.*%.conf%.lua$")
        then
            return false
        end
        if name == "build-output" or name == "release-assets" or name == "coverage" or name == "logs" then
            return false
        end
        if relative == "example/dist" or relative == "example/skyext.zip" or relative == "3rd/sprotodump" then
            return false
        end
        return true
    end)
    local output = fs.join(ctx.root, "release-assets", "skyext-" .. platform .. ".zip")
    publish(fs, output, entries, function(temp)
        local stage = fs.temporary_dir(fs.join(ctx.root, "release-assets"))
        local prepared, err = xpcall(function()
            for _, item in ipairs(entries) do
                local dest = fs.join(stage, item.relative)
                if item.mode == "directory" then
                    fs.mkdir(dest)
                else
                    fs.mkdir(dest:match("^(.*)[/\\][^/\\]+$") or stage)
                    local linked = lfs.link(item.path, dest)
                    if not linked then
                        fs.copy(item.path, dest)
                    end
                end
            end
        end, debug.traceback)
        if not prepared then
            fs.remove_tree(stage)
            error(err, 0)
        end
        local ok, code = pcall(ctx.process.run, { "zip", "-qr", temp, "." }, { cwd = stage })
        fs.remove_tree(stage)
        if ok and code == 0 then
            return
        end
        if not ok or code == 127 then
            io.stderr:write("zip 不可用，回退为无压缩 ZIP\n")
            os.remove(temp)
            zip.write(temp, entries)
            return
        end
        os.remove(temp)
        error("zip failed with exit code " .. tostring(code))
    end)
end

local function package_game(ctx, args)
    assert(#args == 1, "用法: package game")
    local fs = ctx.fs
    local root, game = ctx.root, ctx.game
    local temp = fs.temporary_dir()
    local manifest = {}
    local next_file = 0
    local function add(relative, source, mode)
        manifest[relative] = { relative = relative, path = source, mode = mode }
    end
    local function add_tree(directory, relative, accept)
        if fs.mode(directory) ~= "directory" then
            return
        end
        add(relative, directory, "directory")
        for _, item in ipairs(fs.walk(directory, accept)) do
            add(relative .. "/" .. item.relative, item.path, item.mode)
        end
    end
    local function add_compiled(relative, source)
        local input = fs.read(source)
        if input:sub(1, 4) == "\27Lua" then
            add(relative, source, "file")
            return
        end
        local chunk = assert(loadfile(source, "t"))
        next_file = next_file + 1
        local dest = fs.join(temp, tostring(next_file) .. ".luac")
        fs.write(dest, string.dump(chunk))
        add(relative, dest, "file")
    end
    local ok, err = xpcall(function()
        for _, item in
            ipairs(fs.walk(root, function(relative)
                local first = relative:match("^[^/]+")
                local name = relative:match("[^/]+$")
                if name == "node_modules" then
                    -- sdk/ts 的依赖树：部署包不需要，且 .bin 里有跨目录符号链接
                    return false
                end
                return first ~= "3rd"
                    and first ~= "example"
                    and first ~= "skynet"
                    and first ~= ".git"
                    and first ~= ".github"
                    and first ~= ".claude"
                    and first ~= "coverage"
                    and first ~= "logs"
                    and first ~= "release-assets"
                    and first ~= "build-output"
            end))
        do
            if item.mode == "file" then
                if item.relative:match("%.so$") then
                    add(item.relative, item.path, "file")
                elseif item.relative:match("%.lua$") and not item.relative:match("%.test%.lua$") then
                    add_compiled(item.relative, item.path)
                end
            end
        end
        for _, item in
            ipairs(fs.walk(game, function(relative)
                local first = relative:match("^[^/]+")
                if first == "dist" or first == "3rd" or relative == "skyext.zip" then
                    return false
                end
                -- 本地联调用的配套仓库（OAuth 服务 / 浏览器客户端），不进游戏部署包
                local tool = relative:match("^tools/([^/]+)")
                if tool == "gamepass" or tool == "phaser-game" then
                    return false
                end
                for _, volume in ipairs({
                    "tools/mongodb/db",
                    "tools/etcd/etcd1_data",
                    "tools/etcd/etcd2_data",
                    "tools/etcd/etcd3_data",
                }) do
                    if relative == volume or relative:sub(1, #volume + 1) == volume .. "/" then
                        return false
                    end
                end
                return true
            end))
        do
            if item.mode == "file" then
                local relative = "example/" .. item.relative
                if item.relative:match("%.so$") then
                    add(relative, item.path, "file")
                elseif
                    item.relative:match("%.lua$")
                    and not item.relative:match("%.test%.lua$")
                    and not item.relative:match("^etc/%.skytest_.*%.conf%.lua$")
                then
                    add_compiled(relative, item.path)
                end
            end
        end
        for _, directory in ipairs({ "skynet/luaclib", "skynet/cservice" }) do
            local source = fs.join(root, directory)
            if fs.mode(source) == "directory" then
                for _, item in ipairs(fs.walk(source)) do
                    if item.mode == "file" and item.relative:match("%.so$") then
                        add(directory .. "/" .. item.relative, item.path, "file")
                    end
                end
            end
        end
        local excluded = {
            -- 本地联调用的配套仓库与浏览器验收脚本，不进游戏部署包（phaser-game 的
            -- node_modules 里还有跨目录符号链接，fs.walk 遇到会直接断言失败）
            ["example/tools/gamepass"] = true,
            ["example/tools/phaser-game"] = true,
            ["example/tools/browser_e2e.mjs"] = true,
            ["example/tools/mongodb/db"] = true,
            ["example/tools/etcd/etcd1_data"] = true,
            ["example/tools/etcd/etcd2_data"] = true,
            ["example/tools/etcd/etcd3_data"] = true,
        }
        for _, directory in ipairs({
            "example/etc",
            "example/tools",
            "example/proto",
            "example/schema",
            "example/build",
            "bin",
            "skynet/lualib",
            "skynet/service",
        }) do
            add_tree(fs.join(root, directory), directory, function(relative)
                local path = directory .. "/" .. relative
                if path:match("%.test%.lua$") or path:match("^example/etc/%.skytest_.*%.conf%.lua$") then
                    return false
                end
                for excluded_path in pairs(excluded) do
                    if path == excluded_path or path:sub(1, #excluded_path + 1) == excluded_path .. "/" then
                        return false
                    end
                end
                return true
            end)
        end
        local logs = fs.join(root, "logs")
        if fs.mode(logs) == "directory" then
            add("logs", logs, "directory")
        end
        for _, name in ipairs({ "README.md", "LICENSE" }) do
            local source = fs.join(root, name)
            if fs.mode(source) == "file" then
                add(name, source, "file")
            end
        end
        publish(fs, fs.join(game, "skyext.zip"), sorted_manifest(manifest))
    end, debug.traceback)
    fs.remove_tree(temp)
    if not ok then
        error(err, 0)
    end
end

return function(ctx, _, args)
    local target = args[1]
    if not target or target == "-h" or target == "--help" then
        print([[用法:
  ./bin/skyext package game                 打包示例游戏部署包 example/skyext.zip
  ./bin/skyext package framework <platform> 打包平台框架发布包 release-assets/skyext-<platform>.zip]])
        return 0
    end
    if (target == "game" or target == "framework") and (args[2] == "-h" or args[2] == "--help") and not args[3] then
        print(
            target == "game" and "用法: ./bin/skyext package game"
                or "用法: ./bin/skyext package framework <platform>"
        )
        return 0
    end
    if target == "game" then
        package_game(ctx, args)
    elseif target == "framework" then
        package_framework(ctx, args)
    else
        error("unknown package target: " .. target)
    end
    return 0
end
