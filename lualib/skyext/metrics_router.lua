-- Prometheus 抓取端点。合并和渲染都在 .metrics 服务里做：
-- 这里只是个转发，HTTP agent 有多个实例，谁来抓都该看到同一份数据。
local skynet = require "skynet"
local log = require "skyext.log"
local metrics_text = require "skyext.metrics_text"

local M = {
    GET = {},
    POST = {},
}

M.GET["/metrics"] = function(_, res)
    -- 不缓存地址：localname 只是查本地句柄表，缓存住一个重启过的 .metrics
    -- 反而会让这个端点一直 500
    local addr = skynet.localname(".metrics")
    if not addr then
        log.error("metrics service not found")
        return res.write(503, "metrics service not available")
    end
    local ok, body = pcall(skynet.call, addr, "lua", "render")
    if not ok then
        log.error("metrics render failed", "err", tostring(body))
        return res.write(500, "metrics render failed")
    end
    return res.write(200, body, { ["content-type"] = metrics_text.CONTENT_TYPE })
end

return M
