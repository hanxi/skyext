local source = assert(arg and arg[0], "skyext must be run as a script"):gsub("\\", "/")
local prefix = source:match("^(.*)/scripts/skyext%.lua$") or source:match("^scripts/skyext%.lua$") and "."
assert(prefix, "cannot locate skyext root from " .. source)

package.path = table.concat({
    prefix .. "/?.lua",
    prefix .. "/lualib/?.lua",
    prefix .. "/lualib/?/init.lua",
    prefix .. "/skynet/lualib/?.lua",
    package.path,
}, ";")
package.cpath = table.concat({ prefix .. "/luaclib/?.so", prefix .. "/skynet/luaclib/?.so", package.cpath }, ";")

local fs = require "skyext.util.fs"
local lfs = require "lfs"
local root = fs.with_dir(prefix, lfs.currentdir)
local context = {
    root = root,
    game = fs.join(root, "example"),
    fs = fs,
    process = require "tool_process",
}

local commands = {
    test = "test",
    serve = "serve",
    generate = "generate",
    package = "package",
    hotfix = "hotfix",
    cov = "cov",
    schema = "schema",
}

local function usage()
    print([[skyext 工具 (先执行 make build)
用法: ./bin/skyext <command> [options]       (Unix/macOS)
      bin\skyext.bat <command> [options]   (Windows CMD/PowerShell)

  test [--cov] [--cov-c] [--match TEXT] [--timeout SECS] [targets...]
  serve <node|config>                  启动服务节点
  generate <proto|schema>              生成协议或 ORM schema（schema 需要 stylua）
  package game                         打包示例游戏部署包 example/skyext.zip
  package framework <platform>         打包平台框架发布包 release-assets/skyext-<platform>.zip
  hotfix refresh <dir>                 刷新热更包（<dir> 相对工程根目录，如 example/hotfix/xxx）
  cov <merge|check|summary|html> ...   覆盖率工具
  schema <check|accept|retired>        对比 ORM schema 与基线，拦下不兼容改动]])
end

local command = arg[1]
if not command or command == "-h" or command == "--help" then
    usage()
    return
end

if not commands[command] then
    io.stderr:write("未知命令: " .. command .. "\n")
    usage()
    os.exit(1)
end

local args = {}
for i = 2, #arg do
    args[#args + 1] = arg[i]
end

local ok, result = xpcall(function()
    return require("scripts.commands." .. commands[command])(context, command, args)
end, debug.traceback)
if not ok then
    io.stderr:write(result .. "\n")
    os.exit(1)
end
os.exit(result or 0)
