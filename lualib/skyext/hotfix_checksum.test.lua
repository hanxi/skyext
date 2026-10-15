local t = require "skytest"
local checksum = require "skyext.hotfix_checksum"

-- 测试进程的工作目录是工程根目录，与服务端 skynet root = "./" 同一基准
local EXAMPLE_DIR = "example/hotfix/20260120-patch1"

t.describe("hotfix_checksum", function()
    t.describe("路径基准", function()
        t.it("update_files 相对工程根目录解析", function()
            local config = { update_files = { "example/lualib/errcode.lua" } }
            local value = checksum.compute(config, EXAMPLE_DIR, "./")
            t.expect(value).to.be_type("string")
        end)

        t.it("工程根目录下不存在的 update_files 报错而不是静默跳过", function()
            local config = { update_files = { "example/lualib/errcode.lua" } }
            -- 旧 CLI 用 example/ 作基准，同一条目会指向 example/example/lualib/errcode.lua
            local value, err = checksum.compute(config, "hotfix/20260120-patch1", "example")
            t.expect(value).to.equal(nil)
            t.expect(err).to.contain("Update file not readable")
        end)

        t.it("code_files 相对 root/hotfix_dir 解析", function()
            local config = { code_files = { "code1.lua" } }
            local value = checksum.compute(config, EXAMPLE_DIR, "./")
            t.expect(value).to.be_type("string")
        end)

        t.it("root 与 hotfix_dir 如何拆分不影响结果", function()
            local config = { code_files = { "code1.lua" } }
            local a = checksum.compute(config, EXAMPLE_DIR, "./")
            local b = checksum.compute(config, "hotfix/20260120-patch1", "./example")
            t.expect(a).to.equal(b)
        end)

        t.it("update_files 与 code_files 混合时两类基准同时生效", function()
            local config = {
                update_files = { "service/gm.lua" },
                code_files = { "code1.lua" },
            }
            local value = checksum.compute(config, EXAMPLE_DIR, "./")
            t.expect(value).to.be_type("string")
        end)
    end)

    t.describe("verify", function()
        -- 回归保护：CLI 的 hotfix refresh 与服务端 verify_checksum 必须使用同一基准。
        -- 两边基准不一致时，带 update_files 的热更包永远校验失败。
        t.it("示例热更包在服务端基准下校验通过", function()
            local config = assert(loadfile(EXAMPLE_DIR .. "/hotfix.conf.lua"))()
            local ok, err = checksum.verify(config, EXAMPLE_DIR, "./")
            t.expect(err).to.equal(nil)
            t.expect(ok).to.equal(true)
        end)

        t.it("checksum 不匹配时返回失败原因", function()
            local config = {
                code_files = { "code1.lua" },
                checksum = "deadbeef",
            }
            local ok, err = checksum.verify(config, EXAMPLE_DIR, "./")
            t.expect(ok).to.equal(false)
            t.expect(err).to.contain("Checksum mismatch")
        end)
    end)
end)
