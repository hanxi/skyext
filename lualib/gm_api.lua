local skynet = require "skynet"
local log = require "log"

local M = {}

local g_gm_service -- 缓存 GM 服务地址

-- 获取 GM 服务地址（懒加载）
local function ensure_gm_service()
    if not g_gm_service then
        g_gm_service = skynet.uniqueservice("gm")
        log.info("GM service started", "address", g_gm_service)
    end
    return g_gm_service
end

-- 注册 GM 指令
-- @param cmd_name 指令名称
-- @param handler 处理器名称（CMD 函数名）
-- @param description 指令描述
-- @param params 参数定义，格式：{ param_name = "参数描述", ... }，可选
function M.register(cmd_name, handler, description, params)
    params = params or {}

    local gm_service = ensure_gm_service()
    local service_address = skynet.self()

    local ok, ret = pcall(
        skynet.call,
        gm_service,
        "lua",
        "register_command",
        cmd_name,
        service_address,
        handler,
        description,
        params
    )

    if not ok then
        log.error("GM register failed", "cmd", cmd_name, "handler", handler, "error", ret)
        return false
    end

    log.info("GM command registered", "cmd", cmd_name, "handler", handler, "service", service_address)
    return true
end

-- 注销 GM 指令
-- @param cmd_name 指令名称
function M.unregister(cmd_name)
    if not g_gm_service then
        log.warn("GM service not initialized, skip unregister", "cmd", cmd_name)
        return false
    end

    local service_address = skynet.self()

    local ok, ret = pcall(skynet.call, g_gm_service, "lua", "unregister_command", cmd_name, service_address)

    if not ok then
        log.error("GM unregister failed", "cmd", cmd_name, "error", ret)
        return false
    end

    log.info("GM command unregistered", "cmd", cmd_name, "service", service_address)
    return true
end

-- 批量注销当前服务的所有 GM 指令
-- 通常在服务退出时调用
function M.unregister_all()
    if not g_gm_service then
        log.warn("GM service not initialized, skip unregister_all")
        return false
    end

    local service_address = skynet.self()

    local ok, ret = pcall(skynet.call, g_gm_service, "lua", "unregister_service", service_address)

    if not ok then
        log.error("GM unregister_all failed", "error", ret)
        return false
    end

    log.info("GM all commands unregistered", "service", service_address)
    return true
end

return M
