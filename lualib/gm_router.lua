local skynet = require "skynet"
local log = require "log"
local errcode = require "errcode"

local M = {
    GET = {},
    POST = {},
}

local g_gm_service -- 缓存 GM 服务地址

-- 获取 GM 服务地址
local function get_gm_service()
    if not g_gm_service then
        g_gm_service = skynet.localname(".gm")
    end
    return g_gm_service
end

-- GET /gm/execute - 执行 GM 指令
M.GET["/gm/execute"] = function(req, res)
    local q = req.parse_query()
    local cmd = q.cmd

    if not cmd or cmd == "" then
        return res.write_json({
            code = errcode.PARAM_ERROR or 1,
            error = "missing cmd parameter",
        })
    end

    -- 提取 services 参数（逗号分隔的服务地址列表）
    local services = nil
    if q.services and q.services ~= "" then
        services = {}
        for service_str in string.gmatch(q.services, "[^,]+") do
            table.insert(services, service_str)
        end
    end

    -- 移除 cmd 和 services 参数，剩余的作为指令参数
    local params = {}
    for k, v in pairs(q) do
        if k ~= "cmd" and k ~= "services" then
            params[k] = v
        end
    end

    local gm_service = get_gm_service()
    if not gm_service then
        log.error("GM service not found")
        return res.write_json({
            code = 1,
            error = "GM service not available",
        })
    end

    local ok, result = pcall(skynet.call, gm_service, "lua", "execute_command", cmd, params, services)
    if not ok then
        log.error("GM execute failed", "cmd", cmd, "error", result)
        return res.write_json({
            code = 1,
            error = tostring(result),
        })
    end

    return res.write_json(result)
end

-- POST /gm/execute - 执行 GM 指令
M.POST["/gm/execute"] = function(req, res)
    local body = req.read_json()
    if not body then
        return res.write_json({
            code = errcode.PARAM_ERROR or 1,
            error = "invalid json body",
        })
    end

    local cmd = body.cmd
    if not cmd or cmd == "" then
        return res.write_json({
            code = errcode.PARAM_ERROR or 1,
            error = "missing cmd parameter",
        })
    end

    -- 提取 services 参数（数组格式）
    local services = body.services

    -- 移除 cmd 和 services 参数，剩余的作为指令参数
    local params = {}
    for k, v in pairs(body) do
        if k ~= "cmd" and k ~= "services" then
            params[k] = v
        end
    end

    local gm_service = get_gm_service()
    if not gm_service then
        log.error("GM service not found")
        return res.write_json({
            code = 1,
            error = "GM service not available",
        })
    end

    local ok, result = pcall(skynet.call, gm_service, "lua", "execute_command", cmd, params, services)
    if not ok then
        log.error("GM execute failed", "cmd", cmd, "error", result)
        return res.write_json({
            code = 1,
            error = tostring(result),
        })
    end

    return res.write_json(result)
end

-- GET /gm/list - 列出所有已注册的 GM 指令
M.GET["/gm/list"] = function(req, res)
    local gm_service = get_gm_service()
    if not gm_service then
        log.error("GM service not found")
        return res.write_json({
            code = 1,
            error = "GM service not available",
        })
    end

    local ok, commands = pcall(skynet.call, gm_service, "lua", "list_commands")
    if not ok then
        log.error("GM list_commands failed", "error", commands)
        return res.write_json({
            code = 1,
            error = tostring(commands),
        })
    end

    return res.write_json({
        code = 0,
        commands = commands,
    })
end

return M
