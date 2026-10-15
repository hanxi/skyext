local t = require "skytest"
local lfs = require "lfs"
local fs = require "skyext.util.fs"

local sep = package.config:sub(1, 1)

-- fs 全是真的文件系统操作，没有值得替身的依赖，直接在临时目录里跑
local function sandbox(fn)
    local dir = fs.temporary_dir()
    local ok, err = pcall(fn, dir)
    fs.remove_tree(dir)
    if not ok then
        error(err, 0)
    end
end

local function names_of(items)
    local out = {}
    for i, item in ipairs(items) do
        out[i] = item.relative
    end
    table.sort(out)
    return out
end

t.describe("fs path composition", function()
    t.it("拼接时跳过空段并消掉重复分隔符", function()
        t.expect(fs.join("a", "b", "c")).to.equal(table.concat({ "a", "b", "c" }, sep))
        t.expect(fs.join("a", "", "b")).to.equal(table.concat({ "a", "b" }, sep))
        t.expect(fs.join("a" .. sep, "b")).to.equal(table.concat({ "a", "b" }, sep))
        t.expect(fs.join()).to.equal("")
    end)

    t.it("遇到绝对路径段就从那一段重新开始", function()
        -- 否则 join(base, user_input) 会在 user_input 是绝对路径时拼出一个不存在的怪路径
        t.expect(fs.join("a", sep .. "etc", "passwd")).to.equal(sep .. "etc" .. sep .. "passwd")
        t.expect(fs.join("a", "C:" .. sep .. "tmp")).to.equal("C:" .. sep .. "tmp")
    end)

    t.it("统一把正反斜杠换成当前平台的分隔符", function()
        t.expect(fs.join("a/b", "c")).to.equal(table.concat({ "a", "b", "c" }, sep))
    end)

    t.it("absolute 对已经是绝对路径的输入原样返回", function()
        local abs = sep .. "tmp" .. sep .. "x"
        t.expect(fs.absolute(abs)).to.equal(abs)
        t.expect(fs.absolute("C:" .. sep .. "x")).to.equal("C:" .. sep .. "x")
    end)

    t.it("absolute 把相对路径接到当前目录后面", function()
        t.expect(fs.absolute("x")).to.equal(fs.join(lfs.currentdir(), "x"))
    end)
end)

t.describe("fs directory operations", function()
    t.it("mkdir 递归建出中间目录，重复调用不报错", function()
        sandbox(function(dir)
            local deep = fs.join(dir, "a", "b", "c")
            fs.mkdir(deep)
            t.expect(fs.mode(deep)).to.equal("directory")
            fs.mkdir(deep)
            t.expect(fs.mode(deep)).to.equal("directory")
        end)
    end)

    t.it("目标已经是普通文件时 mkdir 报错，不悄悄当成功", function()
        sandbox(function(dir)
            local path = fs.join(dir, "taken")
            fs.write(path, "x")
            t.expect(function()
                fs.mkdir(path)
            end).to
                .throw("not a directory")
        end)
    end)

    t.it("entries 按名字排序并滤掉 . 与 ..", function()
        sandbox(function(dir)
            fs.write(fs.join(dir, "b.txt"), "")
            fs.write(fs.join(dir, "a.txt"), "")
            fs.mkdir(fs.join(dir, "sub"))
            t.expect(fs.entries(dir)).to.equal({ "a.txt", "b.txt", "sub" })
        end)
    end)

    t.it("remove_tree 递归删目录，也能删单个文件", function()
        sandbox(function(dir)
            local tree = fs.join(dir, "tree")
            fs.write(fs.join(tree, "a", "x.txt"), "x")
            fs.remove_tree(tree)
            t.expect(fs.mode(tree)).to.be_nil()

            local file = fs.join(dir, "one.txt")
            fs.write(file, "x")
            fs.remove_tree(file)
            t.expect(fs.mode(file)).to.be_nil()
        end)
    end)

    t.it("remove_tree 对不存在的路径是空操作", function()
        sandbox(function(dir)
            fs.remove_tree(fs.join(dir, "never-existed"))
        end)
    end)

    t.it("temporary_dir 每次给出一个新建的空目录", function()
        sandbox(function(dir)
            local a = fs.temporary_dir(dir)
            local b = fs.temporary_dir(dir)
            t.expect(a).to_not.equal(b)
            t.expect(fs.mode(a)).to.equal("directory")
            t.expect(fs.entries(a)).to.have_length(0)
        end)
    end)
end)

