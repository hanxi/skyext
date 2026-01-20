local skynet = require "skynet"
local md5 = require "md5"
local log = require "log"
local util_io = require "util.io"
local util_path = require "util.path"
local gm_api = require "gm_api"
local cmd_api = require "cmd_api"

local g_hotfix_history = {}
local g_hotfix_lock = false
local MAX_HISTORY = 100

local CMD = {}
local GM_CMD = {}

local function get_root_dir()
    return skynet.getenv("root")
end

local function find_service_address(service_name)
    local addr = skynet.localname(service_name)
    if addr then
        return addr
    end

    if service_name:sub(1, 1) == "." then
        addr = skynet.localname(service_name:sub(2))
        if addr then
            return addr
        end
    end

    return nil
end

local function load_hotfix_config(hotfix_dir)
    local root_dir = get_root_dir()
    local config_path = util_path.join(root_dir, hotfix_dir, "hotfix.conf.lua")

    log.info("Loading hotfix config", "path", config_path)

    local content, err = util_io.readfile(config_path)
    if not content then
        return false, string.format("Failed to read config file: %s", err or "unknown error")
    end

    local func, load_err = load(content, "@" .. config_path)
    if not func then
        return false, string.format("Failed to load config: %s", load_err)
    end

    local ok, config = pcall(func)
    if not ok then
        return false, string.format("Failed to execute config: %s", config)
    end

    if type(config) ~= "table" then
        return false, "Config must return a table"
    end

    local required_fields = { "desc", "checksum", "gitsha_base", "gitsha_update", "time" }
    for _, field in ipairs(required_fields) do
        if not config[field] then
            return false, string.format("Missing required field: %s", field)
        end
    end

    return true, config
end

local function verify_checksum(config, hotfix_dir, root_dir)
    log.info("Verifying checksum")

    local all_content = {}

    if config.update_files then
        for _, filepath in ipairs(config.update_files) do
            local full_path = util_path.join(root_dir, filepath)
            local content, err = util_io.readfile(full_path)
            if not content then
                log.warn("Failed to read update file", "path", full_path, "error", err)
            else
                table.insert(all_content, content)
            end
        end
    end

    if config.code_files then
        for _, filename in ipairs(config.code_files) do
            local full_path = util_path.join(root_dir, hotfix_dir, filename)
            local content, err = util_io.readfile(full_path)
            if not content then
                return false, string.format("Failed to read code file %s: %s", filename, err or "unknown error")
            end
            table.insert(all_content, content)
        end
    end

    local combined = table.concat(all_content)
    local calculated_checksum = md5.sumhexa(combined)

    if calculated_checksum ~= config.checksum then
        return false, string.format("Checksum mismatch: expected %s, got %s", config.checksum, calculated_checksum)
    end

    log.info("Checksum verified successfully")
    return true
end

local function clear_lua_cache()
    log.info("Clearing lua code cache")

    local result = gm_api.execute_command("clearcache", {})
    if result.code and result.code ~= 0 then
        return false, string.format("clearcache failed: %s", result.error or "unknown error")
    end

    log.info("Code cache cleared successfully")
    return true
end

local function reload_res()
    log.info("Reloading res")

    local result = gm_api.execute_command("reload_res", {})
    if result.code and result.code ~= 0 then
        return false, string.format("reload_res failed: %s", result.error or "unknown error")
    end

    log.info("Res reloaded successfully")
    return true
end

local function reload_sproto()
    log.info("Reloading sproto")

    local result = gm_api.execute_command("reload_sproto_schema", {})
    if result.code and result.code ~= 0 then
        return false, string.format("reload_sproto_schema failed: %s", result.error or "unknown error")
    end

    log.info("Sproto reloaded successfully")
    return true
end

