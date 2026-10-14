-- 把本服务挂到 .metrics 上，由它在抓取时统一来拉。
--
-- 由 skyext.cmd_api 在接管消息分发时调用，业务代码不需要显式初始化。注册会往
-- 服务的 CMD 表里塞一个 collect_metrics 指令，所以自己接管 skynet.dispatch 的
-- 服务拉不到指标，连运行时数据也没有。
local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local log = require "skyext.log"

local M = {}

-- .metrics 可能比业务服务起得晚，重试几次；都失败就放弃，不能一直占着定时器
local RETRY_INTERVAL = 100 -- 1 秒
local MAX_ATTEMPTS = 10

local g_pending = false
local g_registered = false

local function collect_metrics()
    local metrics = require "skyext.metrics"
    return {
        metrics = metrics.collect(),
        -- 顺手带上 skynet 自己的运行时数据：抓取时反正要跟每个服务通一次消息，
        -- 比让 .metrics 再去 launcher 扇出一轮 STAT 便宜得多
        runtime = {
            mqlen = skynet.stat("mqlen"),
            cpu = skynet.stat("cpu"),
            message = skynet.stat("message"),
            memory = math.floor(collectgarbage("count") * 1024),
        },
    }
end

local function register(attempt)
    local addr = skynet.localname(".metrics")
    if addr == skynet.self() then
        -- .metrics 自己：抓取时直接读本地指标就行，不用绕一圈发消息给自己
        return
    end
    if not addr then
        if attempt < MAX_ATTEMPTS then
            return skynet.timeout(RETRY_INTERVAL, function()
                register(attempt + 1)
            end)
        end
        log.warn("metrics service not found, metrics of this service are not exported")
        return
    end
    -- 先把指令挂上去再注册：注册成功后 .metrics 随时可能来拉
    cmd_api.register({ collect_metrics = collect_metrics })
    local ok, err = pcall(skynet.call, addr, "lua", "register_service", skynet.self())
    if not ok then
        log.warn("metrics register failed", "err", tostring(err))
        return
    end
    g_registered = true
end

function M.ensure_registered()
    if g_pending then
        return
    end
    g_pending = true
    -- 指标常在模块加载期声明，那时还在主线程里，发不了消息，
    -- 所以挪到一个新协程里做
    skynet.timeout(0, function()
        register(1)
    end)
end

function M.registered()
    return g_registered
end

return M
