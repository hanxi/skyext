local t = require "skytest"
local fs = require "skyext.util.fs"
local lfs = require "lfs"

local source =
    fs.join(fs.absolute(os.getenv("SKYTEST_ROOT") or lfs.currentdir()), "lualib/skyext/event_channel_api.lua")

local function harness(opts)
    opts = opts or {}
    local h = { channels = {}, calls = {}, errors = {} }

    -- mc.new 带 conf 是订阅端，不带 conf 是服务端自己开频道
    local function channel_new(conf)
        local ch = {
            channel = conf and conf.channel or (opts.new_channel_id or 7777),
            conf = conf,
            subscribed = 0,
            published = {},
        }
        function ch:subscribe()
            self.subscribed = self.subscribed + 1
        end
        function ch:publish(cmd, ...)
            self.published[#self.published + 1] = { cmd = cmd, args = table.pack(...) }
        end
        h.channels[#h.channels + 1] = ch
        return ch
    end

    local imports = {
        skynet = {
            call = function(service, proto, cmd)
                h.calls[#h.calls + 1] = { service = service, proto = proto, cmd = cmd }
                return opts.up_channels and opts.up_channels[service] or 100
            end,
        },
        ["skynet.multicast"] = { new = channel_new },
        ["skyext.log"] = {
            info = function() end,
            warn = function() end,
            error = function(msg)
                h.errors[#h.errors + 1] = msg
            end,
        },
        ["skyext.cmd_api"] = {
            register = function(CMD)
                h.CMD = CMD
            end,
        },
    }
    local env = setmetatable({
        require = function(name)
            return imports[name] or require(name)
        end,
    }, { __index = _G })
    h.module = assert(loadfile(source, "t", env))()
    return h
end

t.describe("event_channel 订阅端", function()
    t.it("第一次订阅某服务时先问对方要频道号，再建 multicast 订阅", function()
        local h = harness({ up_channels = { [".role"] = 555 } })
        h.module.subscribe(".role", "level_up", function() end)

        t.expect(h.calls).to.have_length(1)
        t.expect(h.calls[1].service).to.equal(".role")
        t.expect(h.calls[1].proto).to.equal("lua")
        t.expect(h.calls[1].cmd).to.equal("GET_EVENT_CHANNEL")
        t.expect(h.channels).to.have_length(1)
        t.expect(h.channels[1].conf.channel).to.equal(555)
        t.expect(h.channels[1].subscribed).to.equal(1)
    end)

    t.it("同一个服务再订阅别的事件时复用已有频道，不重复 subscribe", function()
        -- 多订一次 multicast 内部就多记一次引用，退订时平不掉，频道会一直活着
        local h = harness()
        h.module.subscribe(".role", "level_up", function() end)
        h.module.subscribe(".role", "logout", function() end)

        t.expect(h.calls).to.have_length(1)
        t.expect(h.channels).to.have_length(1)
        t.expect(h.channels[1].subscribed).to.equal(1)
    end)

    t.it("不同服务各自建独立频道", function()
        local h = harness({ up_channels = { [".role"] = 11, [".guild"] = 22 } })
        h.module.subscribe(".role", "evt", function() end)
        h.module.subscribe(".guild", "evt", function() end)

        t.expect(h.calls).to.have_length(2)
        t.expect(h.channels).to.have_length(2)
        t.expect(h.channels[1].conf.channel).to.equal(11)
        t.expect(h.channels[2].conf.channel).to.equal(22)
    end)

    t.it("收到已订阅的事件时调对应回调，参数原样透传", function()
        local h = harness()
        local seen
        h.module.subscribe(".role", "level_up", function(...)
            seen = table.pack(...)
        end)
        local ch = h.channels[1]
        ch.conf.dispatch(ch, 1234, "level_up", 7, "abc")

        t.expect(seen).to.equal(table.pack(7, "abc"))
        t.expect(h.errors).to.have_length(0)
    end)

    t.it("收到没订阅过的事件时记 error，不抛异常打断 multicast 派发", function()
        -- 同一条频道上跑着所有事件，为一个没人管的事件把派发协程崩掉，
        -- 后面排在同批的订阅者就全收不到了
        local h = harness()
        local called = false
        h.module.subscribe(".role", "level_up", function()
            called = true
        end)
        local ch = h.channels[1]
        ch.conf.dispatch(ch, 1234, "guild_disband")

        t.expect(called).to.equal(false)
        t.expect(h.errors).to.have_length(1)
    end)

    t.it("后注册的回调对同一条已建好的频道立即生效", function()
        local h = harness()
        h.module.subscribe(".role", "level_up", function() end)
        local ch = h.channels[1]
        local hit
        h.module.subscribe(".role", "logout", function(uid)
            hit = uid
        end)
        ch.conf.dispatch(ch, 1234, "logout", 99)

        t.expect(hit).to.equal(99)
    end)
end)

t.describe("event_channel 服务端", function()
    t.it("init 开出服务端频道并把 GET_EVENT_CHANNEL 注册进 cmd_api", function()
        local h = harness({ new_channel_id = 4242 })
        h.module.init()

        t.expect(h.channels).to.have_length(1)
        -- 服务端是自己开频道，不带 conf
        t.expect(h.channels[1].conf).to.be_nil()
        t.expect(h.CMD.GET_EVENT_CHANNEL).to.be_type("function")
        t.expect(h.CMD.GET_EVENT_CHANNEL()).to.equal(4242)
    end)

    t.it("publish 把事件和参数原样发到服务端频道", function()
        local h = harness()
        h.module.init()
        h.module.publish("level_up", 7, "abc")

        local pub = h.channels[1].published
        t.expect(pub).to.have_length(1)
        t.expect(pub[1].cmd).to.equal("level_up")
        t.expect(pub[1].args).to.equal(table.pack(7, "abc"))
    end)

    t.it("没 init 就 publish 会直接报错，而不是把事件静默丢掉", function()
        local h = harness()
        local function publish_before_init()
            h.module.publish("level_up")
        end
        t.expect(publish_before_init).to.throw()
    end)
end)

t.describe("event_channel 两端对接", function()
    t.it("订阅端建频道用的正是服务端 init 开出来的那个号", function()
        local server = harness({ new_channel_id = 4242 })
        server.module.init()

        local client = harness({ up_channels = { [".role"] = server.CMD.GET_EVENT_CHANNEL() } })
        client.module.subscribe(".role", "evt", function() end)

        t.expect(client.channels[1].conf.channel).to.equal(4242)
    end)
end)
