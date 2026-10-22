-- 引擎自用的 binaryheap，收进 skyext 命名空间。
--
-- 不写成 require "binaryheap"：paths.conf.lua 里 game_root/lualib 排在 skyext_root/lualib
-- 之前，游戏层放一个同名文件就会把它顶替掉，而这个堆是 skyext.timer 的底层容器，
-- 定时器又是锁心跳、回存轮、实体卸载重试的底座——被顶替不会报错，只会行为诡异。
--
-- 源文件由 build.mk 从 3rd/binaryheap.lua 子模块拷到 lualib/binaryheap.lua，
-- 这里按引擎根目录的绝对路径加载，绕开 package.path，保持单一副本。
local skynet = require "skynet"

local root = skynet.getenv("skyext_root") or "./"
local path = root .. "lualib/binaryheap.lua"
local chunk = assert(loadfile(path))
return chunk()
