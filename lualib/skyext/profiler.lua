local skynet = require "skynet"
local log = require "skyext.log"

local M = {}

local g_sessions = {}
local g_next_session_id = 0

local function new_session_id()
    g_next_session_id = g_next_session_id + 1
    return g_next_session_id
end

local function lua_sampler(duration, target_service)
    local stacks = {}
    local sample_count = 0

    local function hook(event)
        local stack_parts = {}
        local level = 2
        while true do
            local info = debug.getinfo(level, "nSl")
            if not info then
                break
            end
            local name = info.name or "<anonymous>"
            local src = info.short_src or "?"
            local line = info.currentline or 0
            stack_parts[#stack_parts + 1] = string.format("%s:%s:%d", src, name, line)
            level = level + 1
        end
        if #stack_parts > 0 then
            local key = table.concat(stack_parts, ";")
            stacks[key] = (stacks[key] or 0) + 1
            sample_count = sample_count + 1
        end
    end

    debug.sethook(hook, "", 10000)
    -- 摘钩子必须无条件执行：采样一旦中途抛错，钩子和它闭包里的 stacks 表
    -- 会永远挂在这个服务上，之后每 10000 条指令都白跑一次
    local ok, err = pcall(skynet.sleep, duration * 100)
    debug.sethook()
    if not ok then
        error(err, 0)
    end

    return stacks, sample_count
end

function M.start(target_service, duration, freq)
    duration = duration or 10
    freq = freq or 99

    local session_id = new_session_id()
    local session = {
        id = session_id,
        target = target_service,
        duration = duration,
        freq = freq,
        status = "sampling",
        start_time = os.time(),
        stacks = nil,
        sample_count = 0,
    }
    g_sessions[session_id] = session

    skynet.fork(function()
        local ok, stacks, count = pcall(function()
            return lua_sampler(duration, target_service)
        end)
        if ok then
            session.stacks = stacks
            session.sample_count = count
            session.status = "completed"
        else
            session.status = "error"
            session.error = stacks
            log.error("profiler sampling failed", "session_id", session_id, "err", stacks)
        end
    end)

    return session_id
end

function M.status(session_id)
    if session_id then
        local s = g_sessions[session_id]
        if not s then
            return nil
        end
        return {
            id = s.id,
            target = s.target,
            duration = s.duration,
            status = s.status,
            sample_count = s.sample_count,
        }
    end

    local result = {}
    for id, s in pairs(g_sessions) do
        result[#result + 1] = {
            id = s.id,
            target = s.target,
            status = s.status,
            sample_count = s.sample_count,
        }
    end
    return result
end

function M.result(session_id)
    local s = g_sessions[session_id]
    if not s then
        return nil, "session not found"
    end
    if s.status ~= "completed" then
        return nil, "sampling not completed, status: " .. s.status
    end

    local lines = {}
    for stack, count in pairs(s.stacks) do
        lines[#lines + 1] = string.format("%s %d", stack, count)
    end
    table.sort(lines)
    return table.concat(lines, "\n")
end

skynet.init(function()
    local gm_api = require "skyext.gm_api"

    local GM_CMD = {}
    GM_CMD.profiler_start = {
        desc = "开始火焰图采样",
        params = { service = "目标服务名", duration = "采样时长(秒)", freq = "采样频率(Hz)" },
        handler = function(params)
            local session_id = M.start(params.service, tonumber(params.duration), tonumber(params.freq))
            return true, { session_id = session_id }
        end,
    }
    GM_CMD.profiler_status = {
        desc = "查询采样状态",
        params = { session_id = "会话ID(可选)" },
        handler = function(params)
            local result = M.status(params.session_id and tonumber(params.session_id))
            return true, result
        end,
    }
    GM_CMD.profiler_result = {
        desc = "获取采样结果(folded stack格式)",
        params = { session_id = "会话ID" },
        handler = function(params)
            local data, err = M.result(tonumber(params.session_id))
            if not data then
                return false, err
            end
            return true, data
        end,
    }
    gm_api.register(GM_CMD)
end)

return M
