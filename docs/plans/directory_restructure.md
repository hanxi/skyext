# 目录结构重构方案：引擎层与游戏逻辑层分离

## 设计目标

1. **skyext 就是引擎**——通用服务器框架，可被多个游戏项目复用
2. **当前游戏代码作为示例**——放在 `example/` 目录，演示如何基于引擎开发游戏
3. **游戏项目独立运行**——新游戏项目引用 skyext 作为 submodule，自身就是完整可运行的项目

---

## 重构后结构

### skyext（引擎仓库）

```
skyext/                                  -- 引擎仓库
├── skynet/                              -- Skynet 框架（submodule）
├── 3rd/                                 -- 第三方库源码
│   ├── lua-cjson/
│   ├── luafilesystem/
│   ├── libsodium/
│   ├── sproto-orm/
│   └── binaryheap.lua/
│
├── lualib/                              -- 引擎 Lua 库
│   ├── cmd_api.lua
│   ├── config.lua
│   ├── dbmgr.lua
│   ├── distributed_lock.lua
│   ├── etcd.lua
│   ├── event_channel_api.lua
│   ├── mongo_conn.lua
│   ├── snowflake.lua
│   ├── id_generator.lua
│   ├── sproto_api.lua
│   ├── timer.lua
│   ├── time.lua
│   ├── res.lua
│   ├── ptype.lua
│   ├── httpc.lua
│   ├── hotfix_checksum.lua
│   ├── loader.lua
│   ├── preload.lua
│   ├── skyext.lua
│   ├── binaryheap.lua
│   ├── orm/                             --   ORM 引擎
│   ├── http_server/                     --   HTTP 服务器框架
│   ├── log/                             --   日志框架
│   ├── util/                            --   通用工具
│   └── entity/                          --   Entity 系统（新增）
│       ├── types.lua
│       ├── router.lua
│       ├── entitymgr.lua
│       ├── client_ext.lua
│       └── reliable_msg.lua
│
├── lualib-src/                          -- 引擎 C 模块源码
│   ├── jchash.c
│   ├── crypto.c
│   ├── traceback.c
│   └── profiler.c                       --   火焰图采样模块
├── luaclib/                             -- 引擎 C 模块编译产物（.so）
├── service-src/                         -- 引擎 C 服务源码
│   └── service_profiler.c               --   火焰图采集服务
├── cservice/                            -- 引擎 C 服务编译产物（.so）
│
├── service/                             -- 引擎服务
│   ├── cluster_discovery.lua
│   ├── mongo_conn.lua
│   ├── mongo_index.lua
│   ├── sproto_loader.lua
│   ├── logger/
│   ├── entity_agent.lua                 --   （新增）
│   └── entity_agentmgr.lua             --   （新增）
│
├── build.mk                             -- 引擎编译规则
├── docs/                                -- 引擎文档
│
└── example/                             -- 示例游戏项目
    ├── nodes/                           --   节点入口
    │   ├── account/
    │   │   ├── main.lua
    │   │   └── lualib/
    │   │       └── account_router.lua
    │   ├── role/
    │   │   ├── main.lua
    │   │   ├── watchdog.lua
    │   │   ├── login/
    │   │   │   ├── main.lua
    │   │   │   ├── client.lua
    │   │   │   └── login_request.lua
    │   │   └── modules/
    │   │       ├── role/
    │   │       │   └── request.lua
    │   │       ├── bag/
    │   │       │   ├── init.lua
    │   │       │   └── request.lua
    │   │       └── mail/
    │   │           ├── init.lua
    │   │           └── request.lua
    │   └── robot/
    │       └── ...
    ├── lualib/                          --   游戏公共库
    │   ├── errcode.lua
    │   ├── jwt.lua
    │   ├── launcher.lua
    │   ├── role_db_api.lua
    │   ├── user_db_api.lua
    │   ├── gm_api.lua
    │   └── gm_router.lua
    ├── service/                         --   游戏服务
    │   ├── gm.lua
    │   ├── gm_sys.lua
    │   └── hotfix.lua
    ├── proto/                           --   协议定义
    ├── schema/                          --   ORM schema
    ├── res/                             --   资源数据
    ├── etc/                             --   配置
    │   ├── core.conf.lua
    │   ├── role1.conf.lua
    │   ├── role2.conf.lua
    │   ├── account1.conf.lua
    │   ├── robot.conf.lua
    │   └── app/
    │       ├── common.app.lua
    │       ├── role1.app.lua
    │       └── ...
    ├── lualib-src/                      --   游戏 C 模块源码（按需添加）
    ├── luaclib/                         --   游戏 C 模块编译产物（.so）
    ├── service-src/                     --   游戏 C 服务源码（按需添加）
    ├── cservice/                        --   游戏 C 服务编译产物（.so）
    ├── hotfix/                          --   热更补丁
    ├── public/                          --   Web 静态资源
    ├── test/                            --   测试
    ├── tools/                           --   构建工具
    └── Makefile                         --   游戏构建入口
```

