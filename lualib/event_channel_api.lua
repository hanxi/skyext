local skynet = require "skynet"
local mc = require "skynet.multicast"
local log = require "log"

local M = {}
local g_client_channels = {}
local g_server_channel

local function channel_new(service, subscribe_cmd)
    local up_channel = skynet.call(service, "lua", "GET_EVENT_CHANNEL")
    log.info("channel new", "up_channel", up_channel)
    local channel = mc.new({
        channel = up_channel,
        dispatch = function(channel, source, cmd, ...)
            local func = subscribe_cmd[cmd]
            if func then
                func(...)
            else
                log.error("unknown subscribe command from channel", "channel", channel, "source", source, "cmd", cmd)
            end
        end,
    })
    channel.subscribe_cmd = subscribe_cmd
    channel:subscribe()
    return channel
end

-- client api
function M.subscribe(service, cmd, func)
    local channel = g_client_channels[service]
    if not channel then
        local subscribe_cmd = {}
        channel = channel_new(service, subscribe_cmd)
        g_client_channels[service] = channel
    end

    channel.subscribe_cmd[cmd] = func
end

-- service api
function M.init(CMD)
    g_server_channel = mc.new()
    CMD.GET_EVENT_CHANNEL = function ()
        log.info("GET_EVENT_CHANNEL called", "channel", g_server_channel.channel)
        return g_server_channel.channel
    end
end

function M.publish(cmd, ...)
    g_server_channel:publish(cmd, ...)
end

return M
