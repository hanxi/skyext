local function run_script(path, args)
    local script_arg = { [0] = path }
    for i, value in ipairs(args) do
        script_arg[i] = value
    end
    local env = setmetatable({ arg = script_arg }, { __index = _G })
    assert(loadfile(path, "bt", env))()
end

local function sproto_files(fs, root)
    local files = {}
    for _, item in ipairs(fs.walk(root)) do
        if item.mode == "file" and item.relative:match("%.sproto$") then
            files[#files + 1] = item.relative:gsub("\\", "/")
        end
    end
    assert(#files > 0, "no .sproto files found in " .. root)
    return files
end

return function(ctx, _, args)
    if not args[1] or args[1] == "-h" or args[1] == "--help" then
        print("用法: ./bin/skyext generate <proto|schema>")
        return 0
    end
    local kind = args[1]
    if (kind == "proto" or kind == "schema") and (args[2] == "-h" or args[2] == "--help") and not args[3] then
        print("用法: ./bin/skyext generate " .. kind)
        return 0
    end
    assert((kind == "proto" or kind == "schema") and not args[2], "用法: generate <proto|schema>")
    local fs = ctx.fs
    local parser = fs.join(ctx.root, "3rd/sprotodump")
    assert(
        fs.mode(fs.join(parser, "core.lua")) == "file",
        "missing sprotodump: git submodule update --init 3rd/sprotodump"
    )
    package.path = package.path .. ";" .. fs.join(parser, "?.lua")
    fs.with_dir(ctx.game, function()
        if kind == "proto" then
            fs.mkdir("build/proto")
            local files = sproto_files(fs, "proto")
            for i, file in ipairs(files) do
                files[i] = "proto/" .. file
            end
            run_script(fs.join(ctx.game, "tools/proto2spb.lua"), files)
            assert(fs.mode("build/proto/sproto.spb") == "file", "protocol output not generated")
        else
            local output = "build/lualib/game/orm"
            fs.mkdir(output)
            local files = sproto_files(fs, "schema")
            for i, file in ipairs(files) do
                files[i] = "schema/" .. file
            end
            local definition = output .. "/schema_define.lua"
            local schema = output .. "/schema.lua"
            table.insert(files, 1, definition)
            run_script(fs.join(ctx.root, "scripts/tools/sproto_orm/sproto2lua.lua"), files)
            assert(fs.mode(definition) == "file", "schema definitions not generated")
            run_script(fs.join(ctx.root, "scripts/tools/sproto_orm/gen_schema.lua"), { schema, definition })
            assert(fs.mode(schema) == "file", "schema not generated")
            local code = ctx.process.run({ "stylua", fs.join(ctx.game, output) }, { cwd = ctx.root })
            assert(code == 0, "stylua failed (install stylua to format generated schema)")
        end
    end)
    return 0
end
