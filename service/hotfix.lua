local skynet = require "skynet"
local cjson = require "cjson"
local log = require "log"
local util_io = require "util.io"
local util_path = require "util.path"
local hotfix_checksum = require "hotfix_checksum"
local gm_api = require "gm_api"
local cmd_api = require "cmd_api"

local g_hotfix_history = {}
local g_hotfix_lock = nil
local MAX_HISTORY = 100
local LOCK_MAX_HOLD = 300
local HISTORY_MAX_READ = 32 * 1024

local CMD = {}
local GM_CMD = {}

local STEP_GUIDANCE = {
    load_config = "检查 hotfix.conf.lua 必填字段(desc/checksum/gitsha_base/gitsha_update/time)，修正后重新执行",
    verify_checksum = "先在开发机执行 ./tools/hotfix.sh refresh <dir> 重新生成 checksum；确认磁盘文件与热更包未被改动",
    clear_cache = "GM 通道异常，检查 .gm 服务是否正常运行；本包尚未注入任何代码，可安全重试",
    reload_res = "res 未重载，配表与代码可能不一致；排查 sharetable 后重试或回退 update_files",
    reload_sproto = "sproto schema 重载失败，检查 sproto 文件格式；可安全重试",
    reload_orm_schema = "ORM schema 重载失败，检查 schema 定义；可安全重试",
    inject_code = "部分服务可能已打补丁，禁止直接重跑整包；按 results 中逐服务确认状态后决定重注或回滚",
    internal_error = "热更执行过程中出现未预期的内部错误，请检查日志排查原因",
}

local function get_history_path()
    return skynet.getenv("root") .. "/hotfix_history.jsonl"
end

local function persist_history(entry)
    local ok_enc, json = pcall(cjson.encode, entry)
    if not ok_enc then
        log.warn("Failed to encode history entry", "error", json)
        return
    end
    local fh = io.open(get_history_path(), "a")
    if not fh then
        log.warn("Failed to open history file for append")
        return
    end
    local wok, werr = fh:write(json .. "\n")
    fh:close()
    if not wok then
        log.warn("Failed to write history entry", "error", werr)
    end
end