local function reload_orm_schema()
    log.info("Reloading orm schema")

    local result = gm_api.execute_command("reload_orm_schema", {})
    if result.code and result.code ~= 0 then
        return false, string.format("reload_orm_schema failed: %s", result.error or "unknown error")
    end

    log.info("ORM schema reloaded successfully")
    return true
end

local function parse_patcher_targets(code_file_path)
    log.info("Parsing patcher", "path", code_file_path)

    local hotfix_code, err = util_io.readfile(code_file_path)
    if not hotfix_code then
        return false, string.format("Failed to read patcher file: %s", err or "unknown error")
    end

    local func, load_err = load(hotfix_code, "@" .. code_file_path)
    if not func then
        return false, string.format("Failed to load patcher: %s", load_err)
    end

    local ok, patcher = pcall(func)
    if not ok then
        return false, string.format("Failed to execute patcher: %s", patcher)
    end

    if type(patcher) ~= "table" then
        return false, "Patcher must return a table"
    end

    if not patcher.targets or type(patcher.targets) ~= "table" then
        return false, "Patcher must have targets field (array)"
    end

    return true, {
        hotfix_code = hotfix_code,
        targets = patcher.targets,
    }
end

local g_hotfix_code_template = [[
local log = require "log"

local hotfix_code = %q

local f, err = load(hotfix_code, "@hotfix")
if not f then
    log.info("hotfix script load error: ", err)
    return
end

local r, patcher = xpcall(f, debug.traceback)

if not r then
    log.info("hotfix xpcall error: ", patcher)
    return
end

local ok, result = pcall(patcher.run)
if ok then
    return result
else
    error("Patcher execution failed: " .. tostring(result))
end
]]

local function inject_to_service(service_addr, hotfix_code, filename)
    log.info("Injecting code to service", "filename", filename)

    local inject_source = string.format(g_hotfix_code_template, hotfix_code)

    local ok, result = pcall(skynet.call, service_addr, "debug", "RUN", inject_source, filename)
    if not ok then
        return false, string.format("Failed to inject code: %s", result)
    end

    return true, result
end

