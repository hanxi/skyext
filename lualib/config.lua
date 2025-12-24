local skynet = require "skynet"

local M = {}
local conf = {}

function M.get(key)
    if conf[key] ~= nil then
        return conf[key]
    end

    local value = skynet.getenv(key)
    if value == nil then
        return
    end

    conf[key] = value
    return conf[key]
end

function M.get_boolean(key)
    if conf[key] ~= nil then
        return conf[key]
    end

    local value = skynet.getenv(key)
    if value == nil then
        return
    end

    if value == "true" then
        value = true
    else
        value = false
    end

    conf[key] = value
    return conf[key]
end

function M.get_number(key)
    if conf[key] ~= nil then
        return conf[key]
    end

    local value = skynet.getenv(key)
    if value == nil then
        return
    end

    value = tonumber(value)
    conf[key] = value
    return conf[key]
end

function M.get_table(key)
    local s = M.get(key)
    if type(s) == "string" then
        local f, err1 = load("return " .. s, "@" .. key)
        if not f then
            error("load config failed:" .. err1 .. s)
        end

        local ok, err2 = pcall(f)
        if not ok then
            error("exec config failed:" .. err2)
        end

        s = err2
        conf[key] = s
    end
    return s
end

local function serialize(_t)
    if type(_t) == "table" then
        local s = "{"
        for k, v in pairs(_t) do
            s = s .. "[" .. serialize(k) .. "]=" .. serialize(v) .. ","
        end
        return s .. "}"
    elseif type(_t) == "string" then
        return '"' .. _t .. '"'
    else
        return tostring(_t)
    end
end

local function load_config(config_name)
    local result = {}
    local function getenv(name)
        return assert(os.getenv(name), [[os.getenv() failed: ]] .. name)
    end
    local sep = package.config:sub(1, 1)
    local current_path = [[.]] .. sep
    local function include(filename)
        local last_path = current_path
        local path, name = filename:match([[(.*]] .. sep .. [[)(.*)$]])
        if path then
            if path:sub(1, 1) == sep then -- root
                current_path = path
            else
                current_path = current_path .. path
            end
        else
            name = filename
        end
        local f = assert(io.open(current_path .. name))
        local code = assert(f:read [[*a]])
        code = string.gsub(code, [[%$([%w_%d]+)]], getenv)
        f:close()
        assert(load(code, [[@]] .. filename, [[t]], result))()
        current_path = last_path
    end
    setmetatable(result, { __index = { include = include } })
    include(config_name)
    setmetatable(result, nil)
    return result
end

function M.init()
    local app_config_loaded = skynet.getenv("app_config_loaded")
    if app_config_loaded then
        return
    end

    local app_config_path = skynet.getenv("app_config_path")
    if app_config_path == nil then
        error("app_config_path is nil")
    end
    local ok, result = pcall(load_config, app_config_path)
    if not ok then
        error("load app config failed:" .. result)
    end
    skynet.setenv("app_config_loaded", "true")
    for k, v in pairs(result) do
        if type(v) == "table" then
            skynet.setenv(k, serialize(v))
        else
            skynet.setenv(k, tostring(v))
        end
    end
end

return M
