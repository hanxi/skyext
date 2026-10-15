local t = require "skytest"
local fs = require "skyext.util.fs"
local lcov_reporter = require "skytest.cov.lcov_reporter"

local function lines_of(text)
    local out = {}
    for line in text:gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

t.describe("skytest.cov.lcov_reporter", function()
    t.describe("generate", function()
        t.it("输出以 TN 开头、以 end_of_record 和换行结尾", function()
            local text = lcov_reporter.generate({ ["@./a.lua"] = { [1] = 1 } }, "suite")
            t.expect(lines_of(text)[1]).to.equal("TN:suite")
            t.expect(text:sub(-#"end_of_record\n")).to.equal("end_of_record\n")
        end)

        t.it("不传测试名时 TN 是空的而不是 nil", function()
            -- genhtml 遇到 "TN:nil" 不会报错，只会把 nil 当成测试名显示出来
            t.expect(lines_of(lcov_reporter.generate({}))[1]).to.equal("TN:")
        end)

        t.it("SF 去掉 Lua chunkname 的前导 @", function()
            local text = lcov_reporter.generate({ ["@./lualib/a.lua"] = { [1] = 1 } })
            t.expect(text).to.contain("SF:./lualib/a.lua")
            t.expect(text).to_not.contain("SF:@")
        end)

        t.it("source 本来就没有 @ 时原样当文件名", function()
            t.expect(lcov_reporter.generate({ ["./a.lua"] = { [1] = 1 } })).to.contain("SF:./a.lua")
        end)

        t.it("DA 按行号数值排序，不是按字符串排", function()
            local text = lcov_reporter.generate({ ["@a.lua"] = { [2] = 1, [10] = 1, [9] = 1 } })
            -- 字符串序会把 10 排在 2 前面，genhtml 读得进去但行号表就乱了
            t.expect(lines_of(text)).to.equal({
                "TN:",
                "SF:a.lua",
                "DA:2,1",
                "DA:9,1",
                "DA:10,1",
                "LH:3",
                "LF:3",
                "end_of_record",
            })
        end)

        t.it("多个文件按文件名排序，保证两次运行的输出可比对", function()
            local text = lcov_reporter.generate({
                ["@b.lua"] = { [1] = 1 },
                ["@a.lua"] = { [1] = 1 },
                ["@c.lua"] = { [1] = 1 },
            })
            local order = {}
            for name in text:gmatch("SF:([^\n]+)") do
                order[#order + 1] = name
            end
            t.expect(order).to.equal({ "a.lua", "b.lua", "c.lua" })
        end)

        t.it("LH 只数命中过的行，LF 数全部行", function()
            local text = lcov_reporter.generate({ ["@a.lua"] = { [1] = 3, [2] = 0, [3] = 1 } })
            t.expect(text).to.contain("LH:2")
            t.expect(text).to.contain("LF:3")
        end)

        t.it("一行都没命中时仍然写出 DA 行，分母不会凭空缩水", function()
            local text = lcov_reporter.generate({ ["@a.lua"] = { [1] = 0, [2] = 0 } })
            -- 漏掉未命中行会让这个文件看起来 0/0，在汇总里等于不存在
            t.expect(text).to.contain("DA:1,0")
            t.expect(text).to.contain("DA:2,0")
            t.expect(text).to.contain("LH:0")
            t.expect(text).to.contain("LF:2")
        end)

        t.it("没有任何文件时只产出 TN 行", function()
            t.expect(lcov_reporter.generate({}, "empty")).to.equal("TN:empty\n")
        end)

        t.it("某个文件一行都没有时 LF 为 0 且不产出 DA", function()
            local text = lcov_reporter.generate({ ["@a.lua"] = {} })
            t.expect(text).to_not.contain("DA:")
            t.expect(text).to.contain("LF:0")
        end)
    end)

    t.describe("write", function()
        t.it("写出的文件内容和 generate 完全一致", function()
            local dir = fs.temporary_dir()
            local path = fs.join(dir, "coverage.info")
            local stats = { ["@a.lua"] = { [1] = 2 } }
            t.expect(lcov_reporter.write(stats, path, "suite")).to.equal(true)
            t.expect(fs.read(path)).to.equal(lcov_reporter.generate(stats, "suite"))
            fs.remove_tree(dir)
        end)

        t.it("目标路径打不开时返回 nil 和原因，而不是抛错中断整轮测试", function()
            local dir = fs.temporary_dir()
            local ok, err = lcov_reporter.write({}, fs.join(dir, "missing", "coverage.info"))
            t.expect(ok).to.be_nil()
            t.expect(err).to.contain("cannot open")
            fs.remove_tree(dir)
        end)
    end)
end)
