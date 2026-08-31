local skynet = require "skynet"
local etcd = require "etcd"
local cluster = require "skynet.cluster"
local queue = require "skynet.queue"
local timer = require "timer"
local event_channel_api = require "event_channel_api"
local util_table = require "util.table"
local cmd_api = require "cmd_api"
local config = require "config"
local log = require "log"

log.config {
    -- traceback = debug.traceback,
}

local sformat = string.format

local NODE_PREFIX = "/skynet/node/"
local PATTERN_NODE = "([^/]+)$"
local PATTERN_SERVICE = "([^/]+)/([^/]+)$"
local SERVICE_PREFIX = "/skynet/service/"
local LEASE_TTL = 30 -- 秒
local HEARTBEAT_INTERVAL = LEASE_TTL // 3
local WATCH_SLEEP = 50 -- 500 毫秒

-- 服务发布
local g_etcd_client
local g_leaseid
-- 同步服务到 etcd
local g_service_local_synced = {}
local g_service_local = {}
-- 同步当前节点到 etcd
local g_self_node_info
local g_local_node_revision

local g_keepalive_timer
local g_heartbeat_timer

-- 服务发现
local g_map_service = {} -- service -> { map_node = { [node] = node_revision } }
local g_map_node = {} -- node -> { address, node_revision }
local g_etcd_node_revision
local g_node_name = config.get("cluster_node_name")
local g_cluster_listened

local function etcd_grant()
    local ret, err = g_etcd_client:grant(LEASE_TTL)
    if not ret then
        log.warn("cluster_discovery grant leaseid failed", "err", err)
        return
    elseif (not ret.body) or not ret.body.ID then
        log.error("cluster_discovery grant leaseid failed", "ret", ret)
        return
    end

    g_leaseid = ret.body.ID
    log.info("cluster_discovery grant succ", "leaseid", g_leaseid)
    return true
end

local function etcd_keepalive()
    local ret, err = g_etcd_client:keepalive(g_leaseid)
    if not ret then
        log.warn("cluster_discovery keepalive failed socket", "err", err)
        return true
    elseif (not ret.body) or not ret.body.result or not ret.body.result.TTL then
        log.error("cluster_discovery keepalive overdue", "leaseid", g_leaseid)
        return false
    end

    log.debug("cluster_discovery etcd keepalive succ", "leaseid", g_leaseid, "ttl", ret.body.result.TTL)
    return true
end

local function make_node_key()
    return sformat("%s%s", NODE_PREFIX, g_node_name)
end

local function etcd_make_service_key(service)
    return sformat("%s%s/%s", SERVICE_PREFIX, service, g_node_name)
end

local function get_self_node_info()
    if g_self_node_info then
        return g_self_node_info
    end

    local listen_port = config.get("cluster_listen_port")
    local host = config.get("cluster_host")

    g_self_node_info = {
        address = sformat("%s:%s", host, listen_port),
    }
    log.info("get_self_node_info ok", "address", g_self_node_info.address)
    return g_self_node_info
end

local function etcd_do_register_node(node_info)
    if not g_leaseid then
        return nil
    end

    local key = make_node_key()
    local ret, err = g_etcd_client:setnx(key, node_info, { lease = g_leaseid })
    if err then
        return nil, err
    end

    if not ret.body.succeeded then
        return nil
    end
    local revision = ret.body.header.revision
    log.info("etcd register node ok", "key", key, "leaseid", g_leaseid, "revision", revision)
    return tonumber(revision)
end

