local md5 = require "md5"
local util_io = require "util.io"
local util_path = require "util.path"

local M = {}

function M.compute(config, hotfix_dir, root_dir)
    local all_content = {}

    if config.update_files then
        for _, filepath in ipairs(config.update_files) do
            local full_path = util_path.join(root_dir, filepath)
            local content, err = util_io.readfile(full_path)
            if not content then
                return nil, string.format("Update file not readable: %s: %s", filepath, err or "unknown error")
            end
            table.insert(all_content, content)
        end
    end

    if config.code_files then
        for _, filename in ipairs(config.code_files) do
            local full_path = util_path.join(root_dir, hotfix_dir, filename)
            local content, err = util_io.readfile(full_path)
            if not content then
                return nil, string.format("Code file not readable: %s: %s", filename, err or "unknown error")
            end
            table.insert(all_content, content)
        end
    end

    local combined = table.concat(all_content)
    return md5.sumhexa(combined)
end

function M.verify(config, hotfix_dir, root_dir)
    local checksum, err = M.compute(config, hotfix_dir, root_dir)
    if not checksum then
        return false, err
    end

    if checksum ~= config.checksum then
        return false, string.format("Checksum mismatch: expected %s, got %s", config.checksum, checksum)
    end

    return true
end

return M
