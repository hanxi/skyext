-- 扩展skynet功能
local skynet = require "skynet.manager"

-- 提前 require sharetable 是为了保证 next 不用下面的next
require "skynet.sharetable"

-- for orm serialize
local old_next = next
_G.next = function(t, i)
    local mt = getmetatable(t)
    if mt and mt.__next then
        return mt.__next(old_next, t, i)
    end
    return old_next(t, i)
end
_G.rawnext = old_next

-- for orm operation
local old_table_unpack = table.unpack
table.unpack = function(t, i, j)
    local mt = getmetatable(t)
    if mt and mt.__unpack then
        return mt.__unpack(t, i, j)
    end
    return old_table_unpack(t, i, j)
end

local old_table_concat = table.concat
table.concat = function(t, sep, i, j)
    local mt = getmetatable(t)
    if mt and mt.__concat then
        return mt.__concat(t, sep, i, j)
    end
    return old_table_concat(t, sep, i, j)
end

local old_table_insert = table.insert
table.insert = function(t, i, v)
    local mt = getmetatable(t)
    if mt and mt.__insert then
        return mt.__insert(t, i, v)
    end
    if v == nil then
        return old_table_insert(t, i)
    else
        return old_table_insert(t, i, v)
    end
end

local old_table_remove = table.remove
table.rmove = function(t, i)
    local mt = getmetatable(t)
    if mt and mt.__remove then
        return mt.__remove(t, i)
    end
    return old_table_remove(t, i)
end

skynet.init(function()
    local ok, config = pcall(require, "config")
    if not ok then
        error("load config module failed" .. config)
    end
    local ok, err = pcall(config.init)
    if not ok then
        error("init config module failed" .. err)
    end

    -- 覆盖 assert error
    local ok, log = pcall(require, "log")
    if not ok then
        error("load log module failed" .. log)
    end
    local ok, err = pcall(log.init)
    if not ok then
        error("init log module failed" .. err)
    end
end)