local function load_history()
    local path = get_history_path()
    local fh = io.open(path, "r")
    if not fh then
        return
    end

    local file_size = fh:seek("end")

    local read_from = 0
    if file_size > HISTORY_MAX_READ then
        read_from = file_size - HISTORY_MAX_READ
    end

    fh:seek("set", read_from)
    local data = fh:read("*a")
    fh:close()

    if not data or data == "" then
        return
    end

    local entries = {}
    local skip_first = read_from > 0
    for line in data:gmatch("[^\n]+") do
        if skip_first then
            skip_first = false
        else
            local ok_dec, entry = pcall(cjson.decode, line)
            if ok_dec and type(entry) == "table" then
                table.insert(entries, entry)
            end
        end
    end

    local start_idx = math.max(1, #entries - MAX_HISTORY + 1)
    for i = #entries, start_idx, -1 do
        table.insert(g_hotfix_history, entries[i])
    end

    log.info("Loaded hotfix history", "count", #g_hotfix_history)
end

local function get_root_dir()
    return skynet.getenv("root")
end

local SERVICE_BLACKLIST = {
    [".launcher"] = true,
    [".service_mgr"] = true,
    [".gm"] = true,
    [".hotfix"] = true,
    [".logger"] = true,
}

local function find_service_address(service_name)
    local addr = skynet.localname(service_name)
    if addr then
        return { addr }
    end

    if service_name:sub(1, 1) == "." then
        addr = skynet.localname(service_name:sub(2))
        if addr then
            return { addr }
        end
    end

    return nil
end

local function find_service_addresses(service_name)
    if not service_name:find("%*") then
        return find_service_address(service_name)
    end

    if service_name:sub(-1) ~= "*" or service_name:find("%*.*%*") then
        return nil, "Wildcard (*) only allowed at end of service name"
    end

    local prefix = service_name:sub(1, -2)
    local escaped = prefix:gsub("([%(%)%.%%%+%-%?%[%]%^%$])", "%%%1")
    local pattern = "^" .. escaped

    local ok, service_list = pcall(skynet.call, ".launcher", "lua", "LIST")
    if not ok then
        return nil, "Failed to query .launcher LIST: " .. tostring(service_list)
    end

    local addrs = {}
    local seen = {}
    for sname, saddr in pairs(service_list) do
        if sname:match(pattern) and not SERVICE_BLACKLIST[sname] and not seen[saddr] then
            seen[saddr] = true
            table.insert(addrs, saddr)
        end
    end

    if #addrs == 0 then
        return nil
    end

    return addrs
end

local function load_hotfix_config(hotfix_dir)
    local root_dir = get_root_dir()
    local config_path = util_path.join(root_dir, hotfix_dir, "hotfix.conf.lua")

    log.info("Loading hotfix config", "path", config_path)

    local content, err = util_io.readfile(config_path)
    if not content then
        return false, string.format("Failed to read config file: %s", err or "unknown error")
    end

    local config_env = {}
    local func, load_err = load(content, "@" .. config_path, "t", config_env)
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
    local ok, err = hotfix_checksum.verify(config, hotfix_dir, root_dir)
    if ok then
        log.info("Checksum verified successfully")
    end
    return ok, err
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

local function shallow_copy(t)
    local c = {}
    for k, v in pairs(t) do c[k] = v end
    return c
end

local SANDBOX_WHITELIST = {
    type = type,
    tostring = tostring,
    tonumber = tonumber,
    pairs = pairs,
    ipairs = ipairs,
    select = select,
    unpack = unpack or table.unpack,
    table = shallow_copy(table),
    string = shallow_copy(string),
    math = shallow_copy(math),
}

local function make_patcher_sandbox()
    return setmetatable({}, {
        __index = function(_, k)
            local v = SANDBOX_WHITELIST[k]
            if v ~= nil then
                return v
            end
            error("patcher top-level cannot access global: " .. tostring(k), 2)
        end,
    })
end

local function parse_patcher_targets(code_file_path)
    log.info("Parsing patcher", "path", code_file_path)

    local hotfix_code, err = util_io.readfile(code_file_path)
    if not hotfix_code then
        return false, string.format("Failed to read patcher file: %s", err or "unknown error")
    end

    local sandbox_env = make_patcher_sandbox()
    local func, load_err = load(hotfix_code, "@" .. code_file_path, "t", sandbox_env)
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
local hotfix_code = %q

local f, err = load(hotfix_code, "@hotfix")
if not f then
    error("hotfix load error: " .. tostring(err))
end

local r, patcher = xpcall(f, debug.traceback)
if not r then
    error("hotfix chunk error: " .. tostring(patcher))
end

if type(patcher) ~= "table" then
    error("hotfix patcher must be a table, got " .. type(patcher))
end
if type(patcher.run) ~= "function" then
    error("hotfix patcher.run must be a function, got " .. type(patcher.run))
end
if type(patcher.targets) ~= "table" then
    error("hotfix patcher.targets must be a table, got " .. type(patcher.targets))
end

local ok, result = pcall(patcher.run)
if ok then
    return result
else
    error("hotfix patcher.run failed: " .. tostring(result))
end
]]

local INJECT_TIMEOUT = tonumber(skynet.getenv("hotfix_inject_timeout")) or 30

local function call_with_timeout(addr, protocol, cmd, timeout_sec, ...)
    local co = coroutine.running()
    local done = false
    local call_ok, call_result

    local args = table.pack(...)
    skynet.fork(function()
        call_ok, call_result = pcall(skynet.call, addr, protocol, cmd, table.unpack(args, 1, args.n))
        done = true
        skynet.wakeup(co)
    end)

    local deadline = skynet.now() + timeout_sec * 100
    while not done do
        local remaining = deadline - skynet.now()
        if remaining <= 0 then
            log.warn("call_with_timeout expired", "addr", addr, "cmd", cmd, "timeout", timeout_sec)
            skynet.fork(function()
                while not done do
                    skynet.sleep(100)
                end
                log.warn("late call result after timeout", "addr", addr, "cmd", cmd, "ok", call_ok)
            end)
            return false, string.format("inject timeout after %ds", timeout_sec)
        end
        skynet.sleep(math.min(remaining, 100))
    end

    return call_ok, call_result
end

local function inject_to_service(service_addr, hotfix_code, filename)
    log.info("Injecting code to service", "filename", filename)

    local inject_source = string.format(g_hotfix_code_template, hotfix_code)

    local ok, result = call_with_timeout(service_addr, "debug", "RUN", INJECT_TIMEOUT, inject_source, filename)
    if not ok then
        return false, string.format("Failed to inject code: %s", result)
    end

    return true, result
