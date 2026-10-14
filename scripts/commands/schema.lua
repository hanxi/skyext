local orm_compat = require "skyext.orm_compat"

local DEFINE = "build/lualib/game/orm/schema_define.lua"
local LOCK = "schema/schema.lock.lua"

local function usage()
    print([[用法:
  ./bin/skyext schema check            对比当前 schema 与基线，不兼容则退出码 1
  ./bin/skyext schema accept [--force] 把当前 schema 记为新基线（不兼容时需要 --force）

基线是 example/schema/schema.lock.lua，跟着改动一起提交，评审时能直接看到 schema 变了什么。
两个命令都要求先执行 ./bin/skyext generate schema。]])
end

local LOCK_HEADER = [[
-- ORM schema 基线：上一次确认过的结构，由 ./bin/skyext schema accept 写入。
-- 不要手改；schema check 用它判断新 schema 还能不能读旧文档。
--
-- retired 记的是删过的名字。删字段只是不再读它，值一直躺在库里，
-- 所以这些名字不能再用，否则旧值会被当成新值读出来。
]]

local function write_lock(ctx, lock, lock_path)
    ctx.fs.write(lock_path, LOCK_HEADER .. orm_compat.encode(lock))
    -- 交给 stylua 定版式，免得这份文件在 stylua --check 下挂掉
    assert(ctx.process.run({ "stylua", lock_path }, { cwd = ctx.root }) == 0, "stylua failed")
end

-- 两份文件都是纯数据表，用空环境加载，免得生成物里的东西碰到全局
local function load_table(fs, path, hint)
    assert(fs.mode(path) == "file", hint)
    local chunk = assert(load(fs.read(path), "@" .. path, "t", {}))
    local data = chunk()
    assert(type(data) == "table", "not a schema table: " .. path)
    return data
end

local function report(changes)
    for _, change in ipairs(changes) do
        print(orm_compat.format(change))
    end
    return orm_compat.count(changes)
end

return function(ctx, _, args)
    local action = args[1]
    if not action or action == "-h" or action == "--help" then
        usage()
        return 0
    end
    assert(action == "check" or action == "accept", "未知命令: " .. action)
    local force = args[2] == "--force"
    assert(not args[2] or (force and action == "accept" and not args[3]), "用法: schema " .. action)

    local fs = ctx.fs
    local define_path = fs.join(ctx.game, DEFINE)
    local lock_path = fs.join(ctx.game, LOCK)
    local current = load_table(fs, define_path, "schema 还没生成，先执行 ./bin/skyext generate schema")

    if fs.mode(lock_path) ~= "file" then
        if action == "check" then
            io.stderr:write(
                "没有基线: " .. lock_path .. "\n执行 ./bin/skyext schema accept 记下当前 schema\n"
            )
            return 1
        end
        write_lock(ctx, { types = current, retired = { fields = {}, types = {} } }, lock_path)
        print("已记录基线: " .. lock_path)
        return 0
    end

    local baseline = load_table(fs, lock_path, "基线读不出来: " .. lock_path)
    local changes = orm_compat.diff(baseline, current)
    if #changes == 0 then
        print("schema 与基线一致")
        return 0
    end

    local counts = report(changes)
    if counts[orm_compat.BREAK] > 0 and not force then
        io.stderr:write(
            string.format(
                "\n%d 处不兼容改动：线上文档按旧结构写的，新代码读不回来。\n"
                    .. "改名、改类型、重用删过的名字，都请换一种做法：加一个新名字的字段，\n"
                    .. "让玩法代码双写一段时间，再删旧字段。\n",
                counts[orm_compat.BREAK]
            )
        )
        return 1
    end

    if action == "check" then
        io.stderr:write("\n基线落后于当前 schema，确认上面的改动后执行 ./bin/skyext schema accept\n")
        return 1
    end
    write_lock(ctx, orm_compat.build_lock(baseline, current), lock_path)
    print("\n已更新基线: " .. lock_path)
    return 0
end
