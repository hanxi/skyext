--[[
可靠消息死信队列的运维入口。

死信队列本身在 MongoDB 里，是整个集群共享的一份数据，因此本服务按节点单例
（由 entity_agentmgr 用 uniqueservice 拉起），不随实体类型或 agent 数量放大：
GM 指令会在所有注册了该指令的服务上执行，每类型注册一次会让一次查询变成 N 次。

GM 指令：
  dlq_list    [type] [id] [limit]  列出死信
  dlq_replay  msg_id               重放一条死信（状态回到 pending 并唤醒目标实体）
  dlq_discard msg_id [operator]    丢弃一条死信（文档保留，只是不再出现在列表里）
]]

local skynet = require "skynet"
local cmd_api = require "skyext.cmd_api"
local gm_api = require "skyext.gm_api"
local reliable_msg = require "skyext.entity.reliable_msg"
local router = require "skyext.entity.router"
local log = require "skyext.log"

-- GM 参数经 HTTP query/body 传来，全是字符串
local function to_msg_id(v)
    if v == nil or v == "" then
        return nil, "msg_id is required"
    end
    local n = math.tointeger(tonumber(v))
    if not n then
        return nil, string.format("invalid msg_id: %s", tostring(v))
    end
    return n
end

-- target_id 可能是数字 ID，也可能是字符串 key，按能否转成整数决定
local function to_target_id(v)
    if v == nil or v == "" then
        return nil
    end
    return math.tointeger(tonumber(v)) or v
end

local function to_limit(v)
    if v == nil or v == "" then
        return nil
    end
    local n = math.tointeger(tonumber(v))
    if not n or n < 1 then
        return nil, string.format("invalid limit: %s", tostring(v))
    end
    return n
end

-- 列表里不回 args：那是业务负载，可能含有玩家数据，不该经 GM 接口整份吐出来
local function brief(doc)
    return {
        msg_id = doc.msg_id,
        seq = doc.seq,
        target_type = doc.target_type,
        target_id = doc.target_id,
        cmd = doc.cmd,
        attempts = doc.attempts,
        create_time = doc.create_time,
        dead_time = doc.dead_time,
        dead_reason = doc.dead_reason,
    }
end

local GM_CMD = {}

GM_CMD.dlq_list = {
    desc = "列出可靠消息死信队列",
    level = "read",
    params = {
        target_type = "实体类型（可选）",
        target_id = "实体 ID（可选）",
        limit = "最多返回条数（可选，默认 50）",
    },
    handler = function(params)
        params = params or {}
        local limit, err = to_limit(params.limit)
        if err then
            return false, err
        end
        local ok, docs = pcall(reliable_msg.list_dead, {
            target_type = params.target_type ~= "" and params.target_type or nil,
            target_id = to_target_id(params.target_id),
            limit = limit,
        })
        if not ok then
            log.error("dlq_list failed", "err", docs)
            return false, tostring(docs)
        end
        local result = {}
        for i, doc in ipairs(docs) do
            result[i] = brief(doc)
        end
        return true, { count = #result, messages = result }
    end,
}

GM_CMD.dlq_replay = {
    desc = "重放一条死信消息",
    level = "write",
    params = {
        msg_id = "消息 ID",
    },
    handler = function(params)
        params = params or {}
        local msg_id, err = to_msg_id(params.msg_id)
        if not msg_id then
            return false, err
        end
        local ok, doc, reason = pcall(reliable_msg.replay, msg_id)
        if not ok then
            log.error("dlq_replay failed", "msg_id", msg_id, "err", doc)
            return false, tostring(doc)
        end
        if not doc then
            return false, reason or "replay failed"
        end
        -- 唤醒失败不影响结论：消息已经回到 pending，实体加载或重试定时器会接上
        local poked = router.poke_reliable(doc.target_type, doc.target_id)
        log.warn(
            "dead letter replayed",
            "msg_id",
            msg_id,
            "target_type",
            doc.target_type,
            "target_id",
            doc.target_id,
            "cmd",
            doc.cmd,
            "poked",
            poked
        )
        return true,
            {
                msg_id = msg_id,
                target_type = doc.target_type,
                target_id = doc.target_id,
                cmd = doc.cmd,
                poked = poked,
            }
    end,
}

GM_CMD.dlq_discard = {
    desc = "丢弃一条死信消息（文档保留，仅不再出现在死信列表）",
    level = "admin",
    params = {
        msg_id = "消息 ID",
        operator = "操作人（可选，记入文档）",
    },
    handler = function(params)
        params = params or {}
        local msg_id, err = to_msg_id(params.msg_id)
        if not msg_id then
            return false, err
        end
        local called, ok, reason = pcall(reliable_msg.discard, msg_id, params.operator)
        if not called then
            log.error("dlq_discard failed", "msg_id", msg_id, "err", ok)
            return false, tostring(ok)
        end
        if not ok then
            return false, reason or "discard failed"
        end
        log.warn("dead letter discarded", "msg_id", msg_id, "operator", tostring(params.operator or "unknown"))
        return true, { msg_id = msg_id }
    end,
}

skynet.start(function()
    cmd_api.dispatch({})
    gm_api.register(GM_CMD)
    log.info("entity_dlq started")
end)
