local t = require "skytest"
local uio = require "skyext.util.io"

local test_file = "/tmp/skytest_io_test_rw.txt"
local test_file2 = "/tmp/skytest_io_test_overwrite.txt"

t.describe("util.io", function()
    t.after_all(function()
        os.remove(test_file)
        os.remove(test_file2)
    end)

    t.describe("writefile + readfile", function()
        t.it("writes and reads back content", function()
            local ok = uio.writefile(test_file, "hello skytest")
            t.expect(ok).to.equal(true)
            local data = uio.readfile(test_file)
            t.expect(data).to.equal("hello skytest")
        end)

        t.it("overwrites existing file", function()
            uio.writefile(test_file2, "first")
            uio.writefile(test_file2, "second")
            local data = uio.readfile(test_file2)
            t.expect(data).to.equal("second")
        end)

        t.it("handles binary content", function()
            local binary = "\0\1\2\255"
            uio.writefile(test_file, binary)
            local data = uio.readfile(test_file)
            t.expect(data).to.equal(binary)
        end)
    end)

    t.describe("readfile errors", function()
        t.it("returns nil for missing file", function()
            local data, err = uio.readfile("/tmp/skytest_nonexistent_file.txt")
            t.expect(data).to.be_nil()
            t.expect(err).to.be_type("string")
        end)
    end)
end)
