local skynet = require "skynet"
local gm_api = require "gm_api"
local cmd_api = require "cmd_api"
local core = require "skynet.core"
local snax = require "skynet.snax"
local memory = require "skynet.memory"
local socket = require "skynet.socket"

local GM_CMD = {}
local TIMEOUT = 300 -- 3 sec

local function adjust_address(address)
    local prefix = address:sub(1, 1)
    if prefix == "." then
        return assert(skynet.localname(address), "Not a valid name")
    elseif prefix ~= ":" then
        address = assert(tonumber("0x" .. address), "Need an address") | (skynet.harbor(skynet.self()) << 24)
    end
    return address
end

local function timeout(ti)
    if ti then
        ti = tonumber(ti)
        if ti <= 0 then
            ti = nil
        end
    else
        ti = TIMEOUT
    end
    return ti
end

local function bytes(size)
    if size == nil or size == 0 then
        return
    end
    if size < 1024 then
        return size
    end
    if size < 1024 * 1024 then
        return tostring(size / 1024) .. "K"
    end
    return tostring(size / (1024 * 1024)) .. "M"
end

local function convert_stat(info)
    local now = skynet.now()
    local function time(t)
        if t == nil then
            return
        end
        t = now - t
        if t < 6000 then
            return tostring(t / 100) .. "s"
        end
        local hour = t // (100 * 60 * 60)
        t = t - hour * 100 * 60 * 60
        local min = t // (100 * 60)
        t = t - min * 100 * 60
        local sec = t / 100
        return string.format("%s%d:%.2gs", hour == 0 and "" or (hour .. ":"), min, sec)
    end

    info.address = skynet.address(info.address)
    info.read = bytes(info.read)
    info.write = bytes(info.write)
    info.wbuffer = bytes(info.wbuffer)
    info.rtime = time(info.rtime)
    info.wtime = time(info.wtime)
end

GM_CMD.list = {
    desc = "List all the service",
    handler = function()
        return true, skynet.call(".launcher", "lua", "LIST")
    end,
}

GM_CMD.stat = {
    desc = "Dump all stats",
    params = {
        timeout = "timeout in seconds (optional)",
    },
    handler = function(params)
        return true, skynet.call(".launcher", "lua", "STAT", timeout(params.timeout))
    end,
}

GM_CMD.mem = {
    desc = "Show memory status",
    params = {
        timeout = "timeout in seconds (optional)",
    },
    handler = function(params)
        return true, skynet.call(".launcher", "lua", "MEM", timeout(params.timeout))
    end,
}

GM_CMD.kill = {
    desc = "kill address : kill service",
    params = {
        address = "service address",
    },
    handler = function(params)
        return true, skynet.call(".launcher", "lua", "KILL", adjust_address(params.address))
    end,
}

GM_CMD.gc = {
    desc = "Force every lua service do garbage collect",
    params = {
        timeout = "timeout in seconds (optional)",
    },
    handler = function(params)
        return true, skynet.call(".launcher", "lua", "GC", timeout(params.timeout))
    end,
}

GM_CMD.exit = {
    desc = "Exit a lua service",
    params = {
        address = "service address",
    },
    handler = function(params)
        skynet.send(adjust_address(params.address), "debug", "EXIT")
        return true, "Exit command sent"
    end,
}

GM_CMD.clearcache = {
    desc = "Clear lua code cache",
    handler = function()
        skynet.cache.clear()
        return true, "Code cache cleared"
    end,
}

GM_CMD.start = {
    desc = "Launch a new lua service",
    params = {
        service = "service name",
        args = "service arguments (optional)",
    },
    handler = function(params)
        local ok, addr = pcall(skynet.newservice, params.service, params.args)
        if ok then
            if addr then
                return true, { [skynet.address(addr)] = params.service }
            else
                return false, "Exit"
            end
        else
            return false, "Failed to start service"
        end
    end,
}

GM_CMD.log = {
    desc = "Launch a new lua service with log",
    params = {
        service = "service name",
        args = "service arguments (optional)",
    },
    handler = function(params)
        local ok, addr = pcall(skynet.call, ".launcher", "lua", "LOGLAUNCH", "snlua", params.service, params.args)
        if ok then
            if addr then
                return true, { [skynet.address(addr)] = params.service }
            else
                return false, "Failed"
            end
        else
            return false, "Failed to launch service with log"
        end
    end,
}

GM_CMD.snax = {
    desc = "Launch a new snax service",
    params = {
        service = "snax service name",
        args = "service arguments (optional)",
    },
    handler = function(params)
        local ok, s = pcall(snax.newservice, params.service, params.args)
        if ok then
            local addr = s.handle
            return true, { [skynet.address(addr)] = params.service }
        else
            return false, "Failed to start snax service"
        end
    end,
}

GM_CMD.service = {
    desc = "List unique service",
    handler = function()
        return true, skynet.call("SERVICE", "lua", "LIST")
    end,
}

