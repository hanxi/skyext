local skynet = require "skynet"
local http_server = require "skyext.http_server"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local errcode = require "skyext.errcode"
local secret = require "skyext.secret"
local log = require "skyext.log"

local g_commands = {} -- 指令注册表：cmd_name -> { handler_name, desc, params, services }
local g_service_commands = {} -- 反向索引：service_address -> { cmd_name1, cmd_name2, ... }

local CMD = {}
-- 注册 GM 指令
local function register_command(service_address, cmd_name, handler_name, desc, params)
    params = params or {}

    local cmd_info = g_commands[cmd_name]
    if not cmd_info then
        -- 新指令，创建记录
        g_commands[cmd_name] = {
            handler_name = handler_name,
            desc = desc,
            params = params,
            services = {
                [service_address] = true,
            },
        }
        log.info("GM command registered", "cmd", cmd_name, "handler_name", handler_name, "service", service_address)
    else
        -- 已存在的指令，检查一致性
        local need_update = false
        if cmd_info.handler_name ~= handler_name then
            log.warn(
                "GM command handler_name updated",
                "cmd",
                cmd_name,
                "old_handler",
                cmd_info.handler_name,
                "new_handler",
                handler_name
            )
            cmd_info.handler_name = handler_name
            need_update = true
        end

        if cmd_info.desc ~= desc then
            log.warn("GM command desc updated", "cmd", cmd_name, "old_desc", cmd_info.desc, "new_desc", desc)
            cmd_info.desc = desc
            need_update = true
        end

        -- 简单比较 params 是否一致
        local params_changed = false
        for k, v in pairs(params) do
            if cmd_info.params[k] ~= v then
                params_changed = true
                break
            end
        end
        if not params_changed then
            for k, v in pairs(cmd_info.params) do
                if params[k] ~= v then
                    params_changed = true
                    break
                end
            end
        end

        if params_changed then
            log.warn("GM command params updated", "cmd", cmd_name, "old_params", cmd_info.params, "new_params", params)
            cmd_info.params = params
            need_update = true
        end

        -- 添加服务地址
        if not cmd_info.services[service_address] then
            cmd_info.services[service_address] = true
            log.info("GM command service added", "cmd", cmd_name, "service", service_address)
        end

        if need_update then
            log.info("GM command updated", "cmd", cmd_name)
        end
    end

    -- 更新反向索引
    if not g_service_commands[service_address] then
        g_service_commands[service_address] = {}
    end
    if not g_service_commands[service_address][cmd_name] then
        g_service_commands[service_address][cmd_name] = true
    end

    return true
end

-- 批量注册 GM 指令
-- @param service_address 服务地址
-- @param commands 指令列表，格式：{
--   { cmd_name = "指令名", handler_name = "处理函数名", desc = "描述", params = {} },
--   ...
-- }
function CMD.register_commands(service_address, commands)
    local success_count = 0
    local failed_commands = {}

    for _, cmd in ipairs(commands) do
        local ok, err = pcall(register_command, service_address, cmd.cmd_name, cmd.handler_name, cmd.desc, cmd.params)
        if ok then
            success_count = success_count + 1
        else
            table.insert(failed_commands, {
                cmd = cmd.cmd_name,
                error = tostring(err),
            })
        end
    end

    log.info(
        "GM batch register completed",
        "service",
        service_address,
        "success",
        success_count,
        "failed",
        #failed_commands
    )

    return {
        success_count = success_count,
        failed_commands = failed_commands,
    }
end

-- 批量注销服务的所有 GM 指令
function CMD.unregister_service(service_address)
    local service_cmds = g_service_commands[service_address]
    if not service_cmds then
        log.info("GM service has no commands to unregister", "service", service_address)
        return true
    end

    local unregistered_count = 0
    -- 遍历该服务注册的所有指令
    for cmd_name, _ in pairs(service_cmds) do
        local cmd_info = g_commands[cmd_name]
        if cmd_info then
            cmd_info.services[service_address] = nil
            unregistered_count = unregistered_count + 1

            -- 如果没有服务注册了，删除该指令
            if next(cmd_info.services) == nil then
                g_commands[cmd_name] = nil
                log.info("GM command removed (no services)", "cmd", cmd_name)
            end
        end
    end

    -- 删除反向索引
    g_service_commands[service_address] = nil

    log.info("GM service unregistered all commands", "service", service_address, "count", unregistered_count)
    return true
end

-- GM 口是管理员接口：谁能用、能用哪条，交给对接它的后台去管，这里只认一个 token。
-- 不走 allow_insecure_secret —— 登录密钥弱了是本地开发的事，GM 弱了是整个进程的事。
local g_token -- nil 还没读，false 读过但不可用

local function gm_token()
    if g_token == nil then
        local value = config.get("gm_auth_token")
        local ok, reason = secret.check(value)
        if not ok then
            log.error("GM token is unusable, GM interface is disabled", "reason", reason)
        end
        g_token = ok and value or false
    end
    return g_token
end

-- 定长比较：逐字节比完再判等，不让对方从"第几个字节开始不一样"里试出 token
local function secure_equal(a, b)
    if #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = diff | (string.byte(a, i) ~ string.byte(b, i))
    end
    return diff == 0
end

-- 鉴权：cred 为 nil 表示进程内部调用，直接放行。
-- @return peer 或 nil + 可以直接回给调用方的应答
local function authenticate(cred)
    if not cred then
        return "internal"
    end
    local peer = cred.peer or "unknown"
    local token = gm_token()
    local err
    if not token then
        err = "no usable GM token configured"
    elseif type(cred.token) ~= "string" or not secure_equal(token, cred.token) then
        err = "invalid token"
    end
    if err then
        log.warn("GM auth failed", "peer", peer, "error", err)
        return nil, { code = errcode.AUTH_FAILED, error = err }
    end
    return peer