t.describe("fs file io", function()
    t.it("write 自动建出父目录，read 原样读回", function()
        sandbox(function(dir)
            local path = fs.join(dir, "deep", "nested", "f.txt")
            fs.write(path, "hello\nworld")
            t.expect(fs.read(path)).to.equal("hello\nworld")
        end)
    end)

    t.it("二进制内容不被换行转换破坏", function()
        sandbox(function(dir)
            local path = fs.join(dir, "bin")
            local data = "\0\1\r\n\255binary"
            fs.write(path, data)
            t.expect(fs.read(path)).to.equal(data)
        end)
    end)

    t.it("读不存在的文件直接报错，不返回空串", function()
        sandbox(function(dir)
            t.expect(function()
                fs.read(fs.join(dir, "missing"))
            end).to
                .throw()
        end)
    end)

    t.it("copy 完整复制超过单次读取块大小的文件", function()
        sandbox(function(dir)
            -- 64KiB 是 copy 内部的读取块，必须跨过它才能覆盖到循环
            local data = string.rep("abcdefgh", 20000)
            local source = fs.join(dir, "big.bin")
            fs.write(source, data)
            local target = fs.join(dir, "out", "big.bin")
            fs.copy(source, target)
            t.expect(fs.read(target)).to.equal(data)
        end)
    end)
end)

t.describe("fs tree walking", function()
    local function build(dir)
        fs.write(fs.join(dir, "root.txt"), "root")
        fs.write(fs.join(dir, "keep", "a.txt"), "a")
        fs.write(fs.join(dir, "skip", "b.txt"), "b")
    end

    t.it("walk 递归列出文件与目录，relative 一律用正斜杠", function()
        sandbox(function(dir)
            build(dir)
            t.expect(names_of(fs.walk(dir))).to.equal({
                "keep",
                "keep/a.txt",
                "root.txt",
                "skip",
                "skip/b.txt",
            })
        end)
    end)

    t.it("accept 返回 false 的目录会被整棵剪掉，不只是它本身", function()
        sandbox(function(dir)
            build(dir)
            local items = fs.walk(dir, function(relative)
                return relative ~= "skip"
            end)
            t.expect(names_of(items)).to.equal({ "keep", "keep/a.txt", "root.txt" })
        end)
    end)

    t.it("同目录内指向普通文件的软链按文件处理", function()
        sandbox(function(dir)
            fs.write(fs.join(dir, "real.txt"), "x")
            assert(lfs.link("real.txt", fs.join(dir, "alias.txt"), true))
            local items = fs.walk(dir)
            for _, item in ipairs(items) do
                t.expect(item.mode).to.equal("file")
            end
            t.expect(names_of(items)).to.equal({ "alias.txt", "real.txt" })
        end)
    end)

    t.it("指向目录外的软链被拒绝，打包时不会把链接外的东西带进去", function()
        sandbox(function(dir)
            fs.write(fs.join(dir, "real.txt"), "x")
            assert(lfs.link(".." .. sep .. "escape.txt", fs.join(dir, "escape"), true))
            t.expect(function()
                fs.walk(dir)
            end).to
                .throw("symlink outside its directory")
        end)
    end)

    t.it("指向非普通文件的软链被拒绝", function()
        sandbox(function(dir)
            fs.mkdir(fs.join(dir, "adir"))
            assert(lfs.link("adir", fs.join(dir, "dirlink"), true))
            t.expect(function()
                fs.walk(dir)
            end).to
                .throw("symlink target is not a regular file")
        end)
    end)

    t.it("copy_tree 保持目录结构并尊重 accept", function()
        sandbox(function(dir)
            local source = fs.join(dir, "src")
            fs.write(fs.join(source, "keep", "a.txt"), "a")
            fs.write(fs.join(source, "skip", "b.txt"), "b")
            local target = fs.join(dir, "dst")
            fs.copy_tree(source, target, function(relative)
                return relative ~= "skip"
            end)
            t.expect(fs.read(fs.join(target, "keep", "a.txt"))).to.equal("a")
            t.expect(fs.mode(fs.join(target, "skip"))).to.be_nil()
        end)
    end)

    t.it("copy_tree 的源不是目录时报错", function()
        sandbox(function(dir)
            local file = fs.join(dir, "f.txt")
            fs.write(file, "x")
            t.expect(function()
                fs.copy_tree(file, fs.join(dir, "dst"))
            end).to
                .throw("not a directory")
        end)
    end)
end)

t.describe("fs with_dir", function()
    t.it("执行期间切到目标目录，结束后回到原处并带回返回值", function()
        sandbox(function(dir)
            local before = lfs.currentdir()
            local inside, extra = fs.with_dir(dir, function()
                return lfs.currentdir(), "extra"
            end)
            t.expect(extra).to.equal("extra")
            -- macOS 的 /var 是 /private/var 的软链，比较真实路径而不是字面量
            t.expect(inside).to_not.equal(before)
            t.expect(lfs.currentdir()).to.equal(before)
        end)
    end)

    t.it("回调抛错时仍然先恢复当前目录再把错误抛出去", function()
        sandbox(function(dir)
            local before = lfs.currentdir()
            t.expect(function()
                fs.with_dir(dir, function()
                    error("boom")
                end)
            end).to
                .throw("boom")
            -- 不恢复的话后面所有用相对路径的代码都会写错地方
            t.expect(lfs.currentdir()).to.equal(before)
        end)
    end)
end)