---

## 关键设计：引擎/游戏路径分离

引擎和游戏代码通过两个路径变量连接：

| 变量 | 含义 | example 中的值 | 独立游戏项目中的值 |
|------|------|---------------|-------------------|
| `skyext_root` | 引擎所在路径 | `"./"` (引擎就是根目录) | `"skyext/"` |
| `game_root` | 游戏代码所在路径 | `"example/"` | `"./"` |

### example 模式（在 skyext 仓库内运行）

```bash
cd skyext
make -C example build    # 编译
./bin/skynet example/etc/role1.conf.lua
```

`example/etc/core.conf.lua`：
```lua
root = "./"

skyext_root = root                   -- 引擎就在根目录
game_root = root .. "example/"       -- 游戏代码在 example/
include (game_root .. "etc/paths.conf.lua")
```

### 独立游戏项目模式

```bash
cd mygame
make build
./bin/skynet etc/role1.conf.lua
```

`mygame/etc/core.conf.lua`：
```lua
root = "./"

skyext_root = root .. "skyext/"      -- 引擎是 submodule
game_root = root                     -- 游戏代码就是根目录
include (game_root .. "etc/paths.conf.lua")
```

### 统一路径配置 `etc/paths.conf.lua`

引擎提供模板，游戏项目拷贝后无需修改：

```lua
-- 服务搜索路径（节点 → 游戏服务 → 引擎服务 → skynet 服务）
luaservice = game_root .. "nodes/" .. start .. "/?.lua;"
luaservice = luaservice .. game_root .. "nodes/?/main.lua;"
luaservice = luaservice .. game_root .. "nodes/" .. start .. "/?/main.lua;"
luaservice = luaservice .. game_root .. "service/?.lua;"
luaservice = luaservice .. game_root .. "service/?/main.lua;"
luaservice = luaservice .. skyext_root .. "service/?.lua;"
luaservice = luaservice .. skyext_root .. "service/?/main.lua;"
luaservice = luaservice .. skyext_root .. "skynet/service/?.lua;"

-- Lua 库搜索路径（游戏库 → 引擎库 → skynet 库）
lua_path = game_root .. "lualib/?.lua;"
lua_path = lua_path .. game_root .. "lualib/?/init.lua;"
lua_path = lua_path .. skyext_root .. "lualib/?.lua;"
lua_path = lua_path .. skyext_root .. "lualib/?/init.lua;"
lua_path = lua_path .. skyext_root .. "skynet/lualib/?.lua;"

-- C 模块搜索路径（游戏 → 引擎 → skynet）
lua_cpath = game_root .. "luaclib/?.so;"
lua_cpath = lua_cpath .. skyext_root .. "luaclib/?.so;"
lua_cpath = lua_cpath .. skyext_root .. "skynet/luaclib/?.so;"

-- C 服务搜索路径（游戏 → 引擎 → skynet）
cpath = game_root .. "cservice/?.so;"
cpath = cpath .. skyext_root .. "cservice/?.so;"
cpath = cpath .. skyext_root .. "skynet/cservice/?.so;"

lualoader = skyext_root .. "lualib/loader.lua"
preload = skyext_root .. "lualib/preload.lua"
```

