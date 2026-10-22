return function(server_name, agent_id, limits, watchdog)
    local skynet = require "skynet"
    local socket = require "skynet.socket"
    local sockethelper = require "http.sockethelper"
    local cmd_api = require "skyext.cmd_api"
    local log = require "skyext.log"
    local httpd = require "http.httpd"
    local cjson = require "cjson.safe"
    local urllib = require "http.url"
    local util_io = require "skyext.util.io"
    local deadline = require "skyext.http_server.deadline"

    local xpcall_msgh = log.xpcall_msgh
    local decode_json = cjson.decode
    local encode_json = cjson.encode

    local CMD = {}
    local SOCKET = {}

    local routers = {} -- method -> path -> handler

    local deadline_deps = {
        now = skynet.now,
        sleep = skynet.sleep,
        wakeup = skynet.wakeup,
        fork = skynet.fork,
        shutdown = socket.shutdown,
    }

    local BASE_HEADER = {
        ["X-Powered-By"] = "skyext framework",
        ["Access-Control-Allow-Origin"] = "*",
        ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type,Authorization,x-token",
        ["Access-Control-Allow-Credentials"] = "true",
    }

    -- 这些状态码按 RFC 7230 定义为不带 body，也就不能带 content-length；
    -- 客户端不会去找 body，keep-alive 的分帧照样成立
    local function bodiless(statuscode)
        return statuscode == 204 or statuscode == 304 or (statuscode >= 100 and statuscode < 200)
    end

    local function send_response(conn, statuscode, body, header)
        if conn.responded then
            -- 一个请求写两次响应会直接把 keep-alive 的字节流写乱，后续请求全部解析错位
            log.error("http handler wrote a second response", "id", conn.id, "status", statuscode)
            return false
        end
        local out = {}
        if header then
            for k, v in pairs(header) do
                out[k] = v
            end
        end
        for k, v in pairs(BASE_HEADER) do
            out[k] = v
        end
        -- keep-alive 下每个响应都必须有确定长度，否则客户端无从判断 body 到哪里结束。
        -- httpd 在 body 为 nil 时 content-length 和 chunked 都不写，这里补成空串。
        if body == nil and not bodiless(statuscode) then
            body = ""
        end
        out["connection"] = conn.keepalive and "keep-alive" or "close"
        conn.responded = true
        conn.guard:set(conn.limits.write_timeout, "write")
        local ok, err = httpd.write_response(conn.write, statuscode, body, out)
        if not ok then
            -- 写不出去说明对端已经走了或者被写超时掐了，连接不能再复用
            conn.keepalive = false
            log.debug("response failed", "id", conn.id, "status", statuscode, "err", tostring(err))
        end
        return ok
    end

    local function keepalive_allowed(conn, header)
        if conn.limits.keepalive_timeout <= 0 then
            return false
        end
        if conn.served >= conn.limits.keepalive_requests then
            return false
        end
        local connection = header and header["connection"]
        if connection and connection:lower():find("close", 1, true) then
            return false
        end
        -- httpd.read_request 不回传 HTTP 版本号，无法区分 1.0 / 1.1。
        -- 这里一律按可复用处理，并在响应里显式写 connection 头：
        -- 不认 keep-alive 的 1.0 客户端自己会关，代价只是多挂一个空闲超时。
        return true
    end

    local function build_request(conn, url, method, header, body)
        local path, query = urllib.parse(url)
        return {
            id = conn.id,
            addr = conn.addr,
            url = url,
            method = method,
            path = path,
            query = query,
            header = header,
            body = body,
            parse_query = function()
                return urllib.parse_query(query)
            end,
            -- 返回 table，或 nil, reason。空 body、坏 JSON、以及 JSON 标量都归为失败：
            -- 直接索引解析结果是路由里最容易漏掉的一步，让它返回 nil 而不是让调用方
            -- 自己去判断类型，漏判就会在 handler 里抛错
            read_json = function()
                if body == nil or body == "" then
                    return nil, "empty body"
                end
                local decoded = decode_json(body)
                if type(decoded) ~= "table" then
                    return nil, "body is not a json object"
                end
                return decoded
            end,
        },
            path
    end

    local function build_response(conn)
        local res = { header = {} }
        res.write = function(statuscode, body, header)
            header = header or res.header
            return send_response(conn, statuscode, body, header)
        end
        res.write_json = function(data, header)
            header = header or res.header
            header["content-type"] = "application/json"
            return send_response(conn, 200, encode_json(data), header)
        end
        res.write_file = function(filename, header)
            header = header or res.header
            -- TODO: cache file by timestamp
            local content = util_io.readfile(filename)
            if not content then
                log.warn("http file not found", "id", conn.id, "file", filename)
                return send_response(conn, 404)
            end
            return send_response(conn, 200, content, header)
        end
        return res
    end

    -- 处理一个请求；返回 true 表示连接可以继续服务下一个请求
    local function serve_once(conn)
        local first = conn.served == 0
        conn.reading = false
        conn.responded = false
        -- 首个请求从 accept 起算读取时限；keep-alive 的后续请求先按空闲时限等，
        -- 首字节到达后由 conn.read 切换到读取时限（见 make_read）
        if first then
            conn.guard:set(conn.limits.read_timeout, "read")
        else
            conn.guard:set(conn.limits.keepalive_timeout, "keepalive")
        end

        local code, url, method, header, body = httpd.read_request(conn.read, conn.limits.request_body_size)
        if not code then
            local reason = conn.guard:expired_reason()
            if reason then
                log.warn("http connection timeout", "id", conn.id, "addr", conn.addr, "phase", reason)
            elseif not conn.reading then
                -- 空闲中对端主动关闭 keep-alive 连接是正常收尾，不值得 warn
                log.debug("connection closed by peer", "id", conn.id, "addr", conn.addr)
            else
                log.info("read request failed", "id", conn.id, "addr", conn.addr, "err", tostring(url))
            end
            return false
        end

        conn.served = conn.served + 1
        conn.keepalive = keepalive_allowed(conn, header)

        if code ~= 200 then
            -- 请求读取阶段就失败（400/413/505 等），缓冲区里剩了什么无从得知，
            -- 复用连接只会把下一个请求也解析错，必须关掉
            conn.keepalive = false
            send_response(conn, code)
            return false
        end

        if method == "OPTIONS" then
            send_response(conn, 204)
            return conn.keepalive
        end

        local method_routers = routers[method]
        if not method_routers then
            send_response(conn, 405)
            return conn.keepalive
        end

        local req, path = build_request(conn, url, method, header, body)
        local handler = method_routers[path]
        if not handler then
            log.warn("handle_request not found", "id", conn.id, "addr", conn.addr, "method", method, "path", path)
            send_response(conn, 404)
            return conn.keepalive
        end

        local res = build_response(conn)
        -- handler 抛错必须回 500。放任它冒到 serve_connection 的 xpcall 去，连接会被直接
        -- 关掉而一个字节都不回，客户端只能等到自己超时——比 500 更难排查
        local handled, handler_err = xpcall(handler, xpcall_msgh, req, res)
        if not handled then
            log.error("http handler failed", "method", method, "path", path, "id", conn.id, "err", handler_err)
            -- 已经写过响应再出错，剩下的字节无从得知，连接不能再复用
            conn.keepalive = false
            send_response(conn, 500)
            return false
        end
        if not conn.responded then
            -- 路由没写响应，keep-alive 下客户端会一直等到自己超时，这里兜底
            log.error("http handler wrote no response", "method", method, "path", path, "id", conn.id)
            conn.keepalive = false
            send_response(conn, 500)
            return false
        end
        return conn.keepalive
    end

    local function make_read(conn)
        local raw = sockethelper.readfunc(conn.id)
        return function(sz)
            local data = raw(sz)
            if not conn.reading then
                conn.reading = true
                -- 首字节到了就从空闲时限切到读取时限：长空闲的 keep-alive 不该被当成攻击，
                -- 而逐字节发送的慢攻击也拿不到空闲时限来续命（读取时限是绝对的，不续期）
                conn.guard:set(conn.limits.read_timeout, "read")
            end
            return data
        end
    end

    local function serve_connection(conn)
        -- 注意：不支持 HTTP 流水线（pipelining）。httpd.read_request 会丢弃
        -- 超出 content-length 的预读数据，同一个包里的第二个请求拿不回来。
        -- 浏览器早已默认关闭流水线，这里以 keep-alive 串行复用为准。
        local keep = true
        while keep do
            local ok, result = xpcall(serve_once, xpcall_msgh, conn)
            if not ok then
                log.warn("request failed", "id", conn.id, "addr", conn.addr, "err", result)
                return
            end
            keep = result
        end
    end

    function SOCKET.request(id, addr)
        log.debug("request", "id", id, "addr", addr)
        socket.start(id)

        local conn = {
            id = id,
            addr = addr,
            limits = limits,
            served = 0,
            keepalive = false,
            guard = deadline.new(id, deadline_deps),
        }
        conn.read = make_read(conn)
        conn.write = sockethelper.writefunc(id)

        serve_connection(conn)

        conn.guard:cancel()
        socket.close(id)
        -- 必须无条件归还额度，否则连接数上限会随着异常连接单调逼近 0
        skynet.send(watchdog, "lua", "conn_closed")
        log.debug("request end", "id", id, "addr", addr, "served", conn.served)
    end

    function CMD.register_router(router_name)
        local router = require(router_name)
        assert(type(router) == "table", "invalid router module: " .. router_name)
        for method, handlers in pairs(router) do
            for path, handler in pairs(handlers) do
                local method_routers = routers[method]
                if not method_routers then
                    method_routers = {}
                    routers[method] = method_routers
                end
                method_routers[path] = handler
            end
        end
        log.info("http agent router registered", "server", server_name, "agent_id", agent_id, "router", router_name)
        return true
    end

    skynet.start(function()
        cmd_api.dispatch_socket(CMD, SOCKET)
        log.info("http agent start", "server", server_name, "agent_id", agent_id)
    end)
end
