local skynet = require "skynet"
local socket = require "skynet.socket"

skynet.start(function()
    local listener = socket.listen("127.0.0.1", assert(tonumber(skynet.getenv("fixture_port"))))
    socket.start(listener, function(client)
        socket.start(client)
        socket.close(client)
    end)
end)
