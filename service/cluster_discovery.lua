local skynet = require "skynet"
local etcd = require "skyext.etcd"
local cluster = require "skynet.cluster"
local queue = require "skynet.queue"
local timer = require "skyext.timer"
local node_lease = require "skyext.node_lease"
local event_channel_api = require "skyext.event_channel_api"
local util_table = require "skyext.util.table"
local cmd_api = require "skyext.cmd_api"
local config = require "skyext.config"
local log = require "skyext.log"

log.config {
    -- traceback = debug.traceback,
}

local sformat = string.format

local NODE_PREFIX = "/skynet/node/"
local PATTERN_NODE = "([^/]+)$"
local PATTERN_SERVICE = "([^/]+)/([^/]+)$"
local SERVICE_PREFIX = "/skynet/service/"
local HEARTBEAT_INTERVAL = 10 -- 秒
local WATCH_SLEEP = 50 -- 500 毫秒

-- 服务发布
local g_etcd_client
-- 同步服务到 etcd
local g_service_local_synced = {}
local g_service_local = {}
-- 同步当前节点到 etcd
local g_self_node_info
local g_local_node_revision

local g_heartbeat_timer
-- 停服后置位：不再往 etcd 写
local g_closed = false

-- 服务发现
local g_map_service = {} -- service -> { map_node = { [node] = node_revision } }
local g_map_node = {} -- node -> { address, node_revision }
local g_etcd_node_revision
-- cluster_node_name 由 skyext 的 skynet.init 回调注入，服务 chunk 加载期读到的是 nil，
-- 会让注册进 etcd 的 key 变成 "node:nil"，所以惰性读取并缓存
local g_node_name
local function node_name()
    if not g_node_name then
        g_node_name = assert(config.get("cluster_node_name"), "cluster_node_name is not configured")
    end
    return g_node_name
end

local g_cluster_listened

-- 节点键和服务键都挂在节点级租约上（见 skyext.node_lease）。本服务不再自己申请租约：
-- 从前锁和服务发现各有一个租约，锁的没了而这里的还在，本节点就会留在 etcd 的服务
-- 列表里继续被路由进来，但每个实体都加不上锁——对外存活、对内全拒，还不会自动摘除。
local function leaseid()
    if g_closed or not node_lease.valid() then
        return nil
    end
    return node_lease.id()
end

local function make_node_key()
    return sformat("%s%s", NODE_PREFIX, node_name())
end

local function etcd_make_service_key(service)
    return sformat("%s%s/%s", SERVICE_PREFIX, service, node_name())
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
    local lease = leaseid()
    if not lease then
        return nil
    end

    local key = make_node_key()
    local ret, err = g_etcd_client:setnx(key, node_info, { lease = lease })
    if err then
        return nil, err
    end

    if not ret.body.succeeded then
        return nil
    end
    local revision = ret.body.header.revision
    log.info("etcd register node ok", "key", key, "leaseid", lease, "revision", revision)
    return tonumber(revision)
end

