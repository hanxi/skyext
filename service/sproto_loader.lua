local skynet = require "skynet"
local md5 = require "md5"
local event_channel_api = require "event_channel_api"
local sprotoloader = require "sprotoloader"
local cmd_api = require "cmd_api"
local log = require "log"

local CMD = {}
local g_sproto_loaded = {}

local function readfile(path)
    local f = io.input(path)
    local result = f:read "a"
    f:close()
    return result
end

local function load_sproto_schema(proto, reload)
    local schema_path = proto.schema_path
    local sproto_index = proto.sproto_index or 1
    local proto_loaded = g_sproto_loaded[sproto_index]
    if proto_loaded and proto_loaded.schema_path ~= schema_path then
        return false,
            string.format(
                "proto index conflict:%s proto_loaded:%s, proto:%s",
                sproto_index,
                proto_loaded.schema_path,
                schema_path
            )
    end

    if proto_loaded and not reload then
        return true, proto_loaded
    end

    log.info("loading sproto schema", "schema_path", schema_path, "index", sproto_index)
    local ok, ret = pcall(readfile, schema_path)
    if not ok then
        return false, ret
    end

    local cs = md5.sumhexa(ret)
    if proto_loaded and proto_loaded.checksum == cs then
        return true, proto_loaded
    end

    ok, ret = pcall(sprotoloader.save, ret, sproto_index)
    if not ok then
        return false, ret
    end

    proto.checksum = cs
    g_sproto_loaded[sproto_index] = proto

    event_channel_api.publish(schema_path)
    collectgarbage("collect")
    return true, proto
end

local function reload_sproto_schema()
    for _, proto in pairs(g_sproto_loaded) do
        local ok, errmsg = load_sproto_schema(proto, true)
        if not ok then
            return false, errmsg
        end
    end
    return true
end

function CMD.load_proto(schema_path, proto_index)
    return load_sproto_schema({
        schema_path = schema_path,
        sproto_index = proto_index,
    })
end

function CMD.reload_proto()
    return reload_sproto_schema()
end

skynet.start(function()
    event_channel_api.init(CMD)
    cmd_api.dispatch(CMD)
end)