local function etcd_revoke_if_same_node(node_info)
    local key = make_node_key()
    local r = g_etcd_client:get(key)
    if (not r) or not r.body or not r.body.kvs or (#r.body.kvs == 0) then
        return false
    end

    local kv = r.body.kvs[1]
    local r_node_info = kv.value
    if r_node_info.address ~= node_info.address then
        log.error("etcd node address conflict", "local", node_info.address, "remote", r_node_info.address)
        return false
    end

    assert(r_node_info.lease)
    g_etcd_client:revoke(tostring(r_node_info.lease))
    return true
end

local function etcd_register_node(node_info)
    assert(node_info)
    if not g_leaseid then
        return
    end

    node_info = util_table.deepcopy(node_info)
    node_info.lease = g_leaseid

    local rev, err = etcd_do_register_node(node_info)
    if rev or err then
        return rev
    end

    if not etcd_revoke_if_same_node(node_info) then
        return
    end

    return etcd_do_register_node(node_info)
end

local function etcd_update_node(node_info, node_revision)
    assert(node_info)
    assert(node_revision)
    if not g_leaseid then
        return nil
    end

    local key = make_node_key()
    local ret, err = g_etcd_client:mod(key, node_info, { lease = g_leaseid, mod_revision = node_revision })
    if err then
        return nil, err
    end

    if not ret.body.succeeded then
        return nil
    end
    local revision = ret.body.header.revision
    log.info("etcd update node ok", "key:", key, "leaseid", g_leaseid, "revision:", revision)
    return tonumber(revision)
end

local function etcd_do_register_service(service, info)
    assert(service)
    assert(info)
    if not g_leaseid then
        return false
    end

    local key = etcd_make_service_key(service)
    local ret, err = g_etcd_client:set(key, info, { lease = g_leaseid })
    if not ret then
        log.error("etcd set fail", "key", key, "err", err)
        return false
    end

    log.info("etcd register service ok", "key", key, "revision", ret.body.header.revision)
    return true
end

local function etcd_register_service(service)
    if not g_local_node_revision then
        return
    end

    local sinfo = g_service_local[service]
    sinfo.node_revision = g_local_node_revision

    local last = g_service_local_synced[service]

    local info = util_table.deepcopy(sinfo)
    if (not last) or (last.node_revision ~= info.node_revision) then
        local ok = etcd_do_register_service(service, info)
        if ok then
            g_service_local_synced[service] = info
        end
    end
end

local function etcd_do_unregister_service(service)
    assert(service)
    local key = etcd_make_service_key(service)
    local ret, err = g_etcd_client:delete(key)
    if not ret then
        log.error("etcd delete fail", "key", key, "err", err)
        return false
    end

    log.error("etcd unregister service ok", "key", key)
    return true
end

local function etcd_unregister_service(service)
    if not g_service_local_synced[service] then
        return
    end

    local ok = etcd_do_unregister_service(service)
    if ok then
        g_service_local_synced[service] = nil
    end
end

local function heartbeat_timer_reset()
    if g_keepalive_timer then
        g_keepalive_timer:cancel()
        g_keepalive_timer = nil
    end
    g_local_node_revision = nil
    log.info("cluster_discovery heartbeat timer reset")
end

local function init_keepalive_timer()
    g_local_node_revision = nil

    if not etcd_grant() then
        return
    end

    if g_keepalive_timer then
        g_keepalive_timer:cancel()
        g_keepalive_timer = nil
    end

    g_keepalive_timer = timer.repeat_immediately("cluster_discovery_keepalive", HEARTBEAT_INTERVAL, function()
        if not etcd_keepalive() then
            heartbeat_timer_reset()
        end
    end)
    log.info("cluster_discovery keepalive timer initialized", "timer_obj", g_keepalive_timer)
end

local function cluster_listen(node_info)
    if g_cluster_listened then
        return
    end
    local port = node_info.address:match(":(.*)$")
    cluster.open(tonumber(port))
    g_cluster_listened = true
end

local function init_node_revision()
    local node_info = get_self_node_info()
    log.info("initializing node revision", "node", g_node_name, "address", node_info.address)
    local new_node_revision
    if g_local_node_revision then
        new_node_revision = etcd_update_node(node_info, g_local_node_revision)
    else
        new_node_revision = etcd_register_node(node_info)
        cluster_listen(node_info)
    end

    if new_node_revision then
        g_service_local_synced = {}
        g_local_node_revision = new_node_revision
        log.info("node revision initialized", "node", g_node_name, "node_revision", new_node_revision)
    else
        log.error("failed to initialize node revision", "node", g_node_name, "address", node_info.address)
    end
end

local function sync_service()
    -- add or update
    for service, _ in pairs(g_service_local) do
        etcd_register_service(service)
    end

    -- del
    for service, _ in pairs(g_service_local_synced) do
        if not g_service_local[service] then
            etcd_unregister_service(service)
        end
    end
end

-------------------------------------------------------------------
-- 节点发现
-------------------------------------------------------------------

local function resolve_node_name(key)
    return key:match(PATTERN_NODE)
end

-- 查询所有节点
local function etcd_query_all_nodes()
    local key = NODE_PREFIX
    local r = g_etcd_client:readdir(key)
    if (not r) or not r.body then
        return false
    end

    local map_node = {}
    if not r.body.kvs then
        return true, map_node, tonumber(r.body.header.revision)
    end

    for _, kv in ipairs(r.body.kvs) do
        local node = resolve_node_name(kv.key)
        if not node then
            log.error("invalid node", "key", kv.key)
            return false
        end

        local node_info = kv.value
        node_info.name = node
        node_info.mod_revision = tonumber(kv.mod_revision)
        map_node[node] = node_info
    end

    return true, map_node, tonumber(r.body.header.revision)
end

local function cluster_reload_nodes(deletes)
    local node2address = {}
    for node, info in pairs(g_map_node) do
        node2address[node] = info.address
    end
    for _, node in pairs(deletes or {}) do
        node2address[node] = false
    end
    node2address.__nowaiting = true
    cluster.reload(node2address)
end

local function first_query_nodes()
    local ok, map_node, etcd_revision = etcd_query_all_nodes()
    if not ok then
        return false
    end

    g_map_node = map_node

    assert(etcd_revision)
    g_etcd_node_revision = etcd_revision
    cluster_reload_nodes()
    return true
end

local function watch_node()
    if not first_query_nodes() then
        return
    end

    log.info("watch etcd node", "revision", g_etcd_node_revision)
    local key = NODE_PREFIX
    local watch_fun <close>, err = g_etcd_client:watchdir(key, { start_revision = g_etcd_node_revision + 1 })
    if err then
        log.error("watchdir failed", "key", key, "err", err)
        return
    end

    for ret, _, _ in watch_fun do
        local deletes = {}
        for _, ev in ipairs(ret.result.events or {}) do
            local node = resolve_node_name(ev.kv.key)
            if not node then
                log.error("watch invalid node", "key", ev.kv.key)
                return
            end
            if ev.type == "DELETE" then
                g_map_node[node] = nil
                deletes[#deletes + 1] = node
                log.info("watch node deleted", "node", node)
            elseif ev.type == "PUT" then
                local old_node_info = g_map_node[node]
                if (not old_node_info) or (old_node_info.mod_revision < ev.kv.mod_revision) then
                    local node_info = ev.kv.value
                    node_info = util_table.deepcopy(node_info)
                    node_info.name = node
                    node_info.mod_revision = tonumber(ev.kv.mod_revision)
                    g_map_node[node] = node_info
                    cluster_reload_nodes()
                    log.info("watch node updated", "node", node)
                end
            end
        end
        cluster_reload_nodes(deletes)

        g_etcd_node_revision = tonumber(ret.result and ret.result.header.revision)
        log.info("etcd node revision updated", "revision", g_etcd_node_revision)
    end
end

local function ensure_watch_node()
    while true do
        local ok, err = xpcall(watch_node, debug.traceback)
        if not ok then
            log.error("ensure_watch_node failed", "err", err)
        end
        skynet.sleep(WATCH_SLEEP)
    end
end

-------------------------------------------------------------------
-- 服务发现
-------------------------------------------------------------------
local service_mt = {}
service_mt.__index = service_mt

function service_mt:get_nodes()
    local nodes = {}
    for node, _ in pairs(self.map_node) do
        nodes[#nodes + 1] = node
    end
    return nodes
end

local function get_service_obj(service)
    local obj = g_map_service[service]
    if not obj then
        obj = setmetatable({
            service = service,
            lock = queue(),
        }, service_mt)
        g_map_service[service] = obj
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
    self.inited = true -- 必须置位,否则每次 ensure_init(query_service_info)都重复 fork watch 循环,每条循环持有 1 条 etcd watch 长连接不释放

    local ok, err = xpcall(self.first_query, debug.traceback, self)
    if not ok then
        self.inited = false
        error(err)
    end
    skynet.fork(function()
        while true do
            local ok, err = xpcall(self.watch, debug.traceback, self)
            if not ok then
                log.error("service watch failed", "err", err)
            end
            skynet.sleep(WATCH_SLEEP)
        end
    end)
end

local function resolve_service_name(key)
    return key:match(PATTERN_SERVICE)
end

local function make_service_key_prefix(service)
    return sformat("%s%s/", SERVICE_PREFIX, service)
end

local function etcd_query_service(service)
    local key = make_service_key_prefix(service)
    local r = g_etcd_client:readdir(key)
    log.debug("etcd query", "service", service, "key", key, "r", r)
    if (not r) or not r.body then
        return false
    end

    local map_node = {}
    if not r.body.kvs then
        return true, map_node, tonumber(r.body.header.revision)
    end

    for _, kv in ipairs(r.body.kvs) do
        local _, node = resolve_service_name(kv.key)
        if not node then
            log.error("invalid service", "key", kv.key)
            return false
        end

        map_node[node] = kv.value
    end

    return true, map_node, tonumber(r.body.header.revision)
end

function service_mt:first_query()
    local ok, map_node, etcd_revision = etcd_query_service(self.service)
    log.debug("service first_query", "service", self.service, "ok", ok, "revision", etcd_revision, "map_node", map_node)
    if not ok then
        return false
    end

    self.map_node = {}

    for k, v in pairs(map_node) do
        if not self:update_node(k, v) then
            return false
        end
    end

    self:update_revision(etcd_revision)
    return true
end

function service_mt:update_node(node, info)
    local node_revision = assert(info.node_revision)

    local node_info = g_map_node[node]
    if not node_info then
        log.debug("service update_node failed node not found", "service", self.service, "node", node)
        return false
    end

    local rev = node_info.mod_revision
    if rev < node_revision then
        log.warn(
            "service update_node failed node revision too old",
            "service",
            self.service,
            "node",
            node,
            "revision",
            node_revision,
            "actual_revision",
            rev
        )
        return false
    end

    self.map_node[node] = node_revision
    log.info(
        "service update_node succeed",
        "service",
        self.service,
        "node",
        node,
        "revision",
        node_revision,
        "actual_revision",
        rev
    )
    return true
end

function service_mt:delete_node(node)
    log.info("service delete_node", "service", self.service, "node", node)
    self.map_node[node] = nil
end

function service_mt:update_revision(revision)
    self.etcd_revision = revision

    local nodes = self:get_nodes()
    event_channel_api.publish("service_change", self.service, nodes)

    log.info("service update_revision", "service", self.service, "revision", revision, "nodes", nodes)
end

function service_mt:watch()
    if not self:first_query() then
        return
    end

    local key = make_service_key_prefix(self.service)
    local watch_fun <close>, err = g_etcd_client:watchdir(key, { start_revision = self.etcd_revision + 1 })
    if err then
        log.error("service watchdir failed", "key", key, "err", err)
        return
    end

    log.info("servide watch etcd", "service", self.service, "revision", self.etcd_revision, "key", key)
    for ret, _, _ in watch_fun do
        for _, ev in ipairs(ret.result.events or {}) do
            local _, node = resolve_service_name(ev.kv.key)
            if not node then
                log.error("service watch invalid service", "key", ev.kv.key)
                return
            end
            if ev.type == "DELETE" then
                self:delete_node(node)
            elseif ev.type == "PUT" then
                if not self:update_node(node, ev.kv.value) then
                    return
                end
            end
        end

        local etcd_revision = tonumber(ret.result and ret.result.header.revision)
        self:update_revision(etcd_revision)
        log.info("service watch etcd revision updated", "service", self.service, "revision", etcd_revision)
    end
end

local CMD = {}
function CMD.register(services)
    for _, service in ipairs(services) do
        g_service_local[service] = {}
        log.info("register service", "service", service)
    end

    g_heartbeat_timer:wakeup()
end

function CMD.unregister(services)
    for _, service in ipairs(services) do
        g_service_local[service] = nil
        log.info("unregister service", "service", service)
    end

    g_heartbeat_timer:wakeup()
end

function CMD.query_service(service)
    local s = get_service_obj(service)
    return s:get_nodes()
end

skynet.start(function()
    local etcd_config = config.get_table("etcd_config")
    g_etcd_client = etcd.new(etcd_config)

    g_heartbeat_timer = timer.repeat_immediately("cluster_discovery_heartbeat", HEARTBEAT_INTERVAL, function()
        if not g_keepalive_timer then
            init_keepalive_timer()
        end
        if not g_local_node_revision then
            init_node_revision()
        end
        if g_keepalive_timer and g_local_node_revision then
            sync_service()
        end
    end)
    log.info("Cluster discovery service started with heartbeat", "timerid", g_heartbeat_timer)

    first_query_nodes()
    skynet.fork(ensure_watch_node)
    event_channel_api.init()
    cmd_api.dispatch(CMD)
end)
