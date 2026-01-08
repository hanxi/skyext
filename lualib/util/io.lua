local M = {}

---读文件内容，以二进制格式读取
---@param file string 文件名
---@return string 文件内容
function M.readfile(file)
    local fh, err = io.open(file, "rb")
    if not fh then
        return nil, err
    end

    local data = fh:read("*a")
    fh:close()
    return data
end

---写文件内容
---@param file string 文件名
---@param data string 写入的文件内容
---@return boolean 是否成功
function M.writefile(file, data)
    local fh = io.open(file, "w+b")
    if not fh then
        return false
    end
    fh:write(data)
    fh:close()
    return true
end

return M
