SKYEXT_ROOT = ..
BIN_PATH = $(SKYEXT_ROOT)/bin
include $(SKYEXT_ROOT)/build.mk

# ---------- 游戏 C 模块（产物输出到游戏 luaclib/）----------

GAME_LUACLIB_PATH = luaclib
GAME_LUA_CLIB =

$(GAME_LUACLIB_PATH) :
	mkdir -p $(GAME_LUACLIB_PATH)

# 游戏 C 模块编译规则（按需添加）
# GAME_LUA_CLIB += mygame
# $(GAME_LUACLIB_PATH)/mygame.so : lualib-src/mygame.c | $(GAME_LUACLIB_PATH)
# 	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

# ---------- 总构建 ----------

.PHONY: build proto schema format lint dist

# 编译
build: skyext_build \
	$(foreach v, $(GAME_LUA_CLIB), $(GAME_LUACLIB_PATH)/$(v).so)
	mkdir -p ../logs

# 工具命令统一由构建出的 Lua 解释器执行
SKYEXT_TOOL = $(BIN_PATH)/lua$(EXE_SUFFIX) $(SKYEXT_ROOT)/scripts/skyext.lua

# 编译协议
proto: skyext_build
	$(SKYEXT_TOOL) generate proto

# 编译 ORM 模式文件
schema: skyext_build
	$(SKYEXT_TOOL) generate schema

# 格式化 lua 代码
format:
	@echo "Formatting Lua files with stylua..."
	@stylua .

# 检查 lua 代码
lint:
	@echo "Checking Lua files with luacheck..."
	@luacheck .

# 打包
dist: build
	$(SKYEXT_TOOL) package game

# 清理游戏编译产物
clean:
	rm -f $(GAME_LUACLIB_PATH)/*.so
