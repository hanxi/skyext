-- 文档级 schema 迁移。
--
-- orm schema 描述的是“现在的代码期望文档长什么样”，库里却还躺着按旧 schema 写下的
-- 文档。字段改名、拆表、补默认值这类结构变更没法靠 schema 本身完成：旧文档一进
-- orm.new 就会在 _check_kv 上炸开。
--
-- 这里给每个集合维护一条有序的迁移链，文档里记一个 _schema_version，加载时把缺的
-- 那几步按序补上。迁移函数直接原地改 mongo 解码出来的普通表，还没有 orm 的类型约束，
-- 所以才有能力把文档从旧形状搬到新形状。

local M = {}

-- 文档里记录 schema 版本的字段。它和 _version（乐观锁计数）、_fence（抢占令牌）一样
-- 由 dbmgr 维护，不在 orm schema 里声明，建 doc 之前必须剔除。
M.VERSION_FIELD = "_schema_version"

local function step_error(dbcoll, index, msg)
    error(string.format("migration %s[%d]: %s", dbcoll, index, msg), 0)
end

-- 校验迁移定义，整理成按集合分组的有序链。
--
-- 每一步都必须显式写出 version，且等于它在表里的下标。迁移链是多人并行往末尾追加的，
-- 漏写或插队在 git 合并时不会产生冲突，却会让两份代码对“第 3 版长什么样”产生分歧。
-- 显式版本号把这种分歧提前成启动期的报错。
function M.compile(defs)
    assert(type(defs) == "table", "migrations must be a table")
    local compiled = {}
    for dbcoll, steps in pairs(defs) do
        assert(type(dbcoll) == "string", "migration collection name must be a string")
        assert(type(steps) == "table", "migrations for " .. tostring(dbcoll) .. " must be a table")
        local list = {}
        for index, step in ipairs(steps) do
            if type(step) ~= "table" then
                step_error(dbcoll, index, "step must be a table")
            end
            if step.version ~= index then
                step_error(dbcoll, index, "version must be " .. index .. ", got " .. tostring(step.version))
            end
            if type(step.desc) ~= "string" or step.desc == "" then
                step_error(dbcoll, index, "desc must be a non-empty string")
            end
            if type(step.migrate) ~= "function" then
                step_error(dbcoll, index, "migrate must be a function")
            end
            list[index] = step
        end
        local total = 0
        for _ in pairs(steps) do
            total = total + 1
        end
        if total ~= #list then
            -- 中间漏了一个下标，后面的步骤会被 ipairs 直接跳过，静默少跑几次迁移
            error(string.format("migration %s: has %d steps but the chain stops at %d", dbcoll, total, #list), 0)
        end
        compiled[dbcoll] = list
    end
    return compiled
end

-- 当前代码对应的 schema 版本；该集合没有迁移就是 0。
function M.target(compiled, dbcoll)
    local list = compiled[dbcoll]
    return list and #list or 0
end

-- 读出文档记录的 schema 版本。迁移机制上线前写入的老文档没有这个字段，按 0 算。
function M.version_of(value)
    local raw = value[M.VERSION_FIELD]
    if raw == nil then
        return 0
    end
    local version = type(raw) == "number" and math.tointeger(raw)
    if not version or version < 0 then
        return nil, string.format("invalid %s: %s", M.VERSION_FIELD, tostring(raw))
    end
    return version
end

-- 把 value 原地升级到最新版本，返回升级后的版本号；已经是最新则原样返回 from。
function M.apply(compiled, dbcoll, value, from)
    local target = M.target(compiled, dbcoll)
    if from > target then
        -- 文档是更高版本的代码写下的。旧代码不认识新结构，继续跑只会把数据越写越坏，
        -- 回滚部署时宁可拒绝加载，也不能让旧逻辑去动新文档。
        return nil, string.format("%s document schema version %d is ahead of code version %d", dbcoll, from, target)
    end
    for index = from + 1, target do
        local step = compiled[dbcoll][index]
        local ok, err = pcall(step.migrate, value)
        if not ok then
            return nil, string.format("%s migration %d (%s) failed: %s", dbcoll, index, step.desc, tostring(err))
        end
    end
    return target
end

return M