GM_CMD.inject = {
    desc = "Inject lua script to service",
    params = {
        address = "service address",
        filename = "lua script filename",
        args = "script arguments (optional)",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        local f = io.open(params.filename, "rb")
        if not f then
            return false, "Can't open " .. params.filename
        end
        local source = f:read("*a")
        f:close()
        local ok, output = skynet.call(address, "debug", "RUN", source, params.filename, params.args)
        if ok == false then
            return false, output
        end
        return true, output
    end,
}

GM_CMD.dbgcmd = {
    desc = "Run service debug command",
    params = {
        address = "service address",
        cmd = "debug command",
        args = "command arguments (optional)",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        return true, skynet.call(address, "debug", params.cmd, params.args)
    end,
}

GM_CMD.task = {
    desc = "Show service task detail",
    params = {
        address = "service address",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        return true, skynet.call(address, "debug", "TASK")
    end,
}

GM_CMD.killtask = {
    desc = "Kill service task thread",
    params = {
        address = "service address",
        threadname = "thread name",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        return true, skynet.call(address, "debug", "KILLTASK", params.threadname)
    end,
}

GM_CMD.uniqtask = {
    desc = "Show service unique task detail",
    params = {
        address = "service address",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        return true, skynet.call(address, "debug", "UNIQTASK")
    end,
}

GM_CMD.info = {
    desc = "Get service information",
    params = {
        address = "service address",
        args = "info arguments (optional)",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        return true, skynet.call(address, "debug", "INFO", params.args)
    end,
}

GM_CMD.logon = {
    desc = "Enable log for service",
    params = {
        address = "service address",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        core.command("LOGON", skynet.address(address))
        return true, "Log enabled"
    end,
}

GM_CMD.logoff = {
    desc = "Disable log for service",
    params = {
        address = "service address",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        core.command("LOGOFF", skynet.address(address))
        return true, "Log disabled"
    end,
}

GM_CMD.signal = {
    desc = "Send signal to service",
    params = {
        address = "service address",
        sig = "signal number (optional)",
    },
    handler = function(params)
        local address = skynet.address(adjust_address(params.address))
        if params.sig then
            core.command("SIGNAL", string.format("%s %d", address, params.sig))
        else
            core.command("SIGNAL", address)
        end
        return true, "Signal sent"
    end,
}

GM_CMD.cmem = {
    desc = "Show C memory info",
    handler = function()
        local info = memory.info()
        local tmp = {}
        for k, v in pairs(info) do
            tmp[skynet.address(k)] = v
        end
        tmp.total = memory.total()
        tmp.block = memory.block()
        return true, tmp
    end,
}

GM_CMD.jmem = {
    desc = "Show jemalloc mem stats",
    handler = function()
        local info = memory.jestat()
        local tmp = {}
        for k, v in pairs(info) do
            tmp[k] = string.format("%11d  %8.2f Mb", v, v / 1048576)
        end
        return true, tmp
    end,
}

GM_CMD.ping = {
    desc = "Ping service",
    params = {
        address = "service address",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        local ti = skynet.now()
        skynet.call(address, "debug", "PING")
        ti = skynet.now() - ti
        return true, tostring(ti)
    end,
}

GM_CMD.trace = {
    desc = "Trace service protocol",
    params = {
        address = "service address",
        proto = "protocol name or on/off",
        flag = "on/off (optional)",
    },
    handler = function(params)
        local address = adjust_address(params.address)
        local proto = params.proto
        local flag = params.flag

        local function toboolean(x)
            return x and (x == "true" or x == "on")
        end

        if flag == nil then
            if proto == "on" or proto == "off" then
                proto = toboolean(proto)
            end
        else
            flag = toboolean(flag)
        end
        skynet.call(address, "debug", "TRACELOG", proto, flag)
        return true, "Trace command sent"
    end,
}

GM_CMD.netstat = {
    desc = "Show network statistics",
    handler = function()
        local stat = socket.netstat()
        for _, info in ipairs(stat) do
            convert_stat(info)
        end
        return true, stat
    end,
}

GM_CMD.dumpheap = {
    desc = "Dump heap profiling",
    handler = function()
        memory.dumpheap()
        return true, "Heap dump completed"
    end,
}

GM_CMD.profactive = {
    desc = "Active/deactive jemalloc heap profiling",
    params = {
        flag = "on/off (optional)",
    },
    handler = function(params)
        local flag = params.flag
        if flag ~= nil then
            local function toboolean(x)
                return x and (x == "true" or x == "on")
            end
            if flag == "on" or flag == "off" then
                flag = toboolean(flag)
            end
            memory.profactive(flag)
        end
        local active = memory.profactive()
        return true, "heap profiling is " .. (active and "active" or "deactive")
    end,
}

GM_CMD.getenv = {
    desc = "Get skynet environment variable",
    params = {
        name = "environment variable name",
    },
    handler = function(params)
        local value = skynet.getenv(params.name)
        return true, { [params.name] = tostring(value) }
    end,
}

GM_CMD.setenv = {
    desc = "Set skynet environment variable",
    params = {
        name = "environment variable name",
        value = "environment variable value",
    },
    handler = function(params)
        skynet.setenv(params.name, params.value)
        return true, "Environment variable set"
    end,
}

skynet.start(function()
    gm_api.register(GM_CMD)
    cmd_api.dispatch({})
end)