-- setnx 失败说明节点键已存在。两种情况：
--   * 键是本节点上一次注册写的（写成功了但响应丢在路上）——直接认领它的 revision；
--   * 键属于本节点的上一个进程实例，那个实例的租约还没过期——撤销它，腾出位置。
-- @return revision, revoked
local function claim_existing_node(node_info)
    local key = make_node_key()
    local r = g_etcd_client:get(key)
    if (not r) or not r.body or not r.body.kvs or (#r.body.kvs == 0) then
        return nil, false
    end

    local kv = r.body.kvs[1]
    local r_node_info = kv.value
    if r_node_info.address ~= node_info.address then
        log.error("etcd node address conflict", "local", node_info.address, "remote", r_node_info.address)
        return nil, false
    end

    assert(r_node_info.lease)
    -- 千万不能撤销自己当前的租约：节点键、服务键、全部实体锁都挂在上面，
    -- 撤掉等于把本节点整个踢下线，而这只是一次响应丢失。
    if tostring(r_node_info.lease) == tostring(leaseid()) then
        log.warn("etcd node key already written by current lease, adopting", "key", key)
        return tonumber(kv.mod_revision), false
    end

    g_etcd_client:revoke(tostring(r_node_info.lease))
    return nil, true
end

local function etcd_register_node(node_info)
    assert(node_info)
    local lease = leaseid()
    if not lease then
        return
    end

    node_info = util_table.deepcopy(node_info)
    node_info.lease = lease

    local rev, err = etcd_do_register_node(node_info)
    if rev or err then
        return rev
    end

    local existing, revoked = claim_existing_node(node_info)
    if existing then
        return existing
    end
    if not revoked then
        return
    end

    return etcd_do_register_node(node_info)
end

local function etcd_update_node(node_info, node_revision)
    assert(node_info)
    assert(node_revision)
    local lease = leaseid()
    if not lease then
        return nil
    end

    local key = make_node_key()
    local ret, err = g_etcd_client:mod(key, node_info, { lease = lease, mod_revision = node_revision })
    if err then
        return nil, err
    end

    if not ret.body.succeeded then
        return nil
    end
    local revision = ret.body.header.revision
    log.info("etcd update node ok", "key:", key, "leaseid", lease, "revision:", revision)
    return tonumber(revision)
end

local function etcd_do_register_service(service, info)
    assert(service)
    assert(info)
    local lease = leaseid()
    if not lease then
        return false
    end

    local key = etcd_make_service_key(service)
    local ret, err = g_etcd_client:set(key, info, { lease = lease })
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

-- 租约没了，挂在它上面的节点键和服务键已经被 etcd 删掉，本地那份"已同步"的记账
-- 就全作废了。清空之后，下一拍心跳会拿新租约从头注册一遍。
local function on_lease_lost(_, reason)
    log.error("cluster_discovery lost node lease, will re-register", "reason", reason)
    g_local_node_revision = nil
    g_service_local_synced = {}
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
    log.info("initializing node revision", "node", node_name(), "address", node_info.address)
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
        log.info("node revision initialized", "node", node_name(), "node_revision", new_node_revision)
    else
        log.error("failed to initialize node revision", "node", node_name(), "address", node_info.address)
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
                -- etcd 的 revision 走 JSON int64，收到的是字符串；首查那边 tonumber 过，
                -- 这里不转就是 number < string，Lua 直接抛错把 watch 流打断，
                -- 已知节点的地址变更于是永远只能靠 500ms 后的整表重查兜底
                local new_mod_revision = tonumber(ev.kv.mod_revision)
                if (not old_node_info) or (old_node_info.mod_revision < new_mod_revision) then
                    local node_info = ev.kv.value
                    node_info = util_table.deepcopy(node_info)
                    node_info.name = node
                    node_info.mod_revision = new_mod_revision
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
    -- 哈希表遍历顺序不定，排序后日志和订阅方拿到的列表才是稳定的
    table.sort(nodes)
    return nodes
end

local function get_service_obj(service)
    local obj = g_map_service[service]
    if not obj then
        obj = setmetatable({
            service = service,
            lock = queue(),
            -- 首查未完成就被 query_service 问到时要能答"还没有节点"，而不是炸在 pairs(nil)
            map_node = {},
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

    -- 快照没取全就不能对外发布半套节点列表，否则订阅方会按残缺的成员做路由；
    -- 保留上一份，等 watch 循环重试
    local prev = self.map_node
    self.map_node = {}

    for k, v in pairs(map_node) do
        if not self:update_node(k, v) then
            self.map_node = prev
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

    -- 停服之后心跳已经停了，不再往 etcd 写
    if g_heartbeat_timer then
        g_heartbeat_timer:wakeup()
    end
end

function CMD.unregister(services)
    for _, service in ipairs(services) do
        g_service_local[service] = nil
        log.info("unregister service", "service", service)
    end

    if g_heartbeat_timer then
        g_heartbeat_timer:wakeup()
    end
end

-- 停服：停掉心跳，之后不再往 etcd 注册。
--
-- 这里不撤销租约——它是节点级的，本节点别的服务还挂在上面。节点键和服务键真正
-- 消失是在 node_shutdown 最后撤销节点租约时，etcd 连带删掉，别的节点立刻看到本节点
-- 下线，不用等 TTL 过期。
function CMD.shutdown()
    g_closed = true
    if g_heartbeat_timer then
        g_heartbeat_timer:cancel()
        g_heartbeat_timer = nil
    end
    return true
end

function CMD.query_service(service)
    local s = get_service_obj(service)
    return s:get_nodes()
end

skynet.start(function()
    -- 配置写错时在这里就要炸：带着 nil 客户端起来，第一次心跳才报错更难查
    g_etcd_client = assert(etcd.new(config.get_table("etcd_config")))

    node_lease.on_lost("cluster_discovery", on_lease_lost)

    g_heartbeat_timer = timer.repeat_immediately("cluster_discovery_heartbeat", HEARTBEAT_INTERVAL, function()
        if not leaseid() then
            return
        end
        if not g_local_node_revision then
            init_node_revision()
        end
        if g_local_node_revision then
            sync_service()
        end
    end)
    log.info("Cluster discovery service started with heartbeat", "timerid", g_heartbeat_timer)

    first_query_nodes()
    skynet.fork(ensure_watch_node)
    event_channel_api.init()
    cmd_api.dispatch(CMD)
end)
