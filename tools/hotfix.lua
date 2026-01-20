-- 热更新工具
local util_io = require "util.io"
local util_path = require "util.path"

-- 获取工程根目录
local function get_root_dir()
    local script_path = arg[0]
    -- 获取脚本所在目录
    local script_dir = script_path:match("(.*/)") or "./"
    -- 向上两级到工程根目录
    return script_dir .. "../"
end

-- 打印帮助信息
local function print_help()
    print([[
Hotfix Tool - 热更新配置管理工具

Usage: hotfix.sh <command> [options]

Commands:
  refresh <hotfix_dir>    刷新热更包配置文件的 time 和 checksum
                          hotfix_dir: 热更包目录路径（相对于工程根目录）
                          例如: hotfix/20260120-patch1

Options:
  -h, --help             显示帮助信息

Examples:
  ./tools/hotfix.sh refresh hotfix/20260120-patch1
  ./tools/hotfix.sh -h

Description:
  refresh 命令会自动计算热更包中所有文件的 checksum，并更新配置文件中的
  time 和 checksum 字段。计算 checksum 时会包含：
  - config.update_files 中列出的所有文件
  - config.code_files 中列出的所有代码文件
]])
end

-- 检查文件是否存在
local function file_exists(filepath)
    local f = io.open(filepath, "r")
    if f then
        f:close()
        return true
    end
    return false
end

-- 加载热更配置文件
local function load_hotfix_config(config_path)
    local content, err = util_io.readfile(config_path)
    if not content then
        return nil, string.format("Failed to read config file: %s", err or "unknown error")
    end

    local func, load_err = load(content, "@" .. config_path)
    if not func then
        return nil, string.format("Failed to load config: %s", load_err)
    end

    local ok, config = pcall(func)
    if not ok then
        return nil, string.format("Failed to execute config: %s", config)
    end

    if type(config) ~= "table" then
        return nil, "Config must return a table"
    end

    return config, content
end

-- 使用系统命令计算 MD5
local function calculate_md5(content)
    -- 创建临时文件
    local tmp_file = os.tmpname()
    local f = io.open(tmp_file, "wb")
    if not f then
        return nil, "Failed to create temporary file"
    end
    f:write(content)
    f:close()

    -- 尝试使用 md5sum 命令（Linux）
    local handle = io.popen("md5sum " .. tmp_file .. " 2>/dev/null")
    local result = handle:read("*a")
    handle:close()

    if result and result ~= "" then
        os.remove(tmp_file)
        return result:match("^(%x+)")
    end

    -- 尝试使用 md5 命令（macOS）
    handle = io.popen("md5 -q " .. tmp_file .. " 2>/dev/null")
    result = handle:read("*a")
    handle:close()

    os.remove(tmp_file)

    if result and result ~= "" then
        return result:match("^(%x+)")
    end

    return nil, "MD5 command not found"
end

-- 计算 checksum
local function calculate_checksum(config, hotfix_dir, root_dir)
    local all_content = {}

    -- 读取 update_files
    if config.update_files then
        for _, filepath in ipairs(config.update_files) do
            local full_path = util_path.join(root_dir, filepath)
            if not file_exists(full_path) then
                return nil, string.format("Update file not found: %s", filepath)
            end
            local content, err = util_io.readfile(full_path)
            if not content then
                return nil, string.format("Failed to read update file %s: %s", filepath, err or "unknown error")
            end
            table.insert(all_content, content)
        end
    end

    -- 读取 code_files
    if config.code_files then
        for _, filename in ipairs(config.code_files) do
            local full_path = util_path.join(root_dir, hotfix_dir, filename)
            if not file_exists(full_path) then
                return nil, string.format("Code file not found: %s", filename)
            end
            local content, err = util_io.readfile(full_path)
            if not content then
                return nil, string.format("Failed to read code file %s: %s", filename, err or "unknown error")
            end
            table.insert(all_content, content)
        end
    end

    local combined = table.concat(all_content)
    local checksum, err = calculate_md5(combined)
    if not checksum then
        return nil, err
    end

    return checksum
end

-- 更新配置文件
local function update_config_file(config_path, original_content, new_time, new_checksum)
    -- 替换 time 字段
    local updated_content = original_content:gsub('(time%s*=%s*)"[^"]*"', string.format('%%1"%s"', new_time))

    -- 替换 checksum 字段
    updated_content = updated_content:gsub('(checksum%s*=%s*)"[^"]*"', string.format('%%1"%s"', new_checksum))

    local ok = util_io.writefile(config_path, updated_content)
    if not ok then
        return false, "Failed to write config file"
    end

    return true
end

-- refresh 命令实现
local function cmd_refresh(hotfix_dir)
    if not hotfix_dir then
        print("Error: Missing required parameter: hotfix_dir")
        print("")
        print_help()
        os.exit(1)
    end

    local root_dir = get_root_dir()
    local config_path = util_path.join(root_dir, hotfix_dir, "hotfix.conf.lua")

    print(string.format("Root directory: %s", root_dir))
    print(string.format("Hotfix directory: %s", hotfix_dir))
    print(string.format("Config path: %s", config_path))
    print("")

    -- 检查配置文件是否存在
    if not file_exists(config_path) then
        print(string.format("Error: Config file not found: %s", config_path))
        os.exit(1)
    end

    -- 加载配置文件
    print("Loading config file...")
    local config, original_content = load_hotfix_config(config_path)
    if not config then
        print(string.format("Error: %s", original_content))
        os.exit(1)
    end
    print("Config loaded successfully")
    print("")

    -- 计算 checksum
    print("Calculating checksum...")
    local checksum, err = calculate_checksum(config, hotfix_dir, root_dir)
    if not checksum then
        print(string.format("Error: %s", err))
        os.exit(1)
    end
    print(string.format("Checksum: %s", checksum))
    print("")

    -- 获取当前时间
    local current_time = os.date("%Y-%m-%d %H:%M:%S")
    print(string.format("Current time: %s", current_time))
    print("")

    -- 更新配置文件
    print("Updating config file...")
    local ok, update_err = update_config_file(config_path, original_content, current_time, checksum)
    if not ok then
        print(string.format("Error: %s", update_err))
        os.exit(1)
    end

    print("Config file updated successfully!")
    print("")
    print("Summary:")
    print(string.format("  Time: %s -> %s", config.time or "N/A", current_time))
    print(string.format("  Checksum: %s -> %s", config.checksum or "N/A", checksum))
end

-- 主函数
local function main()
    local command = arg[1]

    -- 处理帮助参数
    if not command or command == "-h" or command == "--help" then
        print_help()
        os.exit(0)
    end

    -- 处理子命令
    if command == "refresh" then
        local hotfix_dir = arg[2]
        cmd_refresh(hotfix_dir)
    else
        print(string.format("Error: Unknown command: %s", command))
        print("")
        print_help()
        os.exit(1)
    end
end

-- 执行主函数
main()
