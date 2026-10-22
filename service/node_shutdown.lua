-- 节点停服编排。顺序：
--   1. stop_accepting 钩子：关掉对外入口（gate、HTTP 端口），不再放新请求进来
--   2. 卸载本节点所有实体类型的全部实体：落库、释放锁、踢下在线玩家
--   3. release 钩子：实体都落库之后释放其余资源（snowflake 归还机器号之类）
--   4. 停掉服务注册，再撤销节点级 etcd 租约：节点键、服务键、残留的实体锁一并消失，
--      别的节点立刻看到本节点下线，不用等 TTL 过期
--   5. 让 logger 写完缓冲，退出进程
-- 第 2 步有实体卸不掉时停在这里、进程不退出：那些实体还有没落库的改动，退出就丢了。
-- 排查后可以再发一次 shutdown。游戏层用 skyext.node_shutdown_api 挂钩子。
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local gm_api = require "skyext.gm_api"
local cluster_discovery = require "skyext.cluster_discovery"
local node_lease = require "skyext.node_lease"
local log = require "skyext.log"

local DEFAULT_TIMEOUT = 60

local g_hooks = {
    stop_accepting = {},
    release = {},
}
local g_running = false

local function run_hooks(phase)
    for _, hook in ipairs(g_hooks[phase]) do
        local ok, err = pcall(skynet.call, hook.addr, "lua", hook.cmd)
        if not ok then
            log.warn("shutdown hook failed", "phase", phase, "addr", hook.addr, "cmd", hook.cmd, "err", err)
        end
    end
end

-- 本节点上起了的 entity_agentmgr：按实体类型配置逐个查本地名字，没在本节点起的类型跳过
local function entity_managers()
    local ok, all = pcall(function()
        return require("skyext.entity.types").all()
    end)
    if not ok then
        return {}
    end
    local list = {}
    for type_name in pairs(all) do
        local addr = skynet.localname(".entity_agentmgr:" .. type_name)
        if addr then
            list[#list + 1] = { type_name = type_name, addr = addr }
        end
    end
    return list
end

-- 各实体类型并行卸载，返回还没卸掉的实体总数
local function unload_entities(timeout_sec)
    local managers = entity_managers()
    local remaining = 0
    local pending = #managers
    local waiter = {}
    for _, mgr in ipairs(managers) do
        skynet.fork(function()
            local ok, count = pcall(skynet.call, mgr.addr, "lua", "shutdown", timeout_sec)
            if not ok then
                log.error("entity shutdown failed", "type", mgr.type_name, "err", count)
                -- 不知道还剩多少，至少算一个，免得误以为已经卸干净
                count = 1
            end
            remaining = remaining + count
            pending = pending - 1
            if pending == 0 then
                skynet.wakeup(waiter)
            end
        end)
    end
    if pending > 0 then
        skynet.wait(waiter)
    end
    return remaining
end

local function shutdown(timeout_sec)
    log.info("node shutdown begin", "timeout", timeout_sec)
    run_hooks("stop_accepting")
    local remaining = unload_entities(timeout_sec)
    if remaining ~= 0 then
        log.error("node shutdown incomplete, process kept alive", "remaining", remaining)
        g_running = false
        return
    end
    run_hooks("release")
    -- 先停注册再撤租约：反过来的话，撤销之后心跳还会再跑一拍，用新租约把节点键写回去
    local stopped, stop_err = pcall(cluster_discovery.shutdown)
    if not stopped then
        log.warn("cluster discovery shutdown failed", "err", stop_err)
    end
    local revoked, revoke_err = pcall(node_lease.shutdown)
    if not revoked then
        log.warn("node lease revoke failed", "err", revoke_err)
    end
    log.info("node shutdown complete, exiting")
    pcall(skynet.call, ".logger", "lua", "close")
    skynet.abort()
end

local CMD = {}

-- 停服时回调 addr 服务的 cmd 命令。同一个 (phase, addr, cmd) 只记一次，按注册顺序执行
function CMD.add_hook(phase, addr, cmd)
    local hooks = assert(g_hooks[phase], "unknown shutdown phase: " .. tostring(phase))
    assert(type(cmd) == "string" and cmd ~= "", "shutdown hook needs a command")
    for _, hook in ipairs(hooks) do
        if hook.addr == addr and hook.cmd == cmd then
            return true
        end
    end
    hooks[#hooks + 1] = { addr = addr, cmd = cmd }
    return true
end

-- 开始停服。卸载可能要几十秒，这里立刻返回，进度看日志
function CMD.shutdown(timeout_sec)
    if g_running then
        return false, "already shutting down"
    end
    g_running = true
    skynet.fork(shutdown, tonumber(timeout_sec) or DEFAULT_TIMEOUT)
    return true, "shutdown started"
end

local GM_CMD = {
    shutdown = {
        desc = "停服：停止接入、卸载全部实体落库后退出进程",
        params = { timeout = "等实体卸载的秒数，默认 60" },
        handler = function(params)
            return CMD.shutdown(params.timeout)
        end,
    },
}

skynet.start(function()
    cmd_api.dispatch(CMD)
    gm_api.register(GM_CMD)
end)
