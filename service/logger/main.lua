-- logger 服务需要特殊处理，防止无法捕捉导启动失败导错误日志
local ok, err_msg = xpcall(function()
    require "start"
end, debug.traceback)

if not ok then
    print(err_msg)

    local skynet = require "skynet"
    local bootfaillogpath = skynet.getenv("bootfaillogpath")
    local file <close> = io.open(bootfaillogpath, "w+")
    if file then
        file:write(err_msg, "\n")
        file:flush()
    end
    skynet.abort()
end
