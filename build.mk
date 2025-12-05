PLATS = freebsd linux macosx mingw

.PHONY: $(PLATS) clean cleanall skynet

$(PLATS):
	@$(MAKE) PLAT=$@ build

ifeq ($(PLAT),)
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
endif

SHARED := -fPIC --shared
BIN_PATH ?= bin
LUA_CLIB_PATH ?= luaclib
LUA_LIB_PATH ?= lualib
LUA_DIR ?= skynet/3rd/lua
LUA_INC ?= $(LUA_DIR)
CFLAGS = -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)
SKYNET_LIBS :=
EXE_SUFFIX :=
LUA_LIBS :=
PLAT_HOST :=
ifeq ($(PLAT), macosx)
	SHARED := -fPIC -dynamiclib -Wl,-undefined,dynamic_lookup
else ifeq ($(PLAT), mingw)
	CC := x86_64-w64-mingw32-gcc
	COMPAT_MINGW_DIR = skynet/3rd/compat-mingw
	CFLAGS := -g -O2 -Wall -std=gnu99 -I$(LUA_INC) $(MYCFLAGS) -I$(COMPAT_MINGW_DIR)
	CFLAGS += -include $(COMPAT_MINGW_DIR)/compat.h
	CFLAGS += -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-pointer-sign -Wno-unused-function
	SKYNET_LIBS := -static-libgcc -Wl,-Bstatic -lpthread -Wl,-Bdynamic -lm -lws2_32 -lgdi32
	EXE_SUFFIX := ".exe"
	LUA_LIBS := -L$(LUA_DIR) -llua54
	PLAT_HOST := --host=x86_64-w64-mingw32
endif

$(LUA_CLIB_PATH) :
	mkdir -p $(LUA_CLIB_PATH)

$(BIN_PATH) :
	mkdir -p $(BIN_PATH)


$(LUA_CLIB_PATH)/jchash.so : lualib-src/jchash.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(LUA_CLIB_PATH)/cjson.so : 3rd/lua-cjson/lua_cjson.c 3rd/lua-cjson/strbuf.c 3rd/lua-cjson/fpconv.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I3rd/lua-cjson $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(LUA_CLIB_PATH)/traceback.so : lualib-src/traceback.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(LUA_CLIB_PATH)/lfs.so : 3rd/luafilesystem/src/lfs.c | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

SODIUM_DIR = 3rd/libsodium
SODIUM_LIB = $(SODIUM_DIR)/src/libsodium/.libs/libsodium.a
SODIUM_INC = $(SODIUM_DIR)/src/libsodium/include
$(SODIUM_LIB):
	cd $(SODIUM_DIR) && \
	./configure --disable-shared --enable-static --with-pic $(PLAT_HOST) && \
	$(MAKE)
$(LUA_CLIB_PATH)/crypto.so : lualib-src/crypto.c $(SODIUM_LIB) | $(LUA_CLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I$(SODIUM_INC) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)


LUA_CLIB = jchash cjson traceback lfs crypto

skynet: $(BIN_PATH)
	cd skynet && $(MAKE) $(PLAT)
	cp -f skynet/skynet$(EXE_SUFFIX) $(BIN_PATH)/
	cp skynet/3rd/lua/lua$(EXE_SUFFIX) $(BIN_PATH)/
	cp skynet/3rd/lua/luac$(EXE_SUFFIX) $(BIN_PATH)/
ifeq ($(PLAT), mingw)
	cp -f skynet/*.dll $(BIN_PATH)/
endif

# 编译 skynet 和 C 库
build: skynet \
	$(LUA_CLIB_PATH) \
	$(foreach v, $(LUA_CLIB), $(LUA_CLIB_PATH)/$(v).so) copy | $(BIN_PATH)
	mkdir -p logs

# 清理
clean:
	cd skynet && $(MAKE) clean
	rm -f $(LUA_CLIB_PATH)/*.so
	rm -rf $(LUA_CLIB_PATH)/*.so.dSYM
	rm -rf $(BIN_PATH)/*

# 清理所有
cleanall: clean
	cd skynet && $(MAKE) cleanall
	rm -rf dist skyext.zip
	cd $(SODIUM_DIR) && $(MAKE) distclean || true

