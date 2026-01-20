local skynet = require "skynet"
local log = require "log"

local M = {}

local g_gm_service -- 缓存 GM 服务地址

-- 获取 GM 服务地址
local function get_gm_service()
    if not g_gm_service then
        g_gm_service = skynet.localname(".gm")
    end
    return g_gm_service
end

-- 批量注销当前服务的所有 GM 指令
-- TODO: 在服务退出时调用
function M.unregister()
    if not g_gm_service then
        log.warn("GM service not initialized, skip unregister")
        return false
    end

    local service_address = skynet.self()

    local ok, ret = pcall(skynet.call, g_gm_service, "lua", "unregister_service", service_address)

    if not ok then
        log.error("GM unregister failed", "error", ret)
        return false
    end

    log.info("GM all commands unregistered", "service", service_address)
    return true
end

-- 注册 GM 指令
-- @param GM_CMD GM 指令表
-- @usage GM_CMD = {
--     cmd_name = {
--         desc = "指令描述",
--         handler = "处理器名称",
--         params = { param_name = "参数描述", ... },
--     },
--     ...
-- }
function M.register(GM_CMD)
    local CMD = {}
    local commands = {} -- 收集所有指令

    for cmd_name, cmd_def in pairs(GM_CMD) do
        -- desc 必须定义
        local desc = cmd_def.desc
        if not desc then
            error(string.format("GM command '%s' must have a desc", cmd_name))
        end

        -- handler 必须定义
        local handler = cmd_def.handler
        if not handler then
            error(string.format("GM command '%s' must have a handler", cmd_name))
        end

        -- params 可选，默认为空表
        local params = cmd_def.params or {}

        -- GM 命令的处理函数名
        local handler_name = "GM_" .. string.upper(cmd_name)

        -- 将 handler 函数注册到 CMD 表中
        CMD[handler_name] = handler

        -- 收集指令信息
        table.insert(commands, {
            cmd_name = cmd_name,
            handler_name = handler_name,
            desc = desc,
            params = params,
        })
    end

    -- 批量注册到 GM 服务
    local gm_service = get_gm_service()
    if not gm_service then
        log.warn("GM service not initialized, skip register")
        return false
    end
    local service_address = skynet.self()

    local ok, result = pcall(
        skynet.call,
        gm_service,
        "lua",
        "register_commands", -- 使用批量接口
        service_address,
        commands
    )

    if not ok then
        log.error("GM batch register failed", "error", result)
        return false
    end

    if result.failed_commands and #result.failed_commands > 0 then
        log.warn("GM some commands register failed", "failed", result.failed_commands)
    end

    log.info("GM batch register success", "service", service_address, "count", result.success_count)

    local cmd_api = require "cmd_api"
    cmd_api.register(CMD)

    return true
end

-- 执行 GM 指令
-- @param cmd_name 指令名称
-- @param params 指令参数（表）
-- @param target_services 可选，目标服务列表
-- @return 执行结果
function M.execute_command(cmd_name, params, target_services)
    local gm_service = get_gm_service()
    if not gm_service then
        log.error("GM service not initialized")
        return {
            code = 1,
            error = "GM service not found",
        }
    end

    local ok, result = pcall(skynet.call, gm_service, "lua", "execute_command", cmd_name, params, target_services)
    if not ok then
        log.error("GM execute_command failed", "cmd", cmd_name, "error", result)
        return {
            code = 1,
            error = string.format("Failed to call execute_command: %s", result),
        }
    end

    return result
end

return M
