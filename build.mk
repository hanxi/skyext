PLATS = freebsd linux macosx mingw

.PHONY: $(PLATS) clean cleanall skynet skyext_build copy

$(PLATS):
	@$(MAKE) PLAT=$@ skyext_build

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

# 由游戏 Makefile 设置
SKYEXT_ROOT ?= ./

SHARED := -fPIC --shared
BIN_PATH ?= $(SKYEXT_ROOT)/bin
LUA_DIR ?= $(SKYEXT_ROOT)/skynet/3rd/lua
LUA_INC ?= $(LUA_DIR)
CFLAGS = -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)
OPENSSL_CFLAGS ?=
OPENSSL_LDFLAGS ?=
SKYNET_LIBS :=
EXE_SUFFIX :=
LUA_LIBS :=
SKYNET_LINK_LIBS :=
PLAT_HOST :=
ifeq ($(PLAT), macosx)
	SHARED := -fPIC -dynamiclib -Wl,-undefined,dynamic_lookup
else ifeq ($(PLAT), mingw)
	CC := x86_64-w64-mingw32-gcc
	COMPAT_MINGW_DIR = $(SKYEXT_ROOT)/skynet/3rd/compat-mingw
	CFLAGS := -g -O2 -Wall -std=gnu99 -I$(LUA_INC) $(MYCFLAGS) -I$(COMPAT_MINGW_DIR)
	CFLAGS += -include $(COMPAT_MINGW_DIR)/compat.h
	CFLAGS += -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-pointer-sign -Wno-unused-function
	SKYNET_LIBS := -static-libgcc -Wl,-Bstatic -lpthread -Wl,-Bdynamic -lm -lws2_32 -lgdi32
	EXE_SUFFIX := ".exe"
	LUA_LIBS := -L$(LUA_DIR) -llua54
	SKYNET_LINK_LIBS := -L$(SKYEXT_ROOT)/skynet -lskynet
	PLAT_HOST := --host=x86_64-w64-mingw32
endif

# ---------- 引擎 C 模块（产物输出到引擎 luaclib/）----------

SKYEXT_LUACLIB_PATH = $(SKYEXT_ROOT)/luaclib

$(SKYEXT_LUACLIB_PATH) :
	mkdir -p $(SKYEXT_LUACLIB_PATH)

$(BIN_PATH) :
	mkdir -p $(BIN_PATH)

$(SKYEXT_LUACLIB_PATH)/jchash.so : $(SKYEXT_ROOT)/lualib-src/jchash.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(SKYEXT_LUACLIB_PATH)/cjson.so : $(SKYEXT_ROOT)/3rd/lua-cjson/lua_cjson.c \
                                   $(SKYEXT_ROOT)/3rd/lua-cjson/strbuf.c \
                                   $(SKYEXT_ROOT)/3rd/lua-cjson/fpconv.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I$(SKYEXT_ROOT)/3rd/lua-cjson $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(SKYEXT_LUACLIB_PATH)/traceback.so : $(SKYEXT_ROOT)/lualib-src/traceback.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(SKYEXT_LUACLIB_PATH)/lfs.so : $(SKYEXT_ROOT)/3rd/luafilesystem/src/lfs.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(SKYEXT_LUACLIB_PATH)/tool_process.so : $(SKYEXT_ROOT)/lualib-src/tool_process.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

$(SKYEXT_LUACLIB_PATH)/crypto.so : $(SKYEXT_ROOT)/lualib-src/crypto.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(OPENSSL_CFLAGS) $(SHARED) $^ -o $@ $(OPENSSL_LDFLAGS) -lssl -lcrypto $(LUA_LIBS) $(SKYNET_LIBS)

$(SKYEXT_LUACLIB_PATH)/profiler_c.so : $(SKYEXT_ROOT)/lualib-src/profiler.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

SKYEXT_LUA_CLIB = jchash cjson traceback lfs tool_process crypto profiler_c