local function inject_code_files(code_files, hotfix_dir)
    log.info("Injecting code files", "count", #code_files)

    local root_dir = get_root_dir()
    local results = {}

    for _, filename in ipairs(code_files) do
        local code_file_path = util_path.join(root_dir, hotfix_dir, filename)

        local ok, patcher_info = parse_patcher_targets(code_file_path)
        if not ok then
            table.insert(results, {
                file = filename,
                success = false,
                error = patcher_info,
            })
            log.warn("Failed to parse patcher", "file", filename, "error", patcher_info)
            goto continue
        end

        for _, service_name in ipairs(patcher_info.targets) do
            local service_addr = find_service_address(service_name)
            if not service_addr then
                table.insert(results, {
                    file = filename,
                    service = service_name,
                    success = false,
                    error = "Service not found",
                })
                log.warn("Service not found", "service", service_name)
                goto continue_service
            end

            local inject_ok, inject_result = inject_to_service(service_addr, patcher_info.hotfix_code, filename)

            if not inject_ok then
                table.insert(results, {
                    file = filename,
                    service = service_name,
                    success = false,
                    error = inject_result,
                })
                log.warn("Failed to inject code", "file", filename, "service", service_name, "error", inject_result)
            else
                table.insert(results, {
                    file = filename,
                    service = service_name,
                    success = true,
                    result = inject_result,
                })
                log.info("Code injected successfully", "file", filename, "service", service_name)
            end

            ::continue_service::
        end

        ::continue::
    end

    return true, results
end

local function execute_hotfix(hotfix_dir)
    if g_hotfix_lock then
        return false, "Another hotfix is in progress"
    end

    g_hotfix_lock = true

    local start_time = os.time()
    local steps = {}
    local root_dir = get_root_dir()

    local function record_step(name, success, result)
        table.insert(steps, {
            name = name,
            success = success,
            result = result,
        })
        if not success then
            log.warn("Hotfix step failed", "step", name, "error", result)
        end
    end

    local function cleanup()
        g_hotfix_lock = false
    end

    local ok, err = pcall(function()
        log.info("Starting hotfix", "dir", hotfix_dir)
        local load_ok, config = load_hotfix_config(hotfix_dir)
        if not load_ok then
            record_step("load_config", false, config)
            return
        end
        record_step("load_config", true, "Config loaded")

        local verify_ok, verify_err = verify_checksum(config, hotfix_dir, root_dir)
        if not verify_ok then
            record_step("verify_checksum", false, verify_err)
            return
        end
        record_step("verify_checksum", true, "Checksum verified")

        log.info(
            "Hotfix info",
            "desc",
            config.desc,
            "gitsha_base",
            config.gitsha_base,
            "gitsha_update",
            config.gitsha_update,
            "time",
            config.time
        )

        if config.clearcache then
            local clear_ok, clear_err = clear_lua_cache()
            record_step("clear_cache", clear_ok, clear_ok and "Cache cleared" or clear_err)
        end

        if config.reload_res then
            local res_ok, res_err = reload_res()
            record_step("reload_res", res_ok, res_ok and "Res reloaded" or res_err)
        end

        if config.reload_sproto then
            local sproto_ok, sproto_err = reload_sproto()
            record_step("reload_sproto", sproto_ok, sproto_ok and "Sproto reloaded" or sproto_err)
        end

        if config.reload_orm_schema then
            local schema_ok, schema_err = reload_orm_schema()
            record_step("reload_orm_schema", schema_ok, schema_ok and "ORM schema reloaded" or schema_err)
        end

        if config.code_files and #config.code_files > 0 then
            local inject_ok, inject_results = inject_code_files(config.code_files, hotfix_dir)
            record_step("inject_code", inject_ok, inject_results)
        end

        local history_entry = {
            time = os.date("%Y-%m-%d %H:%M:%S", start_time),
            desc = config.desc,
            gitsha_base = config.gitsha_base,
            gitsha_update = config.gitsha_update,
            hotfix_dir = hotfix_dir,
            steps = steps,
            success = true,
        }

        for _, step in ipairs(steps) do
            if not step.success then
                history_entry.success = false
                break
            end
        end

        table.insert(g_hotfix_history, 1, history_entry)

        while #g_hotfix_history > MAX_HISTORY do
            table.remove(g_hotfix_history)
        end

        log.info("Hotfix completed", "success", history_entry.success, "dir", hotfix_dir)
    end)

    cleanup()

    if not ok then
        log.warn("Hotfix execution error", "error", err)
        return false, string.format("Hotfix execution error: %s", err)
    end

    local all_success = true
    for _, step in ipairs(steps) do
        if not step.success then
            all_success = false
            break
        end
    end

    return all_success,
        {
            steps = steps,
            message = all_success and "Hotfix completed successfully" or "Hotfix completed with errors",
        }
end

GM_CMD.hotfix = {
    desc = "执行热更新",
    params = {
        hotfix_dir = "热更包目录路径（相对于工程根目录，如 hotfix/20260120-patch1）",
    },
    handler = function(params)
        local hotfix_dir = params.hotfix_dir
        if not hotfix_dir then
            return false, "Missing required parameter: hotfix_dir"
        end

        return execute_hotfix(hotfix_dir)
    end,
}

GM_CMD.hotfix_history = {
    desc = "查看热更历史",
    params = {
        limit = "返回最近 N 条记录（可选，默认 10）",
    },
    handler = function(params)
        local limit = tonumber(params.limit) or 10
        limit = math.min(limit, #g_hotfix_history)

        local result = {}
        for i = 1, limit do
            table.insert(result, g_hotfix_history[i])
        end

        return true, result
    end,
}

skynet.start(function()
    gm_api.register(GM_CMD)
    cmd_api.dispatch(CMD)
    log.info("Hotfix service started")
end)
