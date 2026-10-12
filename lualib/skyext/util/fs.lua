local lfs = require "lfs"

local M = {}
local sep = package.config:sub(1, 1)

local function native(path)
    return (path:gsub("[/\\]", sep))
end

function M.join(...)
    local parts = { ... }
    local path = ""
    for _, part in ipairs(parts) do
        if part ~= "" then
            part = native(part)
            if path == "" or part:match("^[/\\]") or part:match("^%a:[/\\]") then
                path = part
            else
                path = path:gsub("[/\\]$", "") .. sep .. part
            end
        end
    end
    return path
end

function M.absolute(path)
    path = native(path)
    if path:match("^[/\\]") or path:match("^%a:[/\\]") then
        return path
    end
    return M.join(lfs.currentdir(), path)
end

function M.mode(path)
    return lfs.symlinkattributes(path, "mode")
end

function M.mkdir(path)
    path = native(path)
    local mode = M.mode(path)
    if mode then
        assert(mode == "directory", "not a directory: " .. path)
        return
    end
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent and parent ~= "" and parent ~= path then
        if parent:match("^%a:$") then
            assert(M.mode(parent .. sep) == "directory", "drive not found: " .. parent)
        else
            M.mkdir(parent)
        end
    end
    local ok, err = lfs.mkdir(path)
    assert(ok or M.mode(path) == "directory", err or ("cannot create directory: " .. path))
end

function M.entries(path)
    local items = {}
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            items[#items + 1] = name
        end
    end
    table.sort(items)
    return items
end

function M.walk(root, accept)
    local items = {}
    local function visit(dir, prefix)
        for _, name in ipairs(M.entries(dir)) do
            local relative = prefix == "" and name or prefix .. "/" .. name
            local path = M.join(dir, name)
            local mode = M.mode(path)
            if not accept or accept(relative, mode) then
                if mode == "link" then
                    local target = lfs.symlinkattributes(path, "target")
                    assert(target and not target:find("[/\\]"), "symlink outside its directory: " .. path)
                    assert(M.mode(M.join(dir, target)) == "file", "symlink target is not a regular file: " .. path)
                    mode = "file"
                end
                assert(mode == "file" or mode == "directory", "unsupported file type: " .. path)
                items[#items + 1] = { path = path, relative = relative, mode = mode }
                if mode == "directory" then
                    visit(path, relative)
                end
            end
        end
    end
    visit(root, "")
    return items
end

function M.read(path)
    local file, err = io.open(path, "rb")
    assert(file, err)
    local data = assert(file:read("*a"))
    assert(file:close())
    return data
end

function M.write(path, data)
    M.mkdir(path:match("^(.*)[/\\][^/\\]+$") or ".")
    local file, err = io.open(path, "wb")
    assert(file, err)
    assert(file:write(data))
    assert(file:close())
end

function M.copy(source, target)
    M.mkdir(target:match("^(.*)[/\\][^/\\]+$") or ".")
    local input, err = io.open(source, "rb")
    assert(input, err)
    local output, output_err = io.open(target, "wb")
    assert(output, output_err)
    while true do
        local chunk = input:read(65536)
        if not chunk then
            break
        end
        assert(output:write(chunk))
    end
    assert(input:close())
    assert(output:close())
end

function M.copy_tree(source, target, accept)
    assert(M.mode(source) == "directory", "not a directory: " .. source)
    M.mkdir(target)
    for _, item in ipairs(M.walk(source, accept)) do
        local dest = M.join(target, item.relative)
        if item.mode == "directory" then
            M.mkdir(dest)
        else
            M.copy(item.path, dest)
        end
    end
end

function M.remove_tree(path)
    local mode = M.mode(path)
    if mode == "directory" then
        for _, name in ipairs(M.entries(path)) do
            M.remove_tree(M.join(path, name))
        end
        assert(lfs.rmdir(path))
    elseif mode then
        assert(os.remove(path))
    end
end

function M.temporary_dir(base)
    base = base or os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or lfs.currentdir()
    for _ = 1, 100 do
        local name = string.format("skyext-%d-%d", os.time(), math.random(1, 2147483647))
        local path = M.join(base, name)
        local ok = lfs.mkdir(path)
        if ok then
            return path
        end
    end
    error("cannot create a temporary directory in " .. base)
end

function M.with_dir(path, fn)
    local previous = lfs.currentdir()
    assert(lfs.chdir(path))
    local results = table.pack(xpcall(fn, debug.traceback))
    assert(lfs.chdir(previous))
    if not results[1] then
        error(results[2], 0)
    end
    return table.unpack(results, 2, results.n)
end

return M