end

function CMD.list_commands(cred)
    local _, denied = authenticate(cred)
    if denied then
        return denied
    end

    local result = {}
    for cmd_name, cmd_info in pairs(g_commands) do
        local service_count = 0
        for _ in pairs(cmd_info.services) do
            service_count = service_count + 1
        end

        table.insert(result, {
            cmd = cmd_name,
            desc = cmd_info.desc,
            params = cmd_info.params,
            service_count = service_count,
        })
    end
    return { code = errcode.OK, commands = result }
end

-- 将服务标识转换为服务地址
-- @param service 服务标识，可以是：
--   - 整数：直接的服务地址
--   - 字符串：服务名字（如 ".gm"）或十六进制地址（如 ":01000002"）
-- @return 服务地址（整数），如果转换失败返回 nil
local function parse_service_address(service)
    local service_type = type(service)

    if service_type == "number" then
        -- 直接是服务地址
        return service
    elseif service_type == "string" then
        if service:sub(1, 1) == ":" then
            -- 十六进制地址字符串，如 ":01000002"
            local addr = tonumber(service:sub(2), 16)
            return addr
        elseif service:sub(1, 1) == "." then
            -- 本地命名服务，如 ".gm"。skynet 的 QUERY 只认带前导点的名字，要原样传
            return skynet.localname(service)
        else
            -- 省略了前导点的本地名，如 "gm"
            return skynet.localname("." .. service)
        end
    end

    return nil
end

-- 执行 GM 指令
-- @param cred 调用方凭证 { token, peer }；nil 表示进程内部调用
-- @param cmd_name 指令名称
-- @param params 指令参数
-- @param target_services 可选，指定要执行的服务列表，每个元素可以是：
--   - 整数：服务地址
--   - 字符串：服务名字（如 ".gm" 或 "gm"）或十六进制地址（如 ":01000002"）
function CMD.execute_command(cred, cmd_name, params, target_services)
    local peer, denied = authenticate(cred)
    if denied then
        return denied
    end

    local cmd_info = g_commands[cmd_name]
    if not cmd_info then
        log.warn("GM command not found", "peer", peer, "cmd", cmd_name)
        return {
            code = 1,
            error = "command not found",
            cmd = cmd_name,
        }
    end

    local results = {}
    local handler_name = cmd_info.handler_name
    local succeeded, failed, first_error = 0, 0, nil

    local function add_failure(service, err)
        failed = failed + 1
        first_error = first_error or err
        table.insert(results, {
            service = service,
            success = false,
            error = err,
        })
    end

    -- 如果指定了 target_services，则只在这些服务上执行
    local services_to_execute = {}
    if target_services and type(target_services) == "table" and #target_services > 0 then
        -- 将服务标识转换为服务地址
        for _, service in ipairs(target_services) do
            local service_address = parse_service_address(service)
            if not service_address then
                log.warn("GM command invalid service", "cmd", cmd_name, "service", service)
                add_failure(tostring(service), "invalid service address or name")
            elseif cmd_info.services[service_address] then
                services_to_execute[service_address] = true
            else
                log.warn("GM command service not registered", "cmd", cmd_name, "service", service)
                add_failure(tostring(service), "service not registered for this command")
            end
        end
    else
        -- 否则在所有注册的服务上执行
        services_to_execute = cmd_info.services
    end

    -- 遍历要执行的服务，执行指令
    for service_address, _ in pairs(services_to_execute) do
        local ok, ret, data = pcall(skynet.call, service_address, "lua", handler_name, params)
        if ok and ret then
            succeeded = succeeded + 1
            table.insert(results, {
                service = skynet.address(service_address),
                success = true,
                data = data,
            })
        else
            log.warn("GM command execute failed", "cmd", cmd_name, "service", service_address, "ret", ret, "data", data)
            add_failure(skynet.address(service_address), tostring(ret or data))
            local result = results[#results]
            if data ~= result.error then
                result.data = data
            end
        end
    end

    -- 记在执行之后：一行就能看出这次操作到底落没落地
    local outcome = "ok"
    if failed > 0 then
        outcome = succeeded > 0 and "partial" or "failed"
    end
    if first_error then
        log.info("GM command executed", "peer", peer, "cmd", cmd_name, "result", outcome, "error", first_error)
    else
        log.info("GM command executed", "peer", peer, "cmd", cmd_name, "result", outcome)
    end

    return {
        code = 0,
        cmd = cmd_name,
        results = results,
    }
end

skynet.start(function()
    log.info("GM service starting")

    -- 启动 GM 专用 HTTP 服务器（独立实例，路由不与业务端口共用）
    -- 默认只监听本机回环地址，需要对外暴露时显式配置 gm_http_host
    local host = config.get("gm_http_host") or "127.0.0.1"
    local port = config.get_number("gm_http_port") or 9090
    local agent_count = config.get_number("gm_agent_count") or 2
    -- 启动时就把 token 读出来：配错了现在就看见，不用等有人来敲一次才报
    gm_token()

    local gm_http = http_server.new("gm")
    gm_http:start({
        host = host,
        port = port,
        agent_count = agent_count,
    })
    gm_http:register_router("skyext.gm_router")
    log.info("GM HTTP server started", "host", host, "port", port, "agent_count", agent_count)

    cmd_api.dispatch(CMD)
    skynet.register(".gm")
    skynet.uniqueservice("gm_sys")
    log.info("GM service started")
end)
