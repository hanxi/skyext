local skynet = require "skynet"

local M = {}

-- 注册 GM 命令
local function register_gm_commands(CMD, GM_CMD)
    if not GM_CMD then
        return
    end

    local gm_api = require "gm_api"
    for cmd_name, cmd_def in pairs(GM_CMD) do
        -- description 必须定义
        local description = cmd_def.description
        if not description then
            error(string.format("GM command '%s' must have a description", cmd_name))
        end

        -- handler 必须定义
        local handler = cmd_def.handler
        if not handler then
            error(string.format("GM command '%s' must have a handler", cmd_name))
        end

        -- params 可选，默认为空表
        local params = cmd_def.params or {}

        -- GM 命令的处理函数名
        local gm_handler_name = "gm_" .. cmd_name

        -- 将 handler 函数注册到 CMD 表中
        CMD[gm_handler_name] = handler

        -- 注册到 GM 服务
        gm_api.register(cmd_name, gm_handler_name, description, params)
    end
end

function M.dispatch(CMD, GM_CMD)
    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if not f then
            error(string.format("Unknown command: %s", cmd))
        end
        skynet.ret(skynet.pack(f(...)))
    end)
    register_gm_commands(CMD, GM_CMD)
end

function M.dispatch_socket(CMD, SOCKET, GM_CMD)
    skynet.dispatch("lua", function(_, _, cmd, subcmd, ...)
        if cmd == "socket" then
            local f = SOCKET[subcmd]
            f(...)
            -- socket api don't need return
        else
            local f = CMD[cmd]
            if not f then
                error("Unknown command:", cmd)
            end
            skynet.ret(skynet.pack(f(subcmd, ...)))
        end
    end)
    register_gm_commands(CMD, GM_CMD)
end

return M
