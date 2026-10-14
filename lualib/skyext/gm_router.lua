local skynet = require "skynet"
local log = require "skyext.log"
local errcode = require "skyext.errcode"
local config = require "skyext.config"

local M = {
    GET = {},
    POST = {},
}

local g_gm_service

local function get_gm_service()
    if not g_gm_service then
        g_gm_service = skynet.localname(".gm")
    end
    return g_gm_service
end

-- 路由层只负责把凭证从请求里取出来，认谁、准不准、记不记审计都在 .gm 服务里做：
-- HTTP agent 有多个实例，鉴权和审计分散在每个实例上既难对齐也难查
local function credential(req, params)
    local token
    local auth_header = req.header and req.header["authorization"]
    if auth_header then
        token = auth_header:match("^Bearer%s+(.+)$")
    end
    if not token then
        token = params and params.token
    end
    return { token = token, peer = req.addr or "unknown" }
end

-- 把请求转给 .gm 服务，应答原样回给调用方
local function forward(res, cmd, ...)
    local gm_service = get_gm_service()
    if not gm_service then
        log.error("GM service not found")
        return res.write_json({
            code = 1,
            error = "GM service not available",
        })
    end

    local ok, result = pcall(skynet.call, gm_service, "lua", cmd, ...)
    if not ok then
        log.error("GM call failed", "cmd", cmd, "error", result)
        return res.write_json({
            code = 1,
            error = tostring(result),
        })
    end
    return res.write_json(result)
end

-- GET /gm/execute - 执行 GM 指令
M.GET["/gm/execute"] = function(req, res)
    local q = req.parse_query()
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

    return forward(res, "execute_command", credential(req, q), cmd, params, services)
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

    return forward(res, "execute_command", credential(req, body), cmd, params, services)
end

-- GET /gm/list - 列出所有已注册的 GM 指令
M.GET["/gm/list"] = function(req, res)
    return forward(res, "list_commands", credential(req, req.parse_query()))
end

-- GET / - index.html
M.GET["/"] = function(req, res)
    local skyext_root = config.get("skyext_root") or "./"
    return res.write_file(skyext_root .. "public/gm.html")
end

return M
