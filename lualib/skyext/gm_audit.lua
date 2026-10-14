-- GM 操作审计：谁、从哪、执行了什么、结果如何，一行一条追加进 JSONL。
--
-- 普通日志会被业务日志淹没、也会被轮转切掉，"上周谁 kill 了 rolenode 的服务"
-- 这种事后追查基本查不动。审计单独落一份只增不改的文件，GM 指令频率很低，
-- 一次操作一次追加写完全够用。
local skynet = require "skynet"
local cjson = require "cjson"
local config = require "skyext.config"
local time = require "skyext.time"
local log = require "skyext.log"

local M = {}

local MAX_RECENT = 100
local MAX_VALUE_LEN = 256
-- 这些参数不进审计：审计文件会被运维传看，不该带着凭证到处跑
local REDACTED = { token = true, password = true, secret = true }

local g_recent = {}

local function audit_path()
    return config.get("gm_audit_path") or (skynet.getenv("root") .. "/gm_audit.jsonl")
end

local function sanitize(params)
    if type(params) ~= "table" then
        return nil
    end
    local out, count = {}, 0
    for k, v in pairs(params) do
        if type(k) == "string" then
            local text
            if REDACTED[k] then
                text = "[redacted]"
            else
                text = type(v) == "table" and "[table]" or tostring(v)
                if #text > MAX_VALUE_LEN then
                    text = text:sub(1, MAX_VALUE_LEN) .. "..."
                end
            end
            out[k] = text
            count = count + 1
        end
    end
    if count == 0 then
        return nil
    end
    return out
end

local function append(record)
    local path = audit_path()
    local fh, oerr = io.open(path, "a")
    if not fh then
        return nil, oerr or ("cannot open " .. path)
    end
    local ok, werr = fh:write(cjson.encode(record), "\n")
    fh:close()
    if not ok then
        return nil, werr or "write failed"
    end
    return true
end

-- @param entry { account, role, peer, cmd, params, result, detail }
function M.record(entry)
    local record = {
        time = time.format(time.now()),
        account = entry.account,
        role = entry.role,
        peer = entry.peer,
        cmd = entry.cmd,
        params = sanitize(entry.params),
        result = entry.result,
        detail = entry.detail,
    }

    table.insert(g_recent, 1, record)
    while #g_recent > MAX_RECENT do
        table.remove(g_recent)
    end

    -- 写不进审计文件不能让 GM 指令跟着失败（磁盘满了还得能 kill 服务），
    -- 但必须在日志里留痕，否则审计是空的也没人知道
    local called, written, err = pcall(append, record)
    if not called then
        log.error("GM audit write failed", "err", tostring(written))
    elseif not written then
        log.error("GM audit write failed", "err", tostring(err))
    end

    log.info("GM audit", "account", record.account, "peer", record.peer, "cmd", record.cmd, "result", record.result)
    return record
end

-- 最近的审计记录，新的在前。文件被轮转或进程重启后只剩内存里这些。
function M.recent(limit)
    limit = math.min(tonumber(limit) or 20, #g_recent)
    local result = {}
    for i = 1, limit do
        result[i] = g_recent[i]
    end
    return result
end

return M
