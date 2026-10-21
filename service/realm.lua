-- 区服目录：server（出生服）-> game（逻辑服）-> zone（战区）的映射。
--
-- 存在 etcd 的 /skyext/realm/ 下，每个节点一个本服务：启动时整表读一遍，之后 watch，
-- 变化时把整份快照广播给订阅方（skyext.realm）。目录很小，广播整份比广播增量简单可靠。
-- 开服、调战区是改 etcd 里的数据，不用改配置、不用重启。
--
--   /skyext/realm/server/<server>  { game, name, tag, status, open_time }
--   /skyext/realm/game/<game>      { zone }
--   /skyext/realm/zone/<zone>      {}
local skynet = require "skynet"
local etcd = require "skyext.etcd"
local cmd_api = require "skyext.cmd_api"
local gm_api = require "skyext.gm_api"
local event_channel_api = require "skyext.event_channel_api"
local config = require "skyext.config"
local time = require "skyext.time"
local log = require "skyext.log"

local PREFIX = "/skyext/realm/"
local KINDS = { server = "servers", game = "games", zone = "zones" }
local WATCH_RETRY = 50 -- 1/100 秒

local g_etcd_client
local g_dir = { servers = {}, games = {}, zones = {}, revision = 0 }

local function parse_key(key)
    local kind, name = key:match("^" .. PREFIX .. "(%a+)/(.+)$")
    local field = kind and KINDS[kind]
    if not field then
        return nil
    end
    return field, name
end

local function publish()
    event_channel_api.publish("realm_change", g_dir)
end

local function load_all()
    local ret, err = g_etcd_client:readdir(PREFIX)
    if not ret or not ret.body or not ret.body.header then
        log.error("realm load failed", "err", err, "ret", ret)
        return false
    end
    local dir = { servers = {}, games = {}, zones = {}, revision = tonumber(ret.body.header.revision) }
    for _, kv in ipairs(ret.body.kvs or {}) do
        local field, name = parse_key(kv.key)
        if field and type(kv.value) == "table" then
            dir[field][name] = kv.value
        else
            log.warn("realm ignores an unknown key", "key", kv.key)
        end
    end
    g_dir = dir
    publish()
    return true
end

-- 目录是空的且配置里带了 realm_seed 时写入种子：本地开发、新环境首次启动不用手动开服。
-- 用 setnx 逐条写，多个节点同时启动也不会互相覆盖；目录里已经有数据就完全不碰
local function apply_seed()
    if next(g_dir.servers) then
        return
    end
    local seed = config.get_table("realm_seed")
    if type(seed) ~= "table" then
        return
    end
    for kind, field in pairs(KINDS) do
        for name, value in pairs(seed[field] or {}) do
            if kind == "server" then
                value.status = value.status or "open"
                value.open_time = value.open_time or time.now()
            end
            local ok, err = g_etcd_client:setnx(PREFIX .. kind .. "/" .. name, value)
            if not ok then
                log.error("realm seed failed", "kind", kind, "name", name, "err", err)
            end
        end
    end
    log.info("realm seeded from config")
end

local function apply_events(events)
    for _, ev in ipairs(events) do
        local field, name = parse_key(ev.kv.key)
        if field then
            if ev.type == "DELETE" then
                g_dir[field][name] = nil
            elseif type(ev.kv.value) == "table" then
                g_dir[field][name] = ev.kv.value
            end
        end
    end
end

local function watch()
    if not load_all() then
        return
    end
    local w <close>, err = g_etcd_client:watchdir(PREFIX, { start_revision = g_dir.revision + 1 })
    if err then
        log.error("realm watch failed", "err", err)
        return
    end
    for ret in w do
        local events = ret.result and ret.result.events
        if events and #events > 0 then
            apply_events(events)
            g_dir.revision = tonumber(ret.result.header.revision) or g_dir.revision
            log.info("realm changed", "revision", g_dir.revision)
            publish()
        end
    end
end

local function ensure_watch()
    while true do
        local ok, err = xpcall(watch, debug.traceback)
        if not ok then
            log.error("realm watch loop failed", "err", err)
        end
        skynet.sleep(WATCH_RETRY)
    end
end

local CMD = {}

function CMD.snapshot()
    return g_dir
end

local function put(kind, name, value)
    local ret, err = g_etcd_client:set(PREFIX .. kind .. "/" .. name, value)
    if not ret or ret.status ~= 200 then
        return false, err or "etcd write failed"
    end
    return true
end

local function valid_name(name)
    return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil
end

local GM_CMD = {}

GM_CMD.realm_list = {
    desc = "查看区服目录",
    handler = function()
        return true, g_dir
    end,
}

GM_CMD.realm_open = {
    desc = "开服：新增一个区服。game 不存在时一并创建（需给 zone）",
    params = {
        server = "区服 ID，如 s4",
        game = "归属的逻辑服",
        name = "显示名",
        tag = "跨服场景里的服号前缀，默认等于 server",
        zone = "game 不存在时，新 game 归属的战区",
    },
    handler = function(params)
        local server, game = params.server, params.game
        if not valid_name(server) or not valid_name(game) then
            return false, "server and game are required"
        end
        if g_dir.servers[server] then
            return false, "server already exists"
        end
        if not g_dir.games[game] then
            local zone = params.zone
            if not valid_name(zone) or not g_dir.zones[zone] then
                return false, "new game needs an existing zone"
            end
            local ok, err = put("game", game, { zone = zone })
            if not ok then
                return false, err
            end
        end
        return put("server", server, {
            game = game,
            name = params.name or server,
            tag = params.tag or server:upper(),
            status = "open",
            open_time = time.now(),
        })
    end,
}

GM_CMD.realm_set_zone = {
    desc = "调战区：把一个逻辑服划到另一个战区",
    params = { game = "逻辑服", zone = "目标战区，不存在时自动创建" },
    handler = function(params)
        local game, zone = params.game, params.zone
        if not g_dir.games[game] or not valid_name(zone) then
            return false, "unknown game or invalid zone"
        end
        if not g_dir.zones[zone] then
            local ok, err = put("zone", zone, {})
            if not ok then
                return false, err
            end
        end
        return put("game", game, { zone = zone })
    end,
}

skynet.start(function()
    g_etcd_client = assert(etcd.new(config.get_table("etcd_config")))
    event_channel_api.init()
    cmd_api.dispatch(CMD)
    -- 先同步读一遍，订阅方第一次 snapshot 就能拿到完整目录
    if load_all() then
        apply_seed()
        load_all()
    end
    skynet.fork(ensure_watch)
    gm_api.register(GM_CMD)
end)
