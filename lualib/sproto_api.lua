local skynet = require "skynet"
local socket = require "skynet.socket"
local netpack = require "skynet.netpack"
local event_channel_api = require "event_channel_api"
local config = require "config"
local log = require "log"

local M = {}
local g_sproto_loader_service
local g_schema
local g_sproto_info
local g_host
local g_send_request
local g_sessions = {}
local REQUEST_CMD = {}
local GET_OBJ_CB = {}
local MIDDLEWARE_CBS = {}

local function register_request_func(request_name, func)
    if REQUEST_CMD[request_name] then
        error("Request command " .. request_name .. " already registered")
    end
    REQUEST_CMD[request_name] = func
end

-- mod_name 是协议的文件名
-- module 是连接管理模块
-- 一个连接管理模块需要提供 get_obj 接口用于获取连接对象
-- 同时也可以提供 middleware_cbs 表，用于注册中间件，主要用于做协议拦截
-- obj 就是一个连接对象，由连接管理模块的 get_obj 接口提供
function M.register_module(mod_name, module, cmds)
    for k, v in pairs(cmds or {}) do
        if type(v) == "function" then
            local request_name = mod_name .. "." .. k
            register_request_func(request_name, v)

            GET_OBJ_CB[request_name] = module.get_obj
            MIDDLEWARE_CBS[request_name] = module.middleware_cbs
        end
    end
end

-- request 消息处理接口:
-- 第 1 个参数是协议数据里的 request ,协议处理接口用 : 实现的时候，刚好 self 就是 request
-- 第 2 个参数是 fd
-- 第 3 个参数是 obj 对象
local function dispatch_request(fd, request_name, request, response_cb)
    local f = assert(REQUEST_CMD[request_name])
    request = request or {}
    local get_obj = GET_OBJ_CB[request_name]
    log.debug("dispatch_request", "request_name", request_name, "fd", fd, "get_obj", get_obj, "request", request)
    local obj = nil
    if get_obj then
        obj = get_obj(fd)
    end

    local middleware_cbs = MIDDLEWARE_CBS[request_name]
    for _, cb in ipairs(middleware_cbs or {}) do
        local ok, ret, err = pcall(cb, request_name, request, fd, obj)
        if not ok then
            log.warn("middleware callback error", "request_name", request_name, "fd", fd, "err", ret)
            return nil
        else
            if ret == nil then
                log.warn("middleware callback reject the request", "request_name", request_name, "fd", fd, "err", err)
                return nil
            end
        end
    end

    local r = f(request, fd, obj)
    if response_cb == nil then
        if r ~= nil then
            log.error("request function should not return a value", "request_name", request_name, "fd", fd)
        end
        return
    end
    return response_cb(r)
end

local function send_package(fd, pack)
    local data, sz = netpack.pack(pack)
    socket.write(fd, data, sz)
end

local function wakeup_call(pending, response, sz)
    local co = pending.co
    if not co then
        return false
    end
    pending.co = nil
    pending.response = response
    pending.sz = sz
    skynet.wakeup(pending)
    return true
end

function M.raw_dispatch(fd, sz, type, request_name, request, response_cb)
    if type == "REQUEST" then
        local ok, result = xpcall(dispatch_request, debug.traceback, fd, request_name, request, response_cb)
        if ok then
            if result then
                send_package(fd, result)
                log.debug("request dispatched successfully", "request_name", request_name, "fd", fd)
            end
        else
            log.error("dispatch request error", "request_name", request_name, "result", result)
        end
    else
        local sess = request_name
        local pending = g_sessions[sess]
        if pending then
            return wakeup_call(pending, request, sz)
        end
    end
end

local function register_protocol()
    skynet.register_protocol({
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function(msg, sz)
            return sz, g_host:dispatch(msg, sz)
        end,
        dispatch = function(fd, _, sz, type, request_name, request, response_cb)
            skynet.ignoreret() -- session is fd, don't call skynet.ret
            return M.raw_dispatch(fd, sz, type, request_name, request, response_cb)
        end,
    })
end

function M.notify(fd, name, param)
    send_package(fd, g_send_request(name, param))
end

function M.call(fd, name, param, session, timeout)
    send_package(fd, g_send_request(name, param, session))

    local pending = {
        name = name,
        co = coroutine.running(),
        response = nil,
    }
    g_sessions[session] = pending

    -- 默认超时时间
    if not timeout then
        timeout = config.get_number("sproto_timeout") or 10
    end
    skynet.sleep(timeout * 100, pending)
    g_sessions[session] = nil

    if pending.co then
        log.error("call timeout", "name", name, "fd", fd, "session", session)
        return nil
    end

    return pending.response
end

function M.get_sproto_info()
    return g_sproto_info
end

function M.get_sproto_host()
    return g_host
end

local function get_sproto_schema()
    local sproto_schema_path = config.get("sproto_schema_path")
    local sproto_index = config.get_number("sproto_index") or 1
    local ok, info = skynet.call(g_sproto_loader_service, "lua", "load_proto", sproto_schema_path, sproto_index)
    if not ok then
        error(info)
    end

    local sprotoloader = require("sprotoloader")
    local ret = sprotoloader.load(sproto_index)
    return ret, info or {}
end

local function reload_sproto()
    g_schema, g_sproto_info = get_sproto_schema()
    g_host = g_schema:host("base.package")
    g_send_request = g_host:attach(g_schema)
end

skynet.init(function()
    g_sproto_loader_service = skynet.uniqueservice("sproto_loader")

    reload_sproto()
    local sproto_schema_path = config.get("sproto_schema_path")
    event_channel_api.subscribe(g_sproto_loader_service, sproto_schema_path, reload_sproto)

    register_protocol()
end)

return M
