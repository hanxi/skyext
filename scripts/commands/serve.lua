return function(ctx, _, args)
    local fs = ctx.fs
    if not args[1] or args[1] == "--help" or args[1] == "-h" then
        print("用法: ./bin/skyext serve <node|config-file> [skynet-args...]")
        print("可用节点:")
        for _, name in ipairs(fs.entries(fs.join(ctx.game, "etc"))) do
            local node = name:match("^(.*)%.conf%.lua$")
            if node and node ~= "core" and node ~= "paths" then
                print("  " .. node)
            end
        end
        return 0
    end

    local target = args[1]
    local config = fs.mode(target) == "file" and fs.absolute(target) or fs.join(ctx.root, target)
    if fs.mode(config) ~= "file" then
        assert(target:match("^[%w_-]+$"), "找不到配置文件: " .. target)
        config = fs.join(ctx.game, "etc", target .. ".conf.lua")
    end
    assert(fs.mode(config) == "file", "找不到配置文件: " .. config)
    local binary = fs.join(ctx.root, "bin", package.config:sub(1, 1) == "\\" and "skynet.exe" or "skynet")
    assert(fs.mode(binary) == "file", "未构建 skynet，请先执行 make build")
    local argv = { binary, config }
    for i = 2, #args do
        argv[#argv + 1] = args[i]
    end
    local code = ctx.process.run(argv, { cwd = ctx.root })
    return code
end
