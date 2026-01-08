local function res_service()
    local skynet = require "skynet"
    local cmd_api = require "cmd_api"
    local lfs = require "lfs"
    local config = require "config"
    local md5 = require "md5"
    local util_io = require "util.io"
    local log = require "log"
    local event_channel_api = require "event_channel_api"
    local gm_api = require "gm_api"
    local sharetable = require "skynet.sharetable"

    local sformat = string.format

    local CMD = {}
    local ref_service = {}
    local preload_loaded = {}
    local lazy_loaded = {}
    local hash_map = {}
    local res_path = config.get("res_path") or "res"
    local res_lazy_path = config.get("res_lazy_path") or "res/lazy"
    local path_sep = package.config:sub(1, 1)

    function CMD.open(source)
        if not ref_service[source] then
            ref_service[source] = true
        end
        return preload_loaded, lazy_loaded
    end

    function CMD.close(source)
        if ref_service[source] then
            ref_service[source] = nil
        end
    end

    local function fetch_res_files(path)
        local files = {} -- name -> filepath
        for file in lfs.dir(path) do
            if file ~= "." and file ~= ".." then
                local f = sformat("%s%s%s", path, path_sep, file)
                local attr = lfs.attributes(f)
                if attr and attr.mode == "file" and file:match("%.lua$") then
                    local name = file:sub(1, -5)
                    files[name] = f
                end
            end
        end
        return files
    end

    local function load_file(name, filepath)
        local content = util_io.readfile(filepath)
        assert(content, "invalid filepath")
        assert(hash_map[name] == nil, "res file already loaded")
        log.debug("load res file", "file", filepath, "content", content)
        local hash = md5.sumhexa(content)
        hash_map[name] = hash
        sharetable.loadstring(name, content)
        log.info("load res file", "file", filepath, "hash", hash)
    end

    local function load_res()
        local res_preload = fetch_res_files(res_path)
        for name, filepath in pairs(res_preload) do
            load_file(name, filepath)
            preload_loaded[name] = true
        end

        local res_lazy = fetch_res_files(res_lazy_path)
        for name, filepath in pairs(res_lazy) do
            load_file(name, filepath)
            lazy_loaded[name] = true
        end
    end

    local function do_reload_res(res_files)
        local name2info = {}
        for name, filepath in pairs(res_files) do
            local content = util_io.readfile(filepath)
            assert(content, "invalid path")
            local hash = md5.sumhexa(content)
            -- 有差异或者新增才加载
            if hash_map[name] ~= hash then
                name2info[name] = {
                    content = content,
                    hash = hash,
                    filepath = filepath,
                }
            end
        end
        if not next(name2info) then
            return true, "no diff res file need to reload"
        end
        local res_list = {}
        for name, info in pairs(name2info) do
            sharetable.loadstring(name, info.content)
            hash_map[name] = info.hash
            res_list[name] = true
            log.info("reload res file", "file", info.filepath, "hash", info.hash)
        end
        event_channel_api.publish("res_reload", res_list)
        return true, "res file reload success"
    end

    local GM_CMD = {}
    GM_CMD.reload_res = {
        desc = "重载 res",
        params = { filepaths = "文件路径列表" },
        handler = function(params)
            local filepaths = params.filepaths
            local res_files = {}
            if filepaths then
                for _, filepath in ipairs(filepaths) do
                    local name = filepath:match("([^/\\]+)%.lua$")
                    res_files[name] = filepath
                end
            else
                local res_preload = fetch_res_files(res_path)
                local res_lazy = fetch_res_files(res_lazy_path)
                for name, filepath in pairs(res_preload) do
                    res_files[name] = filepath
                end
                for name, filepath in pairs(res_lazy) do
                    res_files[name] = filepath
                end
            end
            if next(res_files) then
                return do_reload_res(res_files)
            else
                return true, "no res file need to reload"
            end
        end,
    }

    skynet.start(function()
        event_channel_api.init()
        load_res()
        gm_api.register(GM_CMD)
        cmd_api.dispatch(CMD)
    end)
end

local skynet = require "skynet"
local service = require "skynet.service"
local sharetable = require "skynet.sharetable"
local log = require "log"
local event_channel_api = require "event_channel_api"

local g_service_addr = nil
local res_table = {} -- filename -> res content
local preload_loaded = nil
local lazy_loaded = nil

setmetatable(res_table, {
    __index = function(t, name)
        if lazy_loaded[name] then
            res_table[name] = sharetable.query(name)
            log.info("load lazy res", "name", name)
            return res_table[name]
        end
    end,
})

local function on_res_reload(res_list)
    for name, _ in pairs(res_list) do
        -- 只有加载过的才重载
        if res_table[name] then
            res_table[name] = sharetable.query(name)
            log.info("reload res", "name", name)
        end
        if (not lazy_loaded[name]) and not preload_loaded[name] then
            -- 新增资源放到 lazy_loaded
            lazy_loaded[name] = true
        end
    end
end

skynet.init(function()
    g_service_addr = service.new("res", res_service)
    preload_loaded, lazy_loaded = skynet.call(g_service_addr, "lua", "open", skynet.self())
    for name, _ in pairs(preload_loaded) do
        res_table[name] = sharetable.query(name)
        log.debug("load init", "name", name, "content", res_table[name])
    end
    event_channel_api.subscribe(g_service_addr, "res_reload", on_res_reload)
end)

local M = {}
setmetatable(M, {
    __index = res_table,
    __gc = function()
        skynet.send(g_service_addr, "lua", "close", skynet.self())
    end,
})

return M
