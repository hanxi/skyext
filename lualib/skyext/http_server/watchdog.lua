return function(server_name)
    local skynet = require "skynet"
    local service = require "skynet.service"
    local socket = require "skynet.socket"
    local log = require "skyext.log"
    local agent_main = require "skyext.http_server.agent"
    local cmd_api = require "skyext.cmd_api"

    assert(type(server_name) == "string" and server_name ~= "", "http watchdog requires a server name")

    local CMD = {}

    local agents = {}
    local started = false
    local listen_info

    function CMD.start(conf)
        if started then
            error(string.format("http server already started: %s", server_name))
        end
        conf = conf or {}

        local port = tonumber(conf.port) or 8080
        assert(port >= 0 and port < 65536, "invalid http port: " .. tostring(conf.port))
        local agent_count = math.tointeger(tonumber(conf.agent_count) or 8)
        assert(agent_count and agent_count > 0, "invalid http agent_count: " .. tostring(conf.agent_count))
        local host = conf.host or "0.0.0.0"

        -- agent 名字带上实例名，避免不同实例复用同一批 agent 导致路由串台
        for agent_id = 1, agent_count do
            local service_name = string.format("http_agent_%s_%d", server_name, agent_id)
            agents[agent_id] = service.new(service_name, agent_main, server_name, agent_id)
        end

        local listen_id, bind_host, bind_port = socket.listen(host, port)
        local balance = 1
        socket.start(listen_id, function(id, addr)
            skynet.send(agents[balance], "lua", "socket", "request", id, addr)
            balance = balance + 1
            if balance > #agents then
                balance = 1
            end
        end)

        started = true
        listen_info = {
            host = bind_host or host,
            port = bind_port or port,
            agent_count = agent_count,
        }
        log.info(
            "start http",
            "server",
            server_name,
            "host",
            listen_info.host,
            "port",
            listen_info.port,
            "agent_count",
            agent_count
        )
        return listen_info
    end

    -- 同步注册到所有 agent，返回时路由已全部生效
    function CMD.register_router(router_name)
        assert(started, string.format("http server not started: %s", server_name))
        for _, agent in ipairs(agents) do
            skynet.call(agent, "lua", "register_router", router_name)
        end
        log.info("http router registered", "server", server_name, "router", router_name)
        return true
    end

    function CMD.info()
        return listen_info
    end

    skynet.start(function()
        cmd_api.dispatch(CMD)
    end)
end
