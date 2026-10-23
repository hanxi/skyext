local skynet = require "skynet"

skynet.start(function()
    -- stdout 指向管道时默认全缓冲：进程被信号杀死会把缓冲区尾部整个带走，
    -- CI 日志只剩半行截断输出，无从定位崩溃点。改行缓冲保住现场。
    io.stdout:setvbuf("line")

    local file = os.getenv("SKYTEST_FILE")
    if not file then
        io.stderr:write("[skytest] ERROR: SKYTEST_FILE not set\n")
        os.exit(2)
    end

    local runner = require "skytest.runner"
    local code = runner.run_file(file)

    if os.getenv("SKYTEST_COV") and os.getenv("SKYTEST_COV") ~= "0" then
        pcall(function()
            skynet.call(".skytest_cov", "lua", "FLUSH")
        end)
    end

    os.exit(code)
end)
