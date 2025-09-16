return function()
    local skynet = require "skynet"
    local service = require "skynet.service"
    local socket = require "skynet.socket"
    local log = require "log"
    local agent = require "http_server.agent"
    local cmd_api = require "cmd_api"

    local CMD = {}

    local agents = {}

    function CMD.start(conf)
        local port = conf.port or 8080
        local agent_count = conf.agent_count or 8
        for agent_id = 1, agent_count do
            local service_name = string.format("http_agent_%d", agent_id)
            local agent = service.new(service_name, agent, agent_id)
            agents[agent_id] = agent
        end

        local host = conf.host or "0.0.0.0"
        local balance = 1
        local listen_id = socket.listen(host, port)
        log.info("start http", "host", host, "port", port)
        socket.start(listen_id, function(id, addr)
            skynet.send(agents[balance], "lua", "socket", "request", id, addr)
            balance = balance + 1
            if balance > #agents then
                balance = 1
            end
        end)
    end

    function CMD.register_router(router_name)
        for _, agent in pairs(agents) do
            skynet.send(agent, "lua", "register_router", router_name)
        end
    end

    skynet.start(function()
        cmd_api.dispatch(CMD)
    end)
end
