--[[
两项搜索路径检查，防的都是「不报错，只是悄悄加载到了别的文件」这类问题。

1. 引擎代码里的裸名 require
   package.path 的顺序是 节点目录 > 游戏 lualib > 引擎 lualib > skynet lualib
   （见 example/etc/paths.conf.lua）。引擎模块只要写成 require "foo"，游戏层放一个
   同名 foo.lua 就会把它顶掉——不报错，行为诡异。引擎自己的模块一律走
   skyext.* / orm.* 命名空间。

2. 节点目录名与服务名撞车
   luaservice 里有 nodes/?/main.lua 这条通配，任何「服务名 == 节点目录名」的
   newservice 都会解析到那个节点的主程序。典型事故：节点叫 gate，clusterd 监听时
   newservice("gate") 起的是网关节点的 main。

用法：lua scripts/ci/check_paths.lua [repo_root]
]]

local root = (... or arg[1] or "."):gsub("/+$", "")

local ENGINE_ROOTS = {
    skyext = true,
    orm = true,
    skytest = true,
}

local function popen_lines(cmd)
    local out = {}
    local pipe = assert(io.popen(cmd))
    for line in pipe:lines() do
        out[#out + 1] = line
    end
    pipe:close()
    return out
end

local function exists(path)
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

local function basename(path, suffix)
    local name = path:match("([^/]+)$")
    if suffix then
        name = name:gsub(suffix .. "$", "")
    end
    return name
end

local violations = {}
local function report(file, line, msg)
    violations[#violations + 1] = string.format("%s:%s: %s", file, line, msg)
end

-------------------------------------------------------------------
-- 外部模块名的白名单：skynet 自带的、以及编译进 luaclib 的 C 模块。
-- 动态枚举而不是写死清单，免得加一个 C 模块就要改这里。
-- .so 是构建产物（被 gitignore），CI 里不编译就扫不到；所以 C 模块
-- 一律从 Makefile 的声明枚举（build.mk / skynet 的 Makefile），
-- .so 扫描只作为本地已构建产物的补充。
-------------------------------------------------------------------
-- 从 Makefile 里取 VAR = a b c 的清单，支持反斜杠续行；$(...) 这类
-- make 变量引用跳过（如 skynet 的 $(TLS_MODULE)，视平台而定）。
local function makefile_list(path, varname)
    local names = {}
    local f = io.open(path, "r")
    if not f then
        return names
    end
    local value, pending
    for line in f:lines() do
        if pending then
            value = value .. " " .. line
        else
            value = line:match("^" .. varname .. "%s*=%s*(.*)$")
        end
        if value then
            pending = value:match("\\%s*$") ~= nil
            value = value:gsub("\\%s*$", "")
            if not pending then
                break
            end
        end
    end
    f:close()
    for token in (value or ""):gmatch("%S+") do
        if not token:find("[%$#()]") then
            names[token] = true
        end
    end
    return names
end

local function external_modules()
    local names = {}
    local dirs = {
        { root .. "/skynet/lualib", "%.lua$" },
        { root .. "/skynet/luaclib", "%.so$" },
        { root .. "/luaclib", "%.so$" },
        { root .. "/lualib-src", "%.c$" },
    }
    for _, spec in ipairs(dirs) do
        local dir, suffix = spec[1], spec[2]
        for _, path in ipairs(popen_lines(string.format("ls -1 %q 2>/dev/null", dir))) do
            if path:match(suffix) then
                names[basename(path, suffix:gsub("%%", ""):gsub("%$", ""))] = true
            elseif not path:match("%.") then
                -- skynet/lualib/http 这类目录，require "http.url" 走的是它
                names[path] = true
            end
        end
    end
    local makefiles = {
        { root .. "/build.mk", "SKYEXT_LUA_CLIB" },
        { root .. "/skynet/Makefile", "LUA_CLIB" },
    }
    for _, spec in ipairs(makefiles) do
        for name in pairs(makefile_list(spec[1], spec[2])) do
            names[name] = true
        end
    end
    return names
end

-------------------------------------------------------------------
-- 检查一：裸名 require
-------------------------------------------------------------------
-- 注释里出现的 require 不算。逐行扫，顺带跟踪 --[[ ]] 块。
local function iter_code_lines(path)
    local lines = {}
    local in_block = false
    local n = 0
    for line in io.lines(path) do
        n = n + 1
        local code = line
        if in_block then
            local close = code:find("%]%]")
            if close then
                code = code:sub(close + 2)
                in_block = false
            else
                code = ""
            end
        end
        local open = code:find("%-%-%[%[")
        if open then
            code = code:sub(1, open - 1)
            in_block = true
        else
            code = code:gsub("%-%-.*$", "")
        end
        if code ~= "" then
            lines[#lines + 1] = { n = n, code = code }
        end
    end
    return lines
end

local function check_bare_requires()
    local externals = external_modules()
    local files = popen_lines(
        string.format(
            "find %q/lualib/skyext %q/lualib/orm %q/lualib/skytest %q/service -name '*.lua' 2>/dev/null",
            root,
            root,
            root,
            root
        )
    )

    for _, path in ipairs(files) do
        local dir = path:match("^(.*)/[^/]+$")
        for _, entry in ipairs(iter_code_lines(path)) do
            for name in entry.code:gmatch('require%s*%(?%s*"([^"]+)"') do
                if not name:find("%.") and not ENGINE_ROOTS[name] and not externals[name] then
                    -- 服务自带的同目录模块（service/logger/cmd.lua 这种）是安全的：
                    -- 加载这个服务时 SERVICE_PATH 排在 package.path 最前面，游戏层顶不掉。
                    -- 这个豁免只对 service/ 下的多文件服务成立；lualib/ 里的同名文件
                    -- 恰恰就是会被顶掉的那一个，不能当成豁免理由。
                    local in_service_dir = path:match("^.*/service/[^/]+/[^/]+%.lua$") ~= nil
                    local sibling = in_service_dir
                        and (exists(dir .. "/" .. name .. ".lua") or exists(dir .. "/" .. name .. "/init.lua"))
                    if not sibling then
                        report(
                            path,
                            entry.n,
                            string.format(
                                'bare require "%s" can be shadowed by the game layer; '
                                    .. "use the skyext.* / orm.* namespace",
                                name
                            )
                        )
                    end
                end
            end
        end
    end
end

-------------------------------------------------------------------
-- 检查二：节点目录名撞服务名
-------------------------------------------------------------------
local function service_names()
    local names = {}
    local function add_dir(dir)
        for _, entry in ipairs(popen_lines(string.format("ls -1 %q 2>/dev/null", dir))) do
            if entry:match("%.lua$") then
                names[basename(entry, "%.lua")] = dir
            elseif exists(dir .. "/" .. entry .. "/main.lua") then
                names[entry] = dir
            end
        end
    end
    add_dir(root .. "/service")
    add_dir(root .. "/skynet/service")
    for _, dir in
        ipairs(popen_lines(string.format("find %q -name nodes -type d -not -path '*/skynet/*' 2>/dev/null", root)))
    do
        add_dir(dir:gsub("/nodes$", "/service"))
    end
    return names
end

local function check_node_name_collisions()
    local services = service_names()
    for _, nodes_dir in
        ipairs(popen_lines(string.format("find %q -name nodes -type d -not -path '*/skynet/*' 2>/dev/null", root)))
    do
        for _, node in ipairs(popen_lines(string.format("ls -1 %q 2>/dev/null", nodes_dir))) do
            if exists(nodes_dir .. "/" .. node .. "/main.lua") and services[node] then
                report(
                    nodes_dir .. "/" .. node,
                    1,
                    string.format(
                        "node directory name collides with service %s/%s.lua; "
                            .. "luaservice has a nodes/?/main.lua wildcard, so newservice(%q) "
                            .. "would launch this node's main instead",
                        services[node],
                        node,
                        node
                    )
                )
            end
        end
    end
end

check_bare_requires()
check_node_name_collisions()

if #violations > 0 then
    io.stderr:write("search path check failed:\n")
    for _, v in ipairs(violations) do
        io.stderr:write("  " .. v .. "\n")
    end
    os.exit(1)
end

print("search path check passed")