# mingw.mk 不构建 TLS_MODULE，待 Lua 导入库生成后单独编译。
SKYEXT_TLS_MODULE =
ifeq ($(PLAT), mingw)
SKYEXT_TLS_MODULE = $(SKYEXT_ROOT)/skynet/luaclib/ltls.so

$(SKYEXT_TLS_MODULE): $(SKYEXT_ROOT)/skynet/lualib-src/ltls.c | skynet
	$(CC) $(CFLAGS) $(OPENSSL_CFLAGS) $(SHARED) $< -o $@ $(OPENSSL_LDFLAGS) -lssl -lcrypto $(LUA_LIBS) $(SKYNET_LIBS)
endif

# ---------- skytest C hook ----------

$(SKYEXT_LUACLIB_PATH)/skytest/hook.so : $(SKYEXT_ROOT)/lualib-src/skytest_hook.c | $(SKYEXT_LUACLIB_PATH)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@ $(LUA_LIBS) $(SKYNET_LIBS)

# ---------- 引擎 C 服务（产物输出到引擎 cservice/）----------

SKYEXT_CSERVICE_PATH = $(SKYEXT_ROOT)/cservice
SKYNET_SRC = $(SKYEXT_ROOT)/skynet/skynet-src

$(SKYEXT_CSERVICE_PATH) :
	mkdir -p $(SKYEXT_CSERVICE_PATH)

$(SKYEXT_CSERVICE_PATH)/profiler.so : $(SKYEXT_ROOT)/service-src/service_profiler.c | $(SKYEXT_CSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I$(SKYNET_SRC) $^ -o $@ $(SKYNET_LINK_LIBS) $(SKYNET_LIBS)

SKYEXT_CSERVICE = profiler

# ---------- skynet 编译 ----------

skynet: $(BIN_PATH)
	cd $(SKYEXT_ROOT)/skynet && $(MAKE) $(PLAT) TLS_MODULE=ltls
	cp -f $(SKYEXT_ROOT)/skynet/skynet$(EXE_SUFFIX) $(BIN_PATH)/
	cp $(SKYEXT_ROOT)/skynet/3rd/lua/lua$(EXE_SUFFIX) $(BIN_PATH)/
	cp $(SKYEXT_ROOT)/skynet/3rd/lua/luac$(EXE_SUFFIX) $(BIN_PATH)/
ifeq ($(PLAT), mingw)
	cp -f $(SKYEXT_ROOT)/skynet/*.dll $(BIN_PATH)/
endif

# ---------- 拷贝第三方 Lua 库 ----------

copy:
	cp -f $(SKYEXT_ROOT)/3rd/binaryheap.lua/src/binaryheap.lua $(SKYEXT_ROOT)/lualib/

# ---------- 引擎 build target ----------

skyext_build: skynet \
	$(SKYEXT_TLS_MODULE) \
	$(foreach v, $(SKYEXT_LUA_CLIB), $(SKYEXT_LUACLIB_PATH)/$(v).so) \
	$(foreach v, $(SKYEXT_CSERVICE), $(SKYEXT_CSERVICE_PATH)/$(v).so) \
	$(SKYEXT_LUACLIB_PATH)/skytest/hook.so \
	copy | $(BIN_PATH)

# ---------- 清理 ----------

clean:
	cd $(SKYEXT_ROOT)/skynet && $(MAKE) clean
	rm -f $(SKYEXT_LUACLIB_PATH)/*.so
	rm -rf $(SKYEXT_LUACLIB_PATH)/*.so.dSYM
	rm -rf $(SKYEXT_LUACLIB_PATH)/skytest
	rm -f $(SKYEXT_CSERVICE_PATH)/*.so
	rm -rf $(SKYEXT_CSERVICE_PATH)/*.so.dSYM
	@for path in "$(BIN_PATH)"/*; do \
		case "$$path" in \
			"$(BIN_PATH)/skyext"|"$(BIN_PATH)/skyext.bat") ;; \
			*) rm -rf "$$path" ;; \
		esac; \
	done

cleanall: clean
	cd $(SKYEXT_ROOT)/skynet && $(MAKE) cleanall
