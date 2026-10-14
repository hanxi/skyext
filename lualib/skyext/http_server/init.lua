local skynet = require "skynet"
local service = require "skynet.service"
local watchdog_main = require "skyext.http_server.watchdog"

-- HTTP 服务器以「命名实例」方式创建：
-- 每个名字对应独立的 watchdog、agent 与路由表，
-- 同一节点内的多个 HTTP 端口（如对外的业务端口与内网 GM 端口）不会互相串路由。
local M = {}

local server = {}
server.__index = server

-- 同一个 Lua 虚拟机内的实例缓存，name -> server
local g_servers = {}

local function check_name(name)
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
        error("invalid http server name: " .. tostring(name), 3)
    end
end

-- 创建（或取回）命名 HTTP 服务器实例
function M.new(name)
    check_name(name)
    local s = g_servers[name]
    if s then
        return s
    end
    s = setmetatable({
        name = name,
        service_name = "http_watchdog_" .. name,
    }, server)
    g_servers[name] = s
    return s
end

-- 启动监听。conf: { host = "0.0.0.0", port = 8080, agent_count = 8 }
-- port 传 0 时由系统分配，返回值中的 port 为实际监听端口。
-- conf 还可覆盖资源上限（max_connections / read_timeout / write_timeout /
-- keepalive_timeout / keepalive_requests / request_body_size），
-- 未给出的字段取节点配置 http_<字段名>，再取内置默认值，见 skyext.http_server.limits。
function server:start(conf)
    assert(type(conf) == "table", "http server conf must be a table")
    assert(not self.addr, "http server already started: " .. self.name)

    local addr = service.new(self.service_name, watchdog_main, self.name)
    local info = skynet.call(addr, "lua", "start", conf)
    self.addr = addr
    self.port = info.port
    self.host = info.host
    return info
end

-- 注册路由模块，必须在 start 之后调用；返回时所有 agent 都已完成注册
function server:register_router(router_name)
    assert(type(router_name) == "string" and router_name ~= "", "invalid router name")
    local addr = assert(self.addr, "http server not started: " .. self.name)
    return skynet.call(addr, "lua", "register_router", router_name)
end

function server:address()
    return self.addr
end

-- 当前连接数与累计拒绝数，用于监控与排障
function server:stats()
    local addr = assert(self.addr, "http server not started: " .. self.name)
    return skynet.call(addr, "lua", "stats")
end

return M
