local lfs = require "lfs"

local M = {}
local max_uint32 = 0xffffffff
local crc_table = {}

for n = 0, 255 do
    local crc = n
    for _ = 1, 8 do
        crc = (crc >> 1) ~ ((crc & 1) ~= 0 and 0xedb88320 or 0)
    end
    crc_table[n] = crc
end

local function crc32(crc, data)
    for i = 1, #data do
        crc = (crc >> 8) ~ crc_table[(crc ~ data:byte(i)) & 0xff]
    end
    return crc
end

local function dos_date(timestamp)
    local t = os.date("*t", timestamp)
    local year = math.max(1980, math.min(2107, t.year))
    return ((year - 1980) << 9) | (t.month << 5) | t.day, (t.hour << 11) | (t.min << 5) | (t.sec // 2)
end

local function file_details(path)
    local input, err = io.open(path, "rb")
    assert(input, err)
    local size, crc = 0, 0xffffffff
    while true do
        local chunk = input:read(65536)
        if not chunk then
            break
        end
        size = size + #chunk
        assert(size <= max_uint32, "ZIP file exceeds 4 GiB: " .. path)
        crc = crc32(crc, chunk)
    end
    assert(input:close())
    return size, (crc ~ 0xffffffff) & max_uint32
end

local function copy_file(path, archive)
    local input, err = io.open(path, "rb")
    assert(input, err)
    while true do
        local chunk = input:read(65536)
        if not chunk then
            break
        end
        assert(archive:write(chunk))
    end
    assert(input:close())
end

function M.write(path, entries)
    assert(#entries <= 65535, "ZIP archive has too many entries")
    local archive, err = io.open(path, "wb")
    assert(archive, err)
    local central = {}
    local ok, failure = xpcall(function()
        for _, item in ipairs(entries) do
            local name = item.relative:gsub("\\", "/")
            assert(name ~= "" and name:sub(1, 1) ~= "/", "invalid ZIP path: " .. name)
            for part in name:gmatch("[^/]+") do
                assert(part ~= "." and part ~= "..", "invalid ZIP path: " .. name)
            end
            assert(item.mode == "file" or item.mode == "directory", "unsupported ZIP entry: " .. name)
            if item.mode == "directory" then
                name = name:gsub("/$", "") .. "/"
            end
            local attrs = lfs.attributes(item.path)
            assert(attrs, "cannot stat: " .. item.path)
            local size, crc = 0, 0
            if item.mode == "file" then
                size, crc = file_details(item.path)
            end
            local date, time = dos_date(attrs.modification)
            local offset = assert(archive:seek())
            assert(offset <= max_uint32, "ZIP archive exceeds 4 GiB")
            assert(
                archive:write(
                    string.pack(
                        "<I4I2I2I2I2I2I4I4I4I2I2",
                        0x04034b50,
                        20,
                        0x800,
                        0,
                        time,
                        date,
                        crc,
                        size,
                        size,
                        #name,
                        0
                    )
                )
            )
            assert(archive:write(name))
            if item.mode == "file" then
                copy_file(item.path, archive)
            end
            local perms = attrs.permissions or ""
            local mode = item.mode == "directory" and 0x41ed or (perms:find("x") and 0x81ed or 0x81a4)
            central[#central + 1] = {
                name = name,
                time = time,
                date = date,
                crc = crc,
                size = size,
                offset = offset,
                mode = mode,
            }
        end

        local central_offset = assert(archive:seek())
        for _, item in ipairs(central) do
            assert(
                archive:write(
                    string.pack(
                        "<I4I2I2I2I2I2I2I4I4I4I2I2I2I2I2I4I4",
                        0x02014b50,
                        0x0314,
                        20,
                        0x800,
                        0,
                        item.time,
                        item.date,
                        item.crc,
                        item.size,
                        item.size,
                        #item.name,
                        0,
                        0,
                        0,
                        0,
                        item.mode << 16,
                        item.offset
                    )
                )
            )
            assert(archive:write(item.name))
        end
        local central_size = assert(archive:seek()) - central_offset
        assert(central_offset <= max_uint32 and central_size <= max_uint32, "ZIP archive exceeds 4 GiB")
        assert(
            archive:write(
                string.pack("<I4I2I2I2I2I4I4I2", 0x06054b50, 0, 0, #central, #central, central_size, central_offset, 0)
            )
        )
    end, debug.traceback)
    local closed, close_err = archive:close()
    if not ok or not closed then
        os.remove(path)
        error(failure or close_err, 0)
    end
end

return M