### `lualib/loader.lua` 修改

loader 需要感知 `game_root`（从 skynet config 读取）：

```lua
local game_root = skynet.getenv("game_root") or "./"

-- 节点路径 prepend 到 package.path 前面，确保优先级高于引擎层和 skynet 层
-- （搜索优先级：服务独有 > 节点根目录 > 节点独有库 > 游戏公共库 > 引擎库 > skynet 库）
local node_paths =
    game_root .. "nodes/" .. start .. "/?.lua;" ..
    game_root .. "nodes/" .. start .. "/?/init.lua;" ..
    game_root .. "nodes/" .. start .. "/lualib/?.lua;" ..
    game_root .. "nodes/" .. start .. "/lualib/?/init.lua;"
package.path = node_paths .. package.path
```

### 完整搜索顺序

| 优先级 | 路径 | 层次 |
|--------|------|------|
| 1 | `<service>/lualib/` | 服务独有 |
| 2 | `{game}/nodes/<start>/` | 节点根目录 |
| 3 | `{game}/nodes/<start>/lualib/` | 节点独有库 |
| 4 | `{game}/lualib/` | 游戏公共库 |
| 5 | `{skyext}/lualib/` | 引擎库 |
| 6 | `{skyext}/skynet/lualib/` | Skynet 库 |

---

## 构建系统

### `build.mk`（引擎编译规则）

引擎提供编译基础设施（变量、skynet 编译、引擎 C 模块），游戏 Makefile include 后复用。

每一层的编译产物输出到**自己的目录**，与 skynet 的目录命名保持一致：

| 层次 | 源码目录 | 产物目录 |
|------|----------|----------|
| skynet | `skynet/lualib-src/`, `skynet/service-src/` | `skynet/luaclib/`, `skynet/cservice/` |
| 引擎 | `lualib-src/` | `luaclib/` |
| 游戏 | `example/lualib-src/`, `example/service-src/` | `example/luaclib/`, `example/cservice/` |

```makefile
# 由游戏 Makefile 设置
SKYEXT_ROOT ?= ./

LUA_DIR ?= $(SKYEXT_ROOT)/skynet/3rd/lua
LUA_INC ?= $(LUA_DIR)
BIN_PATH ?= bin

# ---------- 通用编译参数 ----------

SHARED := -fPIC --shared
CFLAGS = -g -O2 -Wall -I$(LUA_INC) $(MYCFLAGS)

# ---------- 引擎 C 模块（产物输出到引擎自己的 luaclib/）----------

SKYEXT_LUACLIB_PATH = $(SKYEXT_ROOT)/luaclib
SKYEXT_CSERVICE_PATH = $(SKYEXT_ROOT)/cservice
SKYEXT_LUA_CLIB = jchash cjson traceback lfs crypto profiler
SKYEXT_CSERVICE = profiler

$(SKYEXT_LUACLIB_PATH) :
	mkdir -p $(SKYEXT_LUACLIB_PATH)

$(SKYEXT_CSERVICE_PATH) :
	mkdir -p $(SKYEXT_CSERVICE_PATH)

$(SKYEXT_LUACLIB_PATH)/jchash.so : $(SKYEXT_ROOT)/lualib-src/jchash.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

$(SKYEXT_LUACLIB_PATH)/cjson.so : $(SKYEXT_ROOT)/3rd/lua-cjson/lua_cjson.c \
                                   $(SKYEXT_ROOT)/3rd/lua-cjson/strbuf.c \
                                   $(SKYEXT_ROOT)/3rd/lua-cjson/fpconv.c | $(SKYEXT_LUACLIB_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I$(SKYEXT_ROOT)/3rd/lua-cjson $^ -o $@

# ... 其他引擎 C 模块同理

# ---------- 引擎 C 服务（产物输出到引擎自己的 cservice/）----------

$(SKYEXT_CSERVICE_PATH)/profiler.so : $(SKYEXT_ROOT)/service-src/service_profiler.c | $(SKYEXT_CSERVICE_PATH)
	$(CC) $(CFLAGS) $(SHARED) -I$(SKYEXT_ROOT)/skynet/skynet-src $^ -o $@

# ---------- skynet 编译 ----------

skynet: $(BIN_PATH)
	cd $(SKYEXT_ROOT)/skynet && $(MAKE) $(PLAT)
	cp -f $(SKYEXT_ROOT)/skynet/skynet$(EXE_SUFFIX) $(BIN_PATH)/
	cp $(SKYEXT_ROOT)/skynet/3rd/lua/lua$(EXE_SUFFIX) $(BIN_PATH)/

copy:
	cp -rf $(SKYEXT_ROOT)/3rd/sproto-orm/orm $(SKYEXT_ROOT)/lualib/
	cp -f $(SKYEXT_ROOT)/3rd/binaryheap.lua/src/binaryheap.lua $(SKYEXT_ROOT)/lualib/

# ---------- 引擎 build target ----------

skyext_build: skynet \
	$(foreach v, $(SKYEXT_LUA_CLIB), $(SKYEXT_LUACLIB_PATH)/$(v).so) \
	$(foreach v, $(SKYEXT_CSERVICE), $(SKYEXT_CSERVICE_PATH)/$(v).so) copy | $(BIN_PATH)
```

