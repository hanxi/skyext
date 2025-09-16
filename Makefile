all : help

help:
	@echo "支持下面命令:"
	@awk '/^#/{comment=substr($$0,2)} /^[a-zA-Z0-9_-]+:/{gsub(/:/, ""); if(comment)printf "make %-12s #%s\n", $$1, comment; comment=""}' $(MAKEFILE_LIST)

.PHONY: proto clean cleanall copy schema autocode dist skynet

UNAME ?= $(shell uname -s | tr A-Z a-z)
ifeq ($(UNAME), linux)
	PLAT := linux
else ifeq ($(UNAME), darwin)
	PLAT := macosx
else ifeq ($(findstring freebsd, $(UNAME)), freebsd)
	PLAT := freebsd
else
	PLAT := unknown
endif

SHARED := -fPIC --shared
EXPORT := -Wl,-E
ifeq ($(PLAT), macosx)
    SHARED := -fPIC -dynamiclib -Wl,-undefined,dynamic_lookup
    EXPORT :=
endif

BIN_PATH ?= bin
LUA_CLIB_PATH ?= luaclib
LUA_LIB_PATH ?= lualib
LUA_INC ?= skynet/3rd/lua
CFLAGS = -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)

$(LUA_CLIB_PATH) :
	mkdir -p $(LUA_CLIB_PATH)

$(BIN_PATH) :
	mkdir -p $(BIN_PATH)

$(LUA_CLIB_PATH)/jchash.so : lualib-src/jchash.c | $(LUA_CLIB_PATH)
	echo $(PLAT)
	echo $(SHARED)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(LUA_CLIB_PATH)/cjson.so : 3rd/lua-cjson/lua_cjson.c 3rd/lua-cjson/strbuf.c 3rd/lua-cjson/fpconv.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-cjson $^ -o $@

$(LUA_CLIB_PATH)/traceback.so : lualib-src/traceback.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(LUA_CLIB_PATH)/lfs.so : 3rd/luafilesystem/src/lfs.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

SODIUM_DIR = 3rd/libsodium
SODIUM_LIB = $(SODIUM_DIR)/src/libsodium/.libs/libsodium.a
SODIUM_INC = $(SODIUM_DIR)/src/libsodium/include
$(SODIUM_LIB):
	cd $(SODIUM_DIR) && \
	./autogen.sh && \
	./configure --disable-shared --enable-static --with-pic && \
	make
$(LUA_CLIB_PATH)/crypto.so : lualib-src/crypto.c $(SODIUM_LIB) | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I$(SODIUM_INC) $^ -o $@

LUA_CLIB = jchash cjson traceback lfs crypto

# 初始化 submodule
init:
	git submodule update --init --recursive

skynet:
	cd skynet && $(MAKE) $(PLAT)
	cp skynet/skynet $(BIN_PATH)/
	cp skynet/3rd/lua/lua $(BIN_PATH)/
	cp skynet/3rd/lua/luac $(BIN_PATH)/

# 编译 skynet 和 C 库
build: skynet \
	$(LUA_CLIB_PATH) \
	$(foreach v, $(LUA_CLIB), $(LUA_CLIB_PATH)/$(v).so) copy | $(BIN_PATH)
	mkdir -p logs

# 拷贝 3rd 里必要的 lua 文件
copy:
	# 这些lua文件直接拷贝，因此如果需要修改，则应该取改 3rd 目录下的原文件
	cp -rf 3rd/sproto-orm/orm $(LUA_LIB_PATH)/
	cp -f 3rd/binaryheap.lua/src/binaryheap.lua $(LUA_LIB_PATH)/

# 编译协议
proto:
	./tools/gen_proto.sh

# 编译 ORM 模式文件
schema:
	./tools/gen_schema.sh

# 生成代码
autocode:
	./bin/lua tools/run.lua tools/gen_roleagent_modules.lua

# 清理
clean:
	cd skynet && $(MAKE) clean
	rm -f $(LUA_CLIB_PATH)/*.so
	rm -rf $(LUA_CLIB_PATH)/*.so.dSYM
	rm -rf $(BIN_PATH)/*

# 清理所有
cleanall: clean
	cd skynet && $(MAKE) cleanall
	cd $(SODIUM_DIR) && $(MAKE) distclean
	rm -rf dist skyext.zip

# 打包
dist: build
	./tools/dist.sh
