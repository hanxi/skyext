local skynet = require "skynet"

skynet.start(function()
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