### `example/Makefile`（示例游戏）

演示游戏如何编译自己的 C 模块和 C 服务，产物输出到游戏自己的 `luaclib/` 和 `cservice/`：

```makefile
SKYEXT_ROOT = ..
BIN_PATH = $(SKYEXT_ROOT)/bin
include $(SKYEXT_ROOT)/build.mk

# ---------- 游戏 C 模块（产物输出到游戏自己的 luaclib/）----------

GAME_LUACLIB_PATH = luaclib
GAME_CSERVICE_PATH = cservice
GAME_LUA_CLIB =
GAME_CSERVICE =

$(GAME_LUACLIB_PATH) :
	mkdir -p $(GAME_LUACLIB_PATH)

$(GAME_CSERVICE_PATH) :
	mkdir -p $(GAME_CSERVICE_PATH)

# ---------- 游戏 C 模块编译规则（按需添加）----------
# 示例：
# GAME_LUA_CLIB += mygame
# $(GAME_LUACLIB_PATH)/mygame.so : lualib-src/mygame.c | $(GAME_LUACLIB_PATH)
# 	$(CC) $(CFLAGS) $(SHARED) $^ -o $@

# ---------- 总构建 ----------

build: skyext_build \
	$(foreach v, $(GAME_LUA_CLIB), $(GAME_LUACLIB_PATH)/$(v).so) \
	$(foreach v, $(GAME_CSERVICE), $(GAME_CSERVICE_PATH)/$(v).so)
	mkdir -p logs

# ---------- 游戏资源构建 ----------

proto:
	@mkdir -p build/proto
	./tools/gen_proto.sh

schema:
	./tools/gen_schema.sh

clean:
	rm -f $(GAME_LUACLIB_PATH)/*.so
	rm -f $(GAME_CSERVICE_PATH)/*.so
```

### 独立游戏项目 `Makefile`（结构相同，SKYEXT_ROOT 不同）

```makefile
SKYEXT_ROOT = skyext
include $(SKYEXT_ROOT)/build.mk

GAME_LUACLIB_PATH = luaclib
GAME_CSERVICE_PATH = cservice
GAME_LUA_CLIB =
GAME_CSERVICE =

$(GAME_LUACLIB_PATH) :
	mkdir -p $(GAME_LUACLIB_PATH)

$(GAME_CSERVICE_PATH) :
	mkdir -p $(GAME_CSERVICE_PATH)

# 游戏 C 模块编译规则（按需添加）

build: skyext_build \
	$(foreach v, $(GAME_LUA_CLIB), $(GAME_LUACLIB_PATH)/$(v).so) \
	$(foreach v, $(GAME_CSERVICE), $(GAME_CSERVICE_PATH)/$(v).so)
	mkdir -p logs

proto:
	@mkdir -p build/proto
	./tools/gen_proto.sh

schema:
	./tools/gen_schema.sh
```

### 构建产物分布

