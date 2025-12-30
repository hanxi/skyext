local skynet = require "skynet"
local http_server = require "http_server"
local cmd_api = require "cmd_api"
local config = require "config"
local log = require "log"

local CMD = {}
local g_commands = {} -- 指令注册表：cmd_name -> { handler, desc, params, services }
local g_service_commands = {} -- 反向索引：service_address -> { cmd_name1, cmd_name2, ... }

-- 注册 GM 指令
function CMD.register_command(cmd_name, service_address, handler_name, description, params)
    params = params or {}

    local cmd_info = g_commands[cmd_name]
    if not cmd_info then
        -- 新指令，创建记录
        g_commands[cmd_name] = {
            handler = handler_name,
            desc = description,
            params = params,
            services = {
                [service_address] = true,
            },
        }
        log.info("GM command registered", "cmd", cmd_name, "handler", handler_name, "service", service_address)
    else
        -- 已存在的指令，检查一致性
        local need_update = false
        if cmd_info.handler ~= handler_name then
            log.warn(
                "GM command handler updated",
                "cmd",
                cmd_name,
                "old_handler",
                cmd_info.handler,
                "new_handler",
                handler_name
            )
            cmd_info.handler = handler_name
            need_update = true
        end

        if cmd_info.desc ~= description then
            log.warn("GM command desc updated", "cmd", cmd_name, "old_desc", cmd_info.desc, "new_desc", description)
            cmd_info.desc = description
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

-- 注销 GM 指令
function CMD.unregister_command(cmd_name, service_address)
    local cmd_info = g_commands[cmd_name]
    if not cmd_info then
        log.warn("GM command not found for unregister", "cmd", cmd_name, "service", service_address)
        return false
    end

    cmd_info.services[service_address] = nil
    log.info("GM command service removed", "cmd", cmd_name, "service", service_address)

    -- 如果没有服务注册了，删除该指令
    if next(cmd_info.services) == nil then
        g_commands[cmd_name] = nil
        log.info("GM command removed (no services)", "cmd", cmd_name)
    end

    -- 更新反向索引
    if g_service_commands[service_address] then
        g_service_commands[service_address][cmd_name] = nil
        -- 如果该服务没有注册任何指令了，删除反向索引
        if next(g_service_commands[service_address]) == nil then
            g_service_commands[service_address] = nil
        end
    end

    return true
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

-- 列出所有已注册指令
function CMD.list_commands()
    local result = {}
    for cmd_name, cmd_info in pairs(g_commands) do
        local service_count = 0
        for _ in pairs(cmd_info.services) do
            service_count = service_count + 1
        end

        table.insert(result, {
            cmd = cmd_name,
            desc = cmd_info.desc,
            handler = cmd_info.handler,
            params = cmd_info.params,
            service_count = service_count,
        })
    end
    return result
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
            -- 本地命名服务，如 ".gm"
            local addr = skynet.localname(service:sub(2))
            return addr
        else
            -- 尝试作为服务名字查找
            local addr = skynet.localname(service)
            return addr
        end
    end

    return nil
end

-- 执行 GM 指令
-- @param cmd_name 指令名称
-- @param params 指令参数
-- @param target_services 可选，指定要执行的服务列表，每个元素可以是：
--   - 整数：服务地址
--   - 字符串：服务名字（如 ".gm" 或 "gm"）或十六进制地址（如 ":01000002"）
function CMD.execute_command(cmd_name, params, target_services)
    local cmd_info = g_commands[cmd_name]
    if not cmd_info then
        return {
            code = 1,
            error = "command not found",
            cmd = cmd_name,
        }
    end

    local results = {}
    local handler = cmd_info.handler

    -- 如果指定了 target_services，则只在这些服务上执行
    local services_to_execute = {}
    if target_services and type(target_services) == "table" and #target_services > 0 then
        -- 将服务标识转换为服务地址
        for _, service in ipairs(target_services) do
            local service_address = parse_service_address(service)
            if not service_address then
                log.warn("GM command invalid service", "cmd", cmd_name, "service", service)
                table.insert(results, {
                    service = tostring(service),
                    success = false,
                    error = "invalid service address or name",
                })
            elseif cmd_info.services[service_address] then
                services_to_execute[service_address] = true
            else
                log.warn("GM command service not registered", "cmd", cmd_name, "service", service)
                table.insert(results, {
                    service = tostring(service),
                    success = false,
                    error = "service not registered for this command",
                })
            end
        end
    else
        -- 否则在所有注册的服务上执行
        services_to_execute = cmd_info.services
    end

    -- 遍历要执行的服务，执行指令
    for service_address, _ in pairs(services_to_execute) do
        local ok, ret = pcall(skynet.call, service_address, "lua", handler, params)
        if ok then
            table.insert(results, {
                service = skynet.address(service_address),
                success = true,
                data = ret,
            })
        else
            log.error("GM command execute failed", "cmd", cmd_name, "service", service_address, "error", ret)
            table.insert(results, {
                service = skynet.address(service_address),
                success = false,
                error = tostring(ret),
            })
        end
    end

    return {
        code = 0,
        cmd = cmd_name,
        results = results,
    }
end

skynet.start(function()
    log.info("GM service starting")

    -- 启动 HTTP 服务器
    local port = config.get_number("gm_http_port") or 9090
    local agent_count = config.get_number("gm_agent_count") or 2
    local conf = {
        port = port,
        agent_count = agent_count,
    }
    http_server.start(conf)
    http_server.register_router("gm_router")

    log.info("GM HTTP server started", "port", port, "agent_count", agent_count)

    -- 注册 CMD 消息处理
    cmd_api.dispatch(CMD)
    skynet.register(".gm")

    log.info("GM service started")
end)
