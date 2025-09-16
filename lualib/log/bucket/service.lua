-- 推送到 logger 服务
local skynet = require "skynet"
local ptype = require "ptype"
local log_level = require "log.log_level"

local PTYPE_LOG_NAME = ptype.PTYPE_LOG_NAME
local PTYPE_LOG_ERR_NAME = ptype.PTYPE_LOG_ERR_NAME

skynet.register_protocol {
    name = ptype.PTYPE_LOG_NAME,
    id = ptype.PTYPE_LOG,
    pack = skynet.pack,
}

skynet.register_protocol {
    name = ptype.PTYPE_LOG_ERR_NAME,
    id = ptype.PTYPE_LOG_ERR,
    pack = skynet.pack,
}

local M = {}
local bucket = {}

function bucket:put(record)
    if record.level <= log_level.WARN then
        skynet.send(self.service, PTYPE_LOG_ERR_NAME, record)
    else
        skynet.send(self.service, PTYPE_LOG_NAME, record)
    end
    return true
end

function M.new(conf)
    if bucket.service then
        return bucket
    end

    local service = skynet.localname(".logger")
    if not service then
        return nil
    end

    -- 在logger服务获取service bucket则返回其自己的实例
    if service == skynet.self() then
        local ok, mod = pcall(require, "global")
        if ok and mod then
            return mod.bucket
        end
        return nil
    end

    bucket.service = service
    return bucket
end

return M
