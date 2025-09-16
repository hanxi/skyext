local httpc = require "http.httpc"
local cjson = require "cjson.safe"

function httpc.post_json(host, url, data, recvheader)
	local header = {
		["content-type"] = "application/json",
	}
    local status, body = httpc.request("POST", host, url, recvheader, header, cjson.encode(data))
    if status == 200 then
        return status, cjson.decode(body)
    end
    return status, body
end


return httpc
