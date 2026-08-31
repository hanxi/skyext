local skynet = require "skynet"
local log = require "log"
local errcode = require "errcode"

local M = {
    GET = {},
    POST = {},
}

local g_gm_service
local g_gm_auth_token

local function get_gm_service()
    if not g_gm_service then
        g_gm_service = skynet.localname(".gm")
    end
    return g_gm_service
end

local PLACEHOLDER_TOKENS = {
    ["CHANGE_ME_TO_RANDOM_TOKEN"] = true,
}

local function get_auth_token()
    if g_gm_auth_token == nil then
        local token = skynet.getenv("gm_auth_token")
        if token and token ~= "" and not PLACEHOLDER_TOKENS[token] then
            g_gm_auth_token = token
        else
            if token and PLACEHOLDER_TOKENS[token] then
                log.error("gm_auth_token is still the default placeholder! /gm/execute is disabled.")
            end
            g_gm_auth_token = false
        end
    end
    return g_gm_auth_token
end

local function check_auth(req, params)
    local expected = get_auth_token()
    if not expected then
        return false, "GM auth token not configured, /gm/execute is disabled"
    end

    local token
    local auth_header = req.header and req.header["authorization"]
    if auth_header then
        token = auth_header:match("^Bearer%s+(.+)$")
    end

    if not token then
        token = params and params.token
    end

    if not token or token ~= expected then
        local peer = req.addr or "unknown"
        log.warn("GM auth failed", "peer", peer)
        return false, "Authentication failed"
    end

    return true
end

-- GET /gm/execute - 执行 GM 指令
M.GET["/gm/execute"] = function(req, res)
    local q = req.parse_query()

    local auth_ok, auth_err = check_auth(req, q)
    if not auth_ok then
        return res.write_json({
            code = errcode.AUTH_FAILED,
            error = auth_err,
        })
    end

    local cmd = q.cmd

    if not cmd or cmd == "" then
        return res.write_json({
            code = errcode.PARAM_ERROR,
            error = "missing cmd parameter",
        })
    end

    local services = nil
    if q.services and q.services ~= "" then
        services = {}
        for service_str in string.gmatch(q.services, "[^,]+") do
            table.insert(services, service_str)
        end
    end

    local params = {}
    for k, v in pairs(q) do
        if k ~= "cmd" and k ~= "services" and k ~= "token" then
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
            code = errcode.PARAM_ERROR,
            error = "invalid json body",
        })
    end

    local auth_ok, auth_err = check_auth(req, body)
    if not auth_ok then
        return res.write_json({
            code = errcode.AUTH_FAILED,
            error = auth_err,
        })
    end

    local cmd = body.cmd
    if not cmd or cmd == "" then
        return res.write_json({
            code = errcode.PARAM_ERROR,
            error = "missing cmd parameter",
        })
    end

    local services = body.services

    local params = {}
    for k, v in pairs(body) do
        if k ~= "cmd" and k ~= "services" and k ~= "token" then
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
    local q = req.parse_query()
    local auth_ok, auth_err = check_auth(req, q)
    if not auth_ok then
        return res.write_json({
            code = errcode.AUTH_FAILED,
            error = auth_err,
        })
    end

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

-- GET / - index.html
M.GET["/"] = function(req, res)
    return res.write_file("public/gm.html")
end

return M
