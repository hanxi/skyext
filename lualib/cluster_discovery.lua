local skynet = require "skynet"
local queue = require "skynet.queue"
local event_channel_api = require "event_channel_api"
local log = require "log"

local M = {}

local g_cluster_discovery_service

-- 注册服务
function M.register(services)
    assert(g_cluster_discovery_service, "cluster_discovery service not initialized")
    skynet.send(g_cluster_discovery_service, "lua", "register", services)
end

-- 注销服务
function M.unregister(services)
    assert(g_cluster_discovery_service, "cluster_discovery service not initialized")
    skynet.send(g_cluster_discovery_service, "lua", "unregister", services)
end

local g_services_cache = {} -- service -> service_obj
local service_mt = {}
service_mt.__index = service_mt

local function get_service_obj(service)
    local obj = g_services_cache[service]
    if not obj then
        obj = setmetatable({
            service = service,
            lock = queue(),
        }, service_mt)
        g_services_cache[service] = obj
        log.info("cluster_discovery create service object", "service", service)
    end
    obj:ensure_init()
    return obj
end

function service_mt:ensure_init()
    if not self.inited then
        self.lock(self.init, self)
    end
end

function service_mt:init()
    if self.inited then
        return
    end

    local nodes = skynet.call(g_cluster_discovery_service, "lua", "query_service", self.service)
    self.inited = true
    self:update(nodes)
    log.info("cluster_discovery service init", "service", self.service, "nodes", self.nodes)
end

function service_mt:update(nodes)
    self.nodes = nodes
end

-- 随机一个节点
function M.random(service)
    local service_obj = get_service_obj(service)
    local nodes = service_obj.nodes
    if #nodes == 0 then
        return nil
    end
    local node = nodes[math.random(#nodes)]
    return node
end

-- 所有节点
function M.nodes(service)
    local service_obj = get_service_obj(service)
    return service_obj.nodes
end

-- 订阅服务变更
local function on_service_change(service, nodes)
    log.info("on_service_change", "service", service, "nodes", nodes)

    local service_obj = g_services_cache[service]
    if not service_obj then
        return
    end
    service_obj:update(nodes)
end

skynet.init(function()
    g_cluster_discovery_service = skynet.uniqueservice("cluster_discovery")
    event_channel_api.subscribe(g_cluster_discovery_service, "service_change", on_service_change)
end)

return M