end

local function inject_code_files(code_files, hotfix_dir, fail_fast)
    log.info("Injecting code files", "count", #code_files, "fail_fast", fail_fast)

    local root_dir = get_root_dir()
    local results = {}
    local aborted = false

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
            if fail_fast then
                aborted = true
                break
            end
            goto continue
        end

        for _, service_name in ipairs(patcher_info.targets) do
            local addrs, find_err = find_service_addresses(service_name)
            if not addrs then
                table.insert(results, {
                    file = filename,
                    service = service_name,
                    success = false,
                    error = find_err or "Service not found",
                })
                log.warn("Service not found", "service", service_name, "error", find_err)
                if fail_fast then
                    aborted = true
                    break
                end
                goto continue_service
            end

            for _, service_addr in ipairs(addrs) do
                local inject_ok, inject_result = inject_to_service(service_addr, patcher_info.hotfix_code, filename)
                local addr_str = string.format("%s(%08x)", service_name, service_addr)

                if not inject_ok then
                    table.insert(results, {
                        file = filename,
                        service = addr_str,
                        success = false,
                        error = inject_result,
                    })
                    log.warn("Failed to inject code", "file", filename, "service", addr_str, "error", inject_result)
                    if fail_fast then
                        aborted = true
                        break
                    end
                else
                    table.insert(results, {
                        file = filename,
                        service = addr_str,
                        success = true,
                        result = inject_result,
                    })
                    log.info("Code injected successfully", "file", filename, "service", addr_str)
                end
            end

            if aborted then
                break
            end

            ::continue_service::
        end

        if aborted then
            break
        end

        ::continue::
    end

    local all_ok = true
    for _, r in ipairs(results) do
        if not r.success then
            all_ok = false
            break
        end
    end

    return all_ok, results
end

local function execute_hotfix(hotfix_dir)
    if g_hotfix_lock then
        local elapsed = os.time() - g_hotfix_lock
        if elapsed < LOCK_MAX_HOLD then
            return false, string.format("Another hotfix is in progress (locked %ds ago)", elapsed)
        end
        log.warn("Force release stale hotfix lock", "held_seconds", elapsed)
    end

    g_hotfix_lock = os.time()

    local start_time = os.time()
    local steps = {}
    local root_dir = get_root_dir()

    local version_warning

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
        g_hotfix_lock = nil
    end

    local ok, err = pcall(function()
        log.info("Starting hotfix", "dir", hotfix_dir)
        local load_ok, config = load_hotfix_config(hotfix_dir)
        if not load_ok then
            record_step("load_config", false, config)
            return
        end
        record_step("load_config", true, "Config loaded")

        local fail_fast = config.fail_fast ~= false

        local build_version = skynet.getenv("build_version")
        if build_version and build_version ~= "" and build_version ~= config.gitsha_base then
            log.warn("Build version mismatch", "build_version", build_version, "gitsha_base", config.gitsha_base)
            version_warning = string.format(
                "当前部署版本(%s)与热更基线(%s)不一致，请人工确认补丁适用性",
                build_version, config.gitsha_base
            )
        end

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
            if not clear_ok and fail_fast then return end
        end

        if config.reload_res then
            local res_ok, res_err = reload_res()
            record_step("reload_res", res_ok, res_ok and "Res reloaded" or res_err)
            if not res_ok and fail_fast then return end
        end

        if config.reload_sproto then
            local sproto_ok, sproto_err = reload_sproto()
            record_step("reload_sproto", sproto_ok, sproto_ok and "Sproto reloaded" or sproto_err)
            if not sproto_ok and fail_fast then return end
        end

        if config.reload_orm_schema then
            local schema_ok, schema_err = reload_orm_schema()
            record_step("reload_orm_schema", schema_ok, schema_ok and "ORM schema reloaded" or schema_err)
            if not schema_ok and fail_fast then return end
        end

        if config.code_files and #config.code_files > 0 then
            local inject_ok, inject_results = inject_code_files(config.code_files, hotfix_dir, fail_fast)
            record_step("inject_code", inject_ok, inject_results)
        end
    end)

    cleanup()

    if not ok then
        log.warn("Hotfix execution error", "error", err)
        record_step("internal_error", false, tostring(err))
    end

    local all_success = true
    for _, step in ipairs(steps) do
        if not step.success then
            all_success = false
            break
        end
    end

    local history_entry = {
        time = os.date("%Y-%m-%d %H:%M:%S", start_time),
        node = skynet.getenv("nodename") or "unknown",
        hotfix_dir = hotfix_dir,
        steps = steps,
        success = all_success,
    }

    table.insert(g_hotfix_history, 1, history_entry)
    while #g_hotfix_history > MAX_HISTORY do
        table.remove(g_hotfix_history)
    end

    persist_history(history_entry)

    local guidance
    if not all_success then
        for _, step in ipairs(steps) do
            if not step.success then
                guidance = STEP_GUIDANCE[step.name]
                break
            end
        end
    end

    log.info("Hotfix completed", "success", all_success, "dir", hotfix_dir)

    return all_success,
        {
            steps = steps,
            guidance = guidance,
            version_warning = version_warning,
            message = all_success and "Hotfix completed successfully" or "Hotfix completed with errors",
        }
end

local function dry_run_hotfix(hotfix_dir)
    local root_dir = get_root_dir()

    local load_ok, config = load_hotfix_config(hotfix_dir)
    if not load_ok then
        return false, { step = "load_config", error = config }
    end

    local verify_ok, verify_err = verify_checksum(config, hotfix_dir, root_dir)
    if not verify_ok then
        return false, { step = "verify_checksum", error = verify_err }
    end

    local plan = {
        desc = config.desc,
        gitsha_base = config.gitsha_base,
        gitsha_update = config.gitsha_update,
        steps = {},
        patchers = {},
        warnings = {},
    }

    if config.clearcache then
        table.insert(plan.steps, "clear_cache")
    end
    if config.reload_res then
        table.insert(plan.steps, "reload_res")
    end
    if config.reload_sproto then
        table.insert(plan.steps, "reload_sproto")
    end
    if config.reload_orm_schema then
        table.insert(plan.steps, "reload_orm_schema")
    end

    if config.code_files then
        for _, filename in ipairs(config.code_files) do
            local code_file_path = util_path.join(root_dir, hotfix_dir, filename)
            local ok, patcher_info = parse_patcher_targets(code_file_path)
            if not ok then
                table.insert(plan.patchers, {
                    file = filename,
                    error = patcher_info,
                })
            else
                local target_details = {}
                for _, service_name in ipairs(patcher_info.targets) do
                    local addrs, find_err = find_service_addresses(service_name)
                    if not addrs then
                        table.insert(target_details, {
                            name = service_name,
                            found = false,
                            error = find_err,
                        })
                        table.insert(plan.warnings, string.format("Service not found: %s (patcher %s)", service_name, filename))
                    else
                        for _, a in ipairs(addrs) do
                            table.insert(target_details, {
                                name = service_name,
                                address = string.format("%08x", a),
                                found = true,
                            })
                        end
                    end
                end
                table.insert(plan.patchers, {
                    file = filename,
                    targets = target_details,
                })
            end
        end
    end

    return true, plan
end

GM_CMD.hotfix = {
    desc = "执行热更新",
    params = {
        hotfix_dir = "热更包目录路径（相对于工程根目录，如 hotfix/20260120-patch1）",
        mode = "执行模式：run（默认执行）/ dry_run（仅预演，不实际执行）",
        confirm = "高危操作确认，执行模式下必须传 confirm=true",
    },
    handler = function(params)
        local hotfix_dir = params.hotfix_dir
        if not hotfix_dir then
            return false, "Missing required parameter: hotfix_dir"
        end

        if hotfix_dir:find("%.%.") or hotfix_dir:sub(1, 1) == "/" then
            return false, "Invalid hotfix_dir: must be a relative path without '..'"
        end

        if params.mode == "dry_run" then
            return dry_run_hotfix(hotfix_dir)
        end

        if params.confirm ~= "true" and params.confirm ~= true then
            return false, "高危操作，请传 confirm=true 确认执行"
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
        limit = math.max(1, math.min(limit, #g_hotfix_history))

        local result = {}
        for i = 1, limit do
            table.insert(result, g_hotfix_history[i])
        end

        return true, result
    end,
}

skynet.start(function()
    load_history()
    gm_api.register(GM_CMD)
    cmd_api.dispatch(CMD)
    log.info("Hotfix service started")
end)
