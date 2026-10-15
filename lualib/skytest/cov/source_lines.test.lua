local t = require "skytest"
local source_lines = require "skytest.cov.source_lines"

-- 夹具的行号是断言的一部分，改 nested.lua 必须同步这里
local FIXTURE_DIR = "lualib/skytest/cov/source_lines.test"
local FIXTURE_KEY = "@./" .. FIXTURE_DIR .. "/nested.lua"
-- inner 函数体内的 return；嵌套 Proto，顶层 chunk 的 activelines 里没有它
local LINE_IN_NESTED_FUNCTION = 6
-- 表构造里匿名函数体内的 return，嵌套得更深一层
local LINE_IN_ANONYMOUS_FUNCTION = 10
-- 顶层 chunk 自己的行，新旧实现都该有
local LINE_AT_TOP_LEVEL = 2

t.describe("skytest.cov.source_lines", function()
    t.describe("scan", function()
        t.it("把嵌套函数体的行算进基线", function()
            local baseline = source_lines.scan({ FIXTURE_DIR }, {})
            local lines = baseline[FIXTURE_KEY]
            t.expect(lines).to.exist()
            t.expect(lines).to.have_key(LINE_AT_TOP_LEVEL)
            -- 回归保护：这两行曾经不在分母里，于是任何加载过的文件都是 100%
            t.expect(lines).to.have_key(LINE_IN_NESTED_FUNCTION)
            t.expect(lines).to.have_key(LINE_IN_ANONYMOUS_FUNCTION)
        end)

        t.it("基线里每一行的初始命中数是 0", function()
            local baseline = source_lines.scan({ FIXTURE_DIR }, {})
            t.expect(baseline[FIXTURE_KEY][LINE_IN_NESTED_FUNCTION]).to.equal(0)
        end)

        t.it("空行和注释行不计入基线", function()
            local lines = source_lines.scan({ FIXTURE_DIR }, {})[FIXTURE_KEY]
            t.expect(lines).to_not.have_key(1) -- 注释
            t.expect(lines).to_not.have_key(3) -- 空行
        end)

        t.it("exclude 命中的文件不进基线", function()
            local baseline = source_lines.scan({ FIXTURE_DIR }, { "nested.lua" })
            t.expect(baseline[FIXTURE_KEY]).to.be_nil()
        end)
    end)

    t.describe("merge_with_stats", function()
        t.it("命中数叠加到基线行上", function()
            local baseline = { ["@./a.lua"] = { [1] = 0, [2] = 0 } }
            local merged = source_lines.merge_with_stats(baseline, { ["@./a.lua"] = { [1] = 3 } })
            t.expect(merged["@./a.lua"][1]).to.equal(3)
            t.expect(merged["@./a.lua"][2]).to.equal(0)
        end)

        t.it("不把基线里没有的行补进分母", function()
            local baseline = { ["@./a.lua"] = { [1] = 0 } }
            local merged, diag = source_lines.merge_with_stats(baseline, { ["@./a.lua"] = { [1] = 1, [9] = 5 } })
            -- 第 9 行执行到了但不在基线里，叠加它等于让分母跟着执行结果走
            t.expect(merged["@./a.lua"]).to_not.have_key(9)
            t.expect(diag.orphan_lines).to.equal(1)
        end)

        t.it("不把基线里没有的文件补进分母", function()
            local merged, diag = source_lines.merge_with_stats({}, { ["@./ghost.lua"] = { [1] = 1 } })
            t.expect(merged["@./ghost.lua"]).to.be_nil()
            t.expect(diag.unknown_sources).to.equal({ "@./ghost.lua" })
        end)

        t.it("未命中的基线行保留为 0 而不是被丢掉", function()
            local merged = source_lines.merge_with_stats({ ["@./a.lua"] = { [1] = 0, [2] = 0 } }, {})
            t.expect(merged["@./a.lua"][1]).to.equal(0)
            t.expect(merged["@./a.lua"][2]).to.equal(0)
        end)
    end)
end)
