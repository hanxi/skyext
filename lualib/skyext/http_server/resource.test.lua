local t = require "skytest"
local skynet = require "skynet"
local socket = require "skynet.socket"
local http_server = require "skyext.http_server"

local PUBLIC_ROUTER = "skyext.http_server.fixtures.public_router"

local function connect(port)
    return assert(socket.open("127.0.0.1", port), "connect failed")
end

local function request_text(path, opts)
    opts = opts or {}
    local lines = {
        string.format("%s %s HTTP/1.1", opts.method or "GET", path),
        "host: 127.0.0.1",
    }
    if opts.connection then
        lines[#lines + 1] = "connection: " .. opts.connection
    end
    if opts.body then
        lines[#lines + 1] = "content-type: application/json"
        lines[#lines + 1] = "content-length: " .. #opts.body
    end
    return table.concat(lines, "\r\n") .. "\r\n\r\n" .. (opts.body or "")
end

-- 读一个完整响应；连接被关掉时返回 nil
local function read_response(fd)
    local buf = ""
    local head_end
    while true do
        head_end = buf:find("\r\n\r\n", 1, true)
        if head_end then
            break
        end
        local chunk = socket.read(fd)
        if not chunk then
            return nil
        end
        buf = buf .. chunk
    end
    local head = buf:sub(1, head_end - 1)
    local body = buf:sub(head_end + 4)
    local status = tonumber(head:match("^HTTP/1%.1 (%d+)"))
    local headers = {}
    for k, v in head:gmatch("\r\n([%w%-_]+):%s*([^\r\n]*)") do
        headers[k:lower()] = v
    end
    local len = tonumber(headers["content-length"])
    if len then
        while #body < len do
            local chunk = socket.read(fd)
            if not chunk then
                return nil
            end
            body = body .. chunk
        end
        body = body:sub(1, len)
    end
    return status, headers, body
end

-- 等服务端关闭连接。超过 max_sec 就自己掐断并返回 false，
-- 这样实现退化时是测试失败，而不是整个测试套挂死。
local function wait_closed(fd, max_sec)
    local done = false
    local timed_out = false
    skynet.fork(function()
        for _ = 1, max_sec * 10 do
            skynet.sleep(10)
            if done then
                return
            end
        end
        timed_out = true
        socket.shutdown(fd)
    end)
    while true do
        if not socket.read(fd) then
            done = true
            return not timed_out
        end
    end
end

t.describe("http 资源上限", function()
    local main_port, cap_port, cap_server

    t.before_all(function()
        local main = http_server.new("rtest_main")
        main_port = main:start({
            host = "127.0.0.1",
            port = 0,
            agent_count = 2,
            read_timeout = 1,
            keepalive_timeout = 1,
            keepalive_requests = 3,
            request_body_size = 64,
        }).port
        main:register_router(PUBLIC_ROUTER)

        cap_server = http_server.new("rtest_cap")
        cap_port = cap_server:start({
            host = "127.0.0.1",
            port = 0,
            agent_count = 1,
            max_connections = 2,
            read_timeout = 3,
            keepalive_timeout = 3,
        }).port
        cap_server:register_router(PUBLIC_ROUTER)
    end)

    t.describe("http keep-alive", function()
        t.it("同一条连接可以连续服务多个请求", function()
            local fd = connect(main_port)
            for _ = 1, 2 do
                socket.write(fd, request_text("/public/ping"))
                local status, headers = read_response(fd)
                t.expect(status).to.equal(200)
                t.expect(headers["connection"]).to.equal("keep-alive")
            end
            socket.close(fd)
        end)

        t.it("达到单连接请求数上限后主动关闭", function()
            local fd = connect(main_port)
            local last_headers
            for _ = 1, 3 do
                socket.write(fd, request_text("/public/ping"))
                local status, headers = read_response(fd)
                t.expect(status).to.equal(200)
                last_headers = headers
            end
            -- keepalive_requests = 3，第三个响应就该宣告关闭
            t.expect(last_headers["connection"]).to.equal("close")
            t.expect(wait_closed(fd, 3)).to.equal(true)
        end)

        t.it("尊重客户端的 connection: close", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/ping", { connection = "close" }))
            local status, headers = read_response(fd)
            t.expect(status).to.equal(200)
            t.expect(headers["connection"]).to.equal("close")
            t.expect(wait_closed(fd, 3)).to.equal(true)
        end)

        t.it("没有 body 的响应也带 content-length，否则客户端无法分帧", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/nope"))
            local status, headers = read_response(fd)
            t.expect(status).to.equal(404)
            t.expect(headers["content-length"]).to.equal("0")
            -- 404 之后连接仍可复用
            socket.write(fd, request_text("/public/ping"))
            t.expect((read_response(fd))).to.equal(200)
            socket.close(fd)
        end)

        t.it("204 不带 content-length，但连接仍能正确分帧", function()
            -- RFC 7230：204 不允许带 content-length；它本身定义为无 body，客户端不会去找
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/ping", { method = "OPTIONS" }))
            local status, headers = read_response(fd)
            t.expect(status).to.equal(204)
            t.expect(headers["content-length"]).to.be_nil()
            socket.write(fd, request_text("/public/ping"))
            t.expect((read_response(fd))).to.equal(200)
            socket.close(fd)
        end)
    end)

    t.describe("http 路由出错时的兜底", function()
        t.it("路由写第二次响应时被挡掉，不会写乱字节流", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/double"))
            local status, _, body = read_response(fd)
            t.expect(status).to.equal(200)
            t.expect(body:find('"first":true', 1, true)).to.be_type("number")
            -- 第二次响应如果真写出去了，这里读到的就是它而不是下一个请求的结果
            socket.write(fd, request_text("/public/ping"))
            local next_status, _, next_body = read_response(fd)
            t.expect(next_status).to.equal(200)
            t.expect(next_body:find('"scope":"public"', 1, true)).to.be_type("number")
            socket.close(fd)
        end)

        t.it("路由一个字都不写时补一个 500 并关闭连接", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/silent"))
            local status, headers = read_response(fd)
            t.expect(status).to.equal(500)
            t.expect(headers["connection"]).to.equal("close")
            t.expect(wait_closed(fd, 3)).to.equal(true)
        end)
    end)

    t.describe("http 超时", function()
        t.it("请求迟迟发不完时掐断连接", function()
            local fd = connect(main_port)
            -- 只发请求行，不发结尾空行：典型的 slowloris 形态
            socket.write(fd, "GET /public/ping HTTP/1.1\r\nhost: 127.0.0.1\r\n")
            t.expect(wait_closed(fd, 5)).to.equal(true)
        end)

        t.it("keep-alive 空闲超过上限后关闭连接", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/ping"))
            t.expect((read_response(fd))).to.equal(200)
            -- keepalive_timeout = 1，之后不再发请求
            t.expect(wait_closed(fd, 5)).to.equal(true)
        end)

        t.it("连上不发任何数据的连接也会被回收", function()
            local fd = connect(main_port)
            t.expect(wait_closed(fd, 5)).to.equal(true)
        end)
    end)

    t.describe("http body 上限", function()
        t.it("超过 request_body_size 返回 413 并关闭连接", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/echo", { method = "POST", body = string.rep("x", 128) }))
            local status, headers = read_response(fd)
            t.expect(status).to.equal(413)
            -- 请求读取阶段就失败，缓冲区剩了什么无从得知，必须关闭而不是复用
            t.expect(headers["connection"]).to.equal("close")
            t.expect(wait_closed(fd, 3)).to.equal(true)
        end)

        t.it("上限之内的 body 正常处理", function()
            local fd = connect(main_port)
            socket.write(fd, request_text("/public/echo", { method = "POST", body = '{"msg":"hi"}' }))
            local status, _, body = read_response(fd)
            t.expect(status).to.equal(200)
            t.expect(body:find('"echo":"hi"', 1, true)).to.be_type("number")
            socket.close(fd)
        end)
    end)

    t.describe("http 连接数上限", function()
        t.it("超过 max_connections 的新连接被立刻关闭", function()
            local held = { connect(cap_port), connect(cap_port) }
            -- 等 watchdog 把前两条连接派发出去
            skynet.sleep(20)
            t.expect(cap_server:stats().active).to.equal(2)

            local extra = connect(cap_port)
            t.expect(wait_closed(extra, 3)).to.equal(true)
            local stats = cap_server:stats()
            t.expect(stats.active).to.equal(2)
            t.expect(stats.rejected).to.be_gte(1)

            for _, fd in ipairs(held) do
                socket.close(fd)
            end
        end)

        t.it("连接关闭后额度会归还", function()
            -- 上一个用例把两条连接关掉了，agent 需要几个 tick 才会上报 conn_closed
            for _ = 1, 50 do
                if cap_server:stats().active == 0 then
                    break
                end
                skynet.sleep(10)
            end
            t.expect(cap_server:stats().active).to.equal(0)

            local fd = connect(cap_port)
            socket.write(fd, request_text("/public/ping", { connection = "close" }))
            t.expect((read_response(fd))).to.equal(200)
            socket.close(fd)
        end)
    end)
end)
