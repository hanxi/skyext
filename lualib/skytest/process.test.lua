local socket = require "skynet.socket"
local t = require "skytest"

t.describe("skytest process", function()
    t.it("starts a fixture without a shell and cleans it up", function()
        local listener, _, port = socket.listen("127.0.0.1", 0)
        socket.close(listener)
        local pid = t.start_skynet({
            start = "fixture",
            env = { fixture_port = port },
        })
        t.expect(type(pid)).to.equal("number")
        t.wait_for_port(port)
        local fixture = assert(io.open(t.data_path("fixture.lua"), "rb"))
        assert(fixture:close())
    end)
end)
