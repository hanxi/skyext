local t = require "skytest"
local skynet = require "skynet"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source = fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "service/gate_ws.lua")

local SELF_NODE = "gate1"
local LOGIN = 42
local LISTEN_FD = 100

local function harness(opts)
    opts = opts or {}
    local h = { sent = {}, writes = {}, closes = {}, env = opts.env or {}, conn_co = {} }
    local noop = function() end

    local function record(target, cmd, ...)
        h.sent[#h.sent + 1] = { target, cmd, ... }
    end

    local fake_skynet = setmetatable({
        start = function(fn)
            h.boot = fn
        end,
        register = function(name)
            h.registered = name
        end,
        getenv = function(key)
            return h.env[key]
        end,
        setenv = function(key, value)
            t.expect(h.env[key]).to.be_nil()
            h.env[key] = value
        end,
        send = function(addr, proto, cmd, ...)
            t.expect(proto).to.equal("lua")
            record(addr, cmd, ...)
        end,
    }, { __index = skynet })

    local fake_cluster = {
        send = function(node, addr, cmd, ...)
            if h.cluster_error then
                error(h.cluster_error)
            end
            record(node .. "!" .. addr, cmd, ...)
        end,
    }

    local fake_socket = {
        listen = function(host, port)
            h.listen = { host = host, port = port }
            return LISTEN_FD
        end,
        start = function(id, cb)
            t.expect(id).to.equal(LISTEN_FD)
            h.accept_cb = cb
        end,
        close = function(id)
            h.listen_closed = id
        end,
        close_fd = function(id)
            h.dropped = id
        end,
    }

    -- websocket.accept 阻塞到连接关闭，这里用协程挂起模拟；测试用 h.disconnect 放行
    local fake_websocket = {
        accept = function(fd, handler, protocol, addr)
            h.handler = handler
            h.accepted = { fd = fd, protocol = protocol, addr = addr }
            if h.accept_fail then
                return false, "handshake failed"
            end
            h.conn_co[fd] = coroutine.running()
            skynet.wait()
            return true
        end,
        write = function(fd, data, fmt)
            if h.write_error then
                error(h.write_error)
            end
            h.writes[#h.writes + 1] = { fd = fd, data = data, fmt = fmt }
        end,
        close = function(fd, code, reason)
            h.closes[#h.closes + 1] = { fd = fd, code = code, reason = reason }
        end,
    }

    local imports = {
        skynet = fake_skynet,
        ["skynet.cluster"] = fake_cluster,
        ["skynet.socket"] = fake_socket,
        ["http.websocket"] = fake_websocket,
        ["skyext.cmd_api"] = {
            dispatch = function(commands)
                h.CMD = commands
            end,
        },
        ["skyext.config"] = {
            get = function(key)
                t.expect(key).to.equal("cluster_node_name")
                return SELF_NODE
            end,
        },
        ["skyext.node_shutdown_api"] = {
            add_hook = function(phase, cmd)
                h.hook = { phase = phase, cmd = cmd }
            end,
        },
        ["skyext.log"] = { info = noop, warn = noop, error = noop, debug = noop },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    assert(loadfile(source, "t", env))()
    h.boot()
    -- 停服钩子是在 skynet.fork 里注册的，让它跑起来
    skynet.sleep(0)

    -- 接一条连接：跑 accept 回调，等连接协程挂进 websocket.accept
    function h.connect(fd, addr)
        h.accept_cb(fd, addr or "127.0.0.1:1234")
        skynet.sleep(0)
    end

    -- 连接真的断了：唤醒连接协程，让它跑完 serve 的收尾
    function h.disconnect(fd)
        local co = h.conn_co[fd]
        h.conn_co[fd] = nil
        if co then
            skynet.wakeup(co)
        end
        skynet.sleep(0)
    end

    if not opts.no_open then
        h.CMD.open({
            address = "0.0.0.0",
            port = 7053,
            login = LOGIN,
            maxclient = opts.maxclient,
            protocol = opts.protocol,
            certfile = opts.certfile,
            keyfile = opts.keyfile,
        })
    end
    return h
end

t.describe("gate_ws startup", function()
    t.it("listens and registers the name the entity side routes packages to", function()
        local h = harness()
        t.expect(h.listen).to.equal({ host = "0.0.0.0", port = 7053 })
        t.expect(h.registered).to.equal(".gate_ws")
        t.expect(h.hook).to.equal({ phase = "stop_accepting", cmd = "close" })
    end)

    t.it("refuses to start without a login service or with an unknown protocol", function()
        local h = harness({ no_open = true })
        t.expect(function()
            h.CMD.open({ port = 7053 })
        end).to
            .throw("conf.login")
        t.expect(function()
            h.CMD.open({ port = 7053, login = LOGIN, protocol = "http" })
        end).to
            .throw("ws_protocol")
    end)

    -- 没开 enablessl 时 TLS 握手要到第一个 wss 连接进来才炸，那时候端口已经对外了
    t.it("rejects wss at startup when TLS is not enabled, instead of on the first connection", function()
        local h = harness({ no_open = true })
        t.expect(function()
            h.CMD.open({ port = 7053, login = LOGIN, protocol = "wss" })
        end).to
            .throw("enablessl")
    end)

    -- skynet 的 env 里全是字符串，配成别的值等于没开
    t.it("rejects wss when enablessl is set to anything other than the string true", function()
        local h = harness({ no_open = true, env = { enablessl = "false" } })
        t.expect(function()
            h.CMD.open({ port = 7053, login = LOGIN, protocol = "wss" })
        end).to
            .throw("enablessl")
    end)

    t.it("publishes the certificate paths where websocket.lua looks for them", function()
        local h = harness({
            no_open = true,
            env = { enablessl = "true" },
        })
        h.CMD.open({
            port = 7053,
            login = LOGIN,
            protocol = "wss",
            certfile = "cert.pem",
            keyfile = "key.pem",
        })
        t.expect(h.env.certfile).to.equal("cert.pem")
        t.expect(h.env.keyfile).to.equal("key.pem")
    end)

    -- skynet.setenv 不允许覆盖已存在的键，直接写节点配置的部署会在这里炸
    t.it("leaves certificate paths that the node config already set", function()
        local h = harness({
            no_open = true,
            env = { enablessl = "true", certfile = "from-node.pem", keyfile = "from-node-key.pem" },
        })
        h.CMD.open({ port = 7053, login = LOGIN, protocol = "wss" })
        t.expect(h.env.certfile).to.equal("from-node.pem")
    end)

    t.it("stops accepting without touching the connections already in flight", function()
        local h = harness()
        h.connect(9)
        h.CMD.close()
        t.expect(h.listen_closed).to.equal(LISTEN_FD)
        t.expect(h.CMD.count()).to.equal(1)
        t.expect(h.closes).to.equal({})
        -- 幂等：停服编排可能重复触发
        h.CMD.close()
    end)
end)

t.describe("gate_ws connections", function()
    t.it("tells the login service which gate a new connection came from", function()
        local h = harness()
        h.connect(9, "1.2.3.4:5678")
        t.expect(h.sent).to.equal({ { LOGIN, "open", 9, "1.2.3.4:5678", ".gate_ws" } })
        t.expect(h.accepted).to.equal({ fd = 9, protocol = "ws", addr = "1.2.3.4:5678" })
        t.expect(h.CMD.count()).to.equal(1)
    end)

    t.it("drops a new connection once it is full rather than degrade everyone", function()
        local h = harness({ maxclient = 1 })
        h.connect(9)
        h.connect(10)
        t.expect(h.dropped).to.equal(10)
        t.expect(h.CMD.count()).to.equal(1)
    end)

    t.it("cleans up a connection whose handshake never completed", function()
        local h = harness()
        h.accept_fail = true
        h.connect(9)
        t.expect(h.CMD.count()).to.equal(0)
        -- 没握成手的连接也要让登录服务知道，否则它的 fd 表会漏
        t.expect(h.sent[2]).to.equal({ LOGIN, "disconnect", 9 })
    end)

    t.it("frees the slot when the connection closes", function()
        local h = harness()
        h.connect(9)
        h.handler.close(9)
        t.expect(h.sent[2]).to.equal({ LOGIN, "disconnect", 9 })
        t.expect(h.CMD.count()).to.equal(0)
        -- serve 收尾时不能再报一次
        h.disconnect(9)
        t.expect(#h.sent).to.equal(2)
    end)
end)

t.describe("gate_ws forwarding", function()
    local function connected(opts)
        local h = harness(opts)
        h.connect(9)
        h.sent = {}
        return h
    end

    t.it("sends an unbound client's packages to the login service", function()
        local h = connected()
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({ { LOGIN, "client_msg", 9, "BYTES" } })
    end)

    t.it("forwards a bound client's packages straight to the owning entity agent", function()
        local h = connected()
        t.expect(h.CMD.bind(9, SELF_NODE, ".entity_agent:role:1")).to.equal(true)
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({ { ".entity_agent:role:1", "client_msg", SELF_NODE, 9, "BYTES" } })
    end)

    t.it("forwards to an owner on another node over cluster", function()
        local h = connected()
        h.CMD.bind(9, "rolenode1", ".entity_agent:role:1")
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({ { "rolenode1!.entity_agent:role:1", "client_msg", SELF_NODE, 9, "BYTES" } })
    end)

    -- 实体节点挂了不能把网关也带下去：这个包丢了，客户端超时后会重连
    t.it("survives an unreachable owner node", function()
        local h = connected()
        h.CMD.bind(9, "rolenode1", ".entity_agent:role:1")
        h.cluster_error = "node down"
        h.handler.message(9, "BYTES", "binary")
        t.expect(h.sent).to.equal({})
    end)

    t.it("tells the owner, not the login service, when a bound connection drops", function()
        local h = connected()
        h.CMD.bind(9, "rolenode1", ".entity_agent:role:1")
        h.handler.close(9)
        t.expect(h.sent).to.equal({ { "rolenode1!.entity_agent:role:1", "session_closed", SELF_NODE, 9 } })
    end)

    t.it("reports a socket error the same way as a clean close", function()
        local h = connected()
        h.handler.error(9, "reset by peer")
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
        t.expect(h.CMD.count()).to.equal(0)
    end)

    -- 协议是二进制 sproto。文本帧多半是接错端口或客户端发了 JSON，早断早清楚
    t.it("closes a connection that sends text frames", function()
        local h = connected()
        h.handler.message(9, '{"cmd":"login"}', "text")
        t.expect(h.sent).to.equal({})
        t.expect(h.closes[1].fd).to.equal(9)
        t.expect(h.closes[1].code).to.equal(1003)
    end)

    t.it("refuses to bind a connection that is already gone", function()
        local h = connected()
        t.expect(h.CMD.bind(99, SELF_NODE, ".entity_agent:role:1")).to.equal(false)
    end)
end)

t.describe("gate_ws downstream", function()
    t.it("writes a binary frame without a length prefix, the WS frame has its own", function()
        local h = harness()
        h.connect(9)
        h.CMD.push(9, "PACK")
        t.expect(h.writes).to.equal({ { fd = 9, data = "PACK", fmt = "binary" } })
    end)

    t.it("drops a package for a connection it does not know", function()
        local h = harness()
        h.CMD.push(9, "PACK")
        t.expect(h.writes).to.equal({})
    end)

    -- 写可能撞上连接正在关闭，这条连接自己会走断开流程，不能连累推送的实体
    t.it("does not propagate a write error to the caller", function()
        local h = harness()
        h.connect(9)
        h.write_error = "socket closed"
        h.CMD.push(9, "PACK")
        t.expect(h.writes).to.equal({})
    end)

    -- kick 只关 socket，解绑交给断开回调，这样 on_unbind_client 照常执行
    t.it("kick closes the socket and leaves the unbind to the disconnect callback", function()
        local h = harness()
        h.connect(9)
        h.sent = {}
        h.CMD.kick(9)
        t.expect(h.closes[1].fd).to.equal(9)
        t.expect(h.sent).to.equal({})
        t.expect(h.CMD.count()).to.equal(1)

        h.handler.close(9)
        t.expect(h.sent).to.equal({ { LOGIN, "disconnect", 9 } })
    end)

    t.it("ignores a kick for a connection that is already gone", function()
        local h = harness()
        h.CMD.kick(9)
        t.expect(h.closes).to.equal({})
    end)
end)
