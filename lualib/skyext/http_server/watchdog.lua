return function(server_name)
    local skynet = require "skynet"
    local service = require "skynet.service"
    local socket = require "skynet.socket"
    local log = require "skyext.log"
    local config = require "skyext.config"
    local agent_main = require "skyext.http_server.agent"
    local cmd_api = require "skyext.cmd_api"
    local limits_mod = require "skyext.http_server.limits"

    assert(type(server_name) == "string" and server_name ~= "", "http watchdog requires a server name")

    local CMD = {}

    local agents = {}
    local started = false
    local listen_info
    local limits
    -- 当前已派给 agent、尚未收到 conn_closed 的连接数
    local active = 0
    local rejected = 0
    local last_reject_log = 0

    -- 节点级默认值。顶层读不到（服务 chunk 先于 config.init 执行），只能到 start 再读。
    local function config_defaults()
        return {
            max_connections = config.get_number("http_max_connections"),
            read_timeout = config.get_number("http_read_timeout"),
            write_timeout = config.get_number("http_write_timeout"),
            keepalive_timeout = config.get_number("http_keepalive_timeout"),
            keepalive_requests = config.get_number("http_keepalive_requests"),
            request_body_size = config.get_number("http_request_body_size"),
        }
    end

    local REJECT_LOG_INTERVAL = 100 -- 1 秒，单位为 skynet 的 1/100 秒

    local function on_accept(id, addr, balance)
        if active >= limits.max_connections then
            rejected = rejected + 1
            -- 直接关闭而不是回 503：回 503 得先把请求读完，正好是被打满时最不该做的事。
            -- 必须用 close_fd：这个 fd 还没 socket.start 过，socket.close 查不到它会直接返回，
            -- fd 就这么泄漏在 C 层，连接上限反而成了 fd 耗尽的加速器。
            socket.close_fd(id)
            -- 日志限流：被打满时每条连接都打一行会把日志通道一起压垮
            local now = skynet.now()
            if now - last_reject_log >= REJECT_LOG_INTERVAL then
                last_reject_log = now
                log.warn(
                    "http connection rejected",
                    "server",
                    server_name,
                    "addr",
                    addr,
                    "active",
                    active,
                    "max",
                    limits.max_connections,
                    "rejected_total",
                    rejected
                )
            end
            return balance
        end
        active = active + 1
        skynet.send(agents[balance], "lua", "socket", "request", id, addr)
        balance = balance + 1
        if balance > #agents then
            balance = 1
        end
        return balance
    end

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

        limits = limits_mod.parse(conf, config_defaults())
        local self_addr = skynet.self()

        -- agent 名字带上实例名，避免不同实例复用同一批 agent 导致路由串台
        for agent_id = 1, agent_count do
            local service_name = string.format("http_agent_%s_%d", server_name, agent_id)
            agents[agent_id] = service.new(service_name, agent_main, server_name, agent_id, limits, self_addr)
        end

        local listen_id, bind_host, bind_port = socket.listen(host, port)
        local balance = 1
        socket.start(listen_id, function(id, addr)
            balance = on_accept(id, addr, balance)
        end)

        started = true
        listen_info = {
            host = bind_host or host,
            port = bind_port or port,
            agent_count = agent_count,
            limits = limits,
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
            agent_count,
            "limits",
            limits
        )
        return listen_info
    end

    -- agent 处理完（含异常收尾）后归还连接额度
    function CMD.conn_closed()
        active = active - 1
        if active < 0 then
            -- 只可能是 agent 重复上报，计数器失真会让上限永远拦不住，必须看得见
            log.error("http active connection underflow", "server", server_name)
            active = 0
        end
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

    function CMD.stats()
        return {
            active = active,
            rejected = rejected,
            max_connections = limits and limits.max_connections,
        }
    end

    skynet.start(function()
        cmd_api.dispatch(CMD)
    end)
end
