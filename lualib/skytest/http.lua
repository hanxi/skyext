local httpc = require "http.httpc"
local cjson = require "cjson.safe"

local M = {}

function M.get(host, path)
    return httpc.request("GET", host, path)
end

function M.get_json(host, path)
    local status, body = httpc.request("GET", host, path)
    if body then
        body = cjson.decode(body)
    end
    return status, body
end

function M.post(host, path, data, content_type)
    local header = {}
    if content_type then
        header["content-type"] = content_type
    end
    return httpc.request("POST", host, path, nil, header, data)
end

function M.post_json(host, path, tbl)
    local header = {
        ["content-type"] = "application/json",
    }
    local status, body = httpc.request("POST", host, path, nil, header, cjson.encode(tbl))
    if body then
        body = cjson.decode(body)
    end
    return status, body
end

function M.request(method, host, path, opts)
    opts = opts or {}
    local header = {}
    local body = opts.body

    if opts.headers then
        for k, v in pairs(opts.headers) do
            header[k] = v
        end
    end

    if opts.json then
        header["content-type"] = "application/json"
        body = cjson.encode(opts.json)
    end

    if opts.timeout then
        httpc.timeout = opts.timeout * 100
    end

    local recvheader = {}
    local status, resp = httpc.request(method, host, path, recvheader, header, body)

    if opts.timeout then
        httpc.timeout = nil
    end

    if opts.json or (recvheader["content-type"] and recvheader["content-type"]:find("application/json", 1, true)) then
        if resp then
            resp = cjson.decode(resp)
        end
    end

    return status, resp
end

return M
