-- lua 脚本工具执行入口文件

-- 获取当前 run.lua 的所在目录
local function get_script_directory()
    local script_path = arg[0]

    if script_path:match(".+%.lua") then
        -- 如果 arg[0] 是相对/绝对路径，尝试用 debug 获取真实路径
        local info = debug.getinfo(1, "S")
        script_path = info.source:sub(2)  -- 去掉 '@'
    end

    -- 提取目录部分
    local script_dir = script_path:match("(.*/)") or "./"
    return script_dir
end

-- 设置路径为全局变量
_G.SCRIPT_DIRECTORY = get_script_directory()

package.path = package.path .. ";" .. SCRIPT_DIRECTORY .. "../3rd/sproto-orm/tools/sprotodump/?.lua"
package.path = package.path .. ";" .. SCRIPT_DIRECTORY .. "../lualib/?.lua"
package.cpath = package.cpath .. ";" .. SCRIPT_DIRECTORY .. "../skynet/luaclib/?.so"
package.cpath = package.cpath .. ";" .. SCRIPT_DIRECTORY .. "../luaclib/?.so"

-- 解析命令行参数
local target_script = arg[1]
if not target_script then
    print("Usage: lua run.lua <script.lua> [args...]")
    os.exit(1)
end

-- 检查脚本文件是否存在
local function file_exists(name)
    local f = io.open(name, "r")
    if f then
        io.close(f)
        return true
    else
        return false
    end
end

if not file_exists(target_script) then
    print("Error: script '" .. target_script .. "' not found.")
    os.exit(1)
end

-- 调整 arg 表：让目标脚本认为自己是主脚本
-- 原始 arg: { run.lua, target.lua, arg1, arg2, ... }
-- 我们要构造一个新的 arg 表给目标脚本：{ target.lua, arg1, arg2, ... }
local new_arg = { [0] = target_script }
for i = 2, #arg do
    new_arg[i - 1] = arg[i]
end

-- 使用 dofile 加载并执行目标脚本，并设置 _G.arg = new_arg
local env = {
    arg = new_arg,
    dofile = dofile,
    package = package,
    _G = _G
}
setmetatable(env, { __index = _G })

-- 加载并运行目标脚本
local chunk, err = loadfile(target_script, "bt", env)
if not chunk then
    print("Error loading script: " .. err)
    os.exit(1)
end

-- 执行脚本
local success, result = pcall(chunk)
if not success then
    print("Error running script: " .. result)
    os.exit(1)
end