```
skyext/                            -- 引擎仓库
├── skynet/
│   ├── luaclib/                   -- skynet 的 C 模块 (.so)
│   └── cservice/                  -- skynet 的 C 服务 (.so)
├── luaclib/                       -- 引擎的 C 模块 (.so)
├── cservice/                      -- 引擎的 C 服务 (.so)
├── bin/                           -- 可执行文件 (skynet, lua, luac)
└── example/
    ├── luaclib/                   -- 游戏的 C 模块 (.so)
    └── cservice/                  -- 游戏的 C 服务 (.so)

mygame/                            -- 独立游戏项目
├── skyext/                        -- 引擎 (submodule)
│   ├── skynet/
│   │   ├── luaclib/               -- skynet 的 C 模块
│   │   └── cservice/              -- skynet 的 C 服务
│   └── luaclib/                   -- 引擎的 C 模块
├── luaclib/                       -- 游戏的 C 模块
├── cservice/                      -- 游戏的 C 服务
└── bin/                           -- 可执行文件
```

### 构建流程

1. `skyext_build` 先编译 skynet（产物在 `skynet/luaclib/`、`skynet/cservice/`），再编译引擎 C 模块（产物在引擎 `luaclib/`）
2. 游戏 `build` 调用 `skyext_build`，再编译游戏自己的 C 模块和 C 服务（产物在游戏 `luaclib/`、`cservice/`）
3. 运行时 Lua 通过 `lua_cpath` 按优先级搜索三层 `luaclib/`，通过 `cpath` 搜索三层 `cservice/`

---

## 新游戏项目创建流程

```bash
mkdir mygame && cd mygame
git init

# 1. 引入引擎
git submodule add <skyext-url> skyext

# 2. 创建目录结构（lualib-src/service-src 按需创建，初始项目不需要 C 模块）
mkdir -p nodes lualib service proto schema res etc/app hotfix public test tools

# 3. 创建配置
cat > etc/core.conf.lua << 'EOF'
root = "./"
skyext_root = root .. "skyext/"
game_root = root
include (game_root .. "etc/paths.conf.lua")
EOF

cp skyext/etc/paths.conf.lua.template etc/paths.conf.lua

# 4. 创建 Makefile
cat > Makefile << 'EOF'
SKYEXT_ROOT = skyext
include $(SKYEXT_ROOT)/build.mk

# 游戏 C 模块（按需添加）
GAME_LUA_CLIB =

build: skyext_build \
	$(foreach v, $(GAME_LUA_CLIB), $(GAME_LUACLIB_PATH)/$(v).so)
	mkdir -p logs

proto:
	@mkdir -p build/proto
	./tools/gen_proto.sh

schema:
	./tools/gen_schema.sh
EOF

# 5. 编译运行
make build
./bin/skynet etc/role1.conf.lua
```

---

## 分层判定标准

| 层次 | 位置 | 标准 | 举例 |
|------|------|------|------|
| Skynet | `skynet/` | Skynet 框架本身 | skynet.call, gate, cluster |
| 引擎 | `lualib/`, `service/`, `lualib-src/` | 换一个游戏能直接用 | dbmgr, entity, orm, timer, cluster_discovery |
| 游戏 | `example/` (或独立项目根) | 跟当前游戏业务绑定 | errcode, jwt, gm 命令, 协议, schema |

### 边界案例

| 文件 | 归属 | 理由 |
|------|------|------|
| `sproto_api.lua` | 引擎 | 协议分发框架，具体协议在游戏层 |
| `res.lua` | 引擎 | sharetable 热加载机制，具体资源在游戏层 |
| `http_server/` | 引擎 | HTTP 框架，路由在游戏层注册 |
| `gm_api.lua` | 游戏 | GM 注册和接口跟具体业务耦合 |
| `hotfix.lua` | 游戏 | 补丁格式和校验跟项目相关 |
| `jwt.lua` | 游戏 | 认证方案是游戏选型 |
| `launcher.lua` | 游戏 | 启动哪些服务由游戏决定 |

### 错误码分层

`errcode` 按层次拆分为两个文件：

