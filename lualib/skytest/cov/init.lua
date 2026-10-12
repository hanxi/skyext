local config = require "skytest.cov.config"
if not config.enabled then
    return
end

local skynet = require "skynet"

skynet.init(function()
    local install = require "skytest.cov.install"
    install.setup()
end)