- **引擎层** `lualib/errcode.lua`：只定义引擎通用的错误码（0-99 保留），如 `OK`、`PARAM_ERROR`、`AUTH_FAILED`、`DB_ERROR`，以及 Entity 系统相关的错误码（如 `NOT_THIS_NODE`、`LOCAK_FAILED`）
- **游戏层** `example/lualib/errcode.lua`：`require` 引擎层 errcode 后追加游戏业务错误码（100+），如 `ROLE_NOT_EXIST`、`ROLE_TOO_MANY`、`TOKEN_ERROR` 等

```lua
-- example/lualib/errcode.lua（游戏层）
local errcode = require "skyext.errcode"  -- 引擎层基础错误码

errcode.ROLE_NOT_EXIST = 100
errcode.ROLE_TOO_MANY = 101
errcode.TOKEN_ERROR = 102
errcode.PROTO_CHECKSUM = 103
errcode.SERVER_NOT_EXIST = 104

return errcode
```

游戏层的 `lualib/` 搜索优先级高于引擎层（优先级 4 > 5），因此游戏代码 `require "errcode"` 会加载游戏层版本，自动包含引擎层定义。引擎内部代码直接 `require "errcode"` 只拿到引擎层的基础错误码。

---

## 文件迁移清单

### 留在引擎根目录（不动）

```
skynet/          -- submodule
3rd/             -- 第三方库
lualib-src/      -- C 模块源码
build.mk         -- 编译规则
docs/            -- 引擎文档
```

### `lualib/` 拆分

**留在 `lualib/`（引擎）：**
```
cmd_api.lua, config.lua, dbmgr.lua, distributed_lock.lua,
etcd.lua, event_channel_api.lua, mongo_conn.lua, snowflake.lua,
id_generator.lua, sproto_api.lua, timer.lua, time.lua, res.lua,
ptype.lua, httpc.lua, hotfix_checksum.lua, loader.lua, preload.lua,
skyext.lua, binaryheap.lua,
orm/, http_server/, log/, util/
```

**拆分（引擎层保留通用错误码 0-99，游戏层追加业务错误码 100+）：**
```
errcode.lua → lualib/errcode.lua（引擎通用） + example/lualib/errcode.lua（游戏业务）
```

**迁到 `example/lualib/`（游戏）：**
```
jwt.lua, launcher.lua,
role_db_api.lua, user_db_api.lua,
gm_api.lua, gm_router.lua
```

### `service/` 拆分

**留在 `service/`（引擎）：**
```
cluster_discovery.lua, mongo_conn.lua, mongo_index.lua,
sproto_loader.lua, logger/
```

**迁到 `example/service/`（游戏）：**
```
gm.lua, gm_sys.lua, hotfix.lua
```

### `app/` → `example/nodes/`

```
app/account/ → example/nodes/account/
app/role/    → example/nodes/role/     （内部结构按 entity 迁移方案简化）
app/robot/   → example/nodes/robot/
```

### 顶层目录迁入 `example/`

```
proto/   → example/proto/
schema/  → example/schema/
res/     → example/res/
etc/     → example/etc/
hotfix/  → example/hotfix/
public/  → example/public/
test/    → example/test/
tools/   → example/tools/
```

### 删除

```
tools/gen_roleagent_modules.lua        -- 不再需要代码生成
app/role/roleagent/modules/init.lua    -- 不再需要生成的注册文件
Makefile 中 autocode target            -- 删除
```

---

## 验证要点

1. **example 启动**：`cd skyext && ./bin/skynet example/etc/role1.conf.lua` 正常运行
2. **路径解析**：`require "dbmgr"` 走引擎层，`require "errcode"` 走游戏层
3. **模块发现**：entity_agentmgr 正确扫描 `example/nodes/role/modules/`
4. **独立项目**：新建游戏项目，`git submodule add <url> skyext`，验证构建和启动正常
5. **覆盖机制**：游戏层可覆盖引擎同名模块（优先级 4 > 5），如 `require "errcode"` 在游戏层加载到含业务错误码的扩展版本
6. **构建**：`make build` / `make proto` / `make schema` 在 example 和独立项目中均正常工作
