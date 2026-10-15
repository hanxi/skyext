/*
 * skytest_hook.c - C accelerated line coverage hook for Lua 5.4+
 *
 * Lua API:
 *   local hook = require "skytest.hook"
 *   hook.start(stats)                     -- Install hook on current coroutine
 *   hook.stop()                           -- Remove hook
 *   hook.install_on(co, stats)            -- Install hook on a specific coroutine
 *   hook.wrap_create(orig_create, stats)  -- Return wrapped coroutine.create
 *   hook.set_filter(include, exclude)     -- Set path filters (tables of strings)
 *   hook.proto_lines(f)                   -- All executable lines of f, nested functions included
 */

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <string.h>
#include <stdlib.h>

/* Proto 树遍历需要内核布局；LUA_INC 已指向 skynet/3rd/lua */
#include <lobject.h>

#define STATS_KEY "skytest_stats"
#define MAX_FILTERS 32

/*
 * Process-wide filters: heap-allocated copies safe across VMs.
 * Write-once semantics: the first VM to call set_filter populates these;
 * all subsequent calls are no-ops. This avoids data races between skynet
 * worker threads (one writing via set_filter while another reads in hook_fn).
 *
 * g_filter_state transitions: 0 (unset) → 1 (writing) → 2 (ready).
 * CAS on 0→1 ensures exactly one writer. A full memory barrier before
 * setting state=2 ensures all pointer/count writes are globally visible
 * before any reader enters check_filter.
 */
static char *g_include[MAX_FILTERS];
static int g_include_count = 0;
static char *g_exclude[MAX_FILTERS];
static int g_exclude_count = 0;
static volatile int g_filter_state = 0;

static int
check_filter(const char *source) {
    const char *path = source + 1; /* skip '@' */

    if (g_exclude_count > 0) {
        for (int i = 0; i < g_exclude_count; i++) {
            if (strstr(path, g_exclude[i]) != NULL)
                return 0;
        }
    }

    if (g_include_count > 0) {
        for (int i = 0; i < g_include_count; i++) {
            if (strstr(path, g_include[i]) != NULL)
                return 1;
        }
        return 0;
    }

    return 1;
}

static void
hook_fn(lua_State *L, lua_Debug *ar) {
    if (ar->event != LUA_HOOKLINE)
        return;

    if (lua_getinfo(L, "S", ar) == 0)
        return;

    const char *source = ar->source;
    if (source == NULL || source[0] != '@')
        return;

    if (g_filter_state == 2) {
        __sync_synchronize();
        if (!check_filter(source))
            return;
    }

    /* Get stats table from this VM's registry */
    lua_pushlightuserdata(L, (void *)STATS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        return;
    }

    /* Get or create stats[source] */
    lua_pushstring(L, source);
    lua_rawget(L, -2);
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_pushstring(L, source);
        lua_newtable(L);
        lua_rawset(L, -3);
        lua_pushstring(L, source);
        lua_rawget(L, -2);
    }

    int line = ar->currentline;
    lua_pushinteger(L, line);
    lua_rawget(L, -2);
    lua_Integer count = lua_tointegerx(L, -1, NULL);
    lua_pop(L, 1);

    lua_pushinteger(L, line);
    lua_pushinteger(L, count + 1);
    lua_rawset(L, -3);

    lua_pop(L, 2);
}

static void
set_stats(lua_State *L, int stats_idx) {
    lua_pushlightuserdata(L, (void *)STATS_KEY);
    lua_pushvalue(L, stats_idx);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

static int
lstart(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    set_stats(L, 1);
    lua_sethook(L, hook_fn, LUA_MASKLINE, 0);
    return 0;
}

static int
lstop(lua_State *L) {
    lua_sethook(L, NULL, 0, 0);
    lua_pushlightuserdata(L, (void *)STATS_KEY);
    lua_pushnil(L);
    lua_rawset(L, LUA_REGISTRYINDEX);
    return 0;
}

static int
linstall_on(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTHREAD);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_State *co = lua_tothread(L, 1);

    lua_pushlightuserdata(co, (void *)STATS_KEY);
    lua_pushvalue(L, 2);
    lua_xmove(L, co, 1);
    lua_rawset(co, LUA_REGISTRYINDEX);

    lua_sethook(co, hook_fn, LUA_MASKLINE, 0);
    return 0;
}

static int
lwrapped_create(lua_State *L) {
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);

    lua_State *co = lua_tothread(L, -1);

    lua_pushvalue(L, lua_upvalueindex(2));
    lua_xmove(L, co, 1);
    lua_pushlightuserdata(co, (void *)STATS_KEY);
    lua_insert(co, -2);
    lua_rawset(co, LUA_REGISTRYINDEX);

    lua_sethook(co, hook_fn, LUA_MASKLINE, 0);

    return 1;
}

static int
lwrap_create(lua_State *L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    luaL_checktype(L, 2, LUA_TTABLE);
    lua_pushvalue(L, 1);
    lua_pushvalue(L, 2);
    lua_pushcclosure(L, lwrapped_create, 2);
    return 1;
}

static int
lget_stats(lua_State *L) {
    lua_pushlightuserdata(L, (void *)STATS_KEY);
    lua_rawget(L, LUA_REGISTRYINDEX);
    return 1;
}

/*
 * hook.set_filter(include_table, exclude_table)
 * Write-once: the first caller populates the global arrays; all subsequent
 * calls from other VMs are no-ops (they share the same env-var config).
 * CAS on g_filter_state 0→1 ensures exactly one writer.
 */
static int
lset_filter(lua_State *L) {
    if (!__sync_bool_compare_and_swap(&g_filter_state, 0, 1))
        return 0;

    if (lua_istable(L, 1)) {
        int len = (int)lua_rawlen(L, 1);
        if (len > MAX_FILTERS) len = MAX_FILTERS;
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, 1, i);
            if (lua_isstring(L, -1)) {
                char *dup = strdup(lua_tostring(L, -1));
                if (dup) g_include[g_include_count++] = dup;
            }
            lua_pop(L, 1);
        }
    }

    if (lua_istable(L, 2)) {
        int len = (int)lua_rawlen(L, 2);
        if (len > MAX_FILTERS) len = MAX_FILTERS;
        for (int i = 1; i <= len; i++) {
            lua_rawgeti(L, 2, i);
            if (lua_isstring(L, -1)) {
                char *dup = strdup(lua_tostring(L, -1));
                if (dup) g_exclude[g_exclude_count++] = dup;
            }
            lua_pop(L, 1);
        }
    }

    __sync_synchronize();
    g_filter_state = 2;
    return 0;
}

/*
 * ---------- 可执行行扫描 ----------
 *
 * debug.getinfo(f, "L").activelines 只返回 f 自己这一个 Proto 的行，
 * 嵌套函数体各是独立 Proto，一行都不在里面。拿它当覆盖率分母，
 * 等于把几乎所有函数体排除在统计之外。这里按 Proto 树递归补全。
 *
 * 取行逻辑与内核 collectvalidlines（ldebug.c）一致，但不调用
 * luaG_getfuncline —— 它是 LUAI_FUNC，带 internal 可见性，.so 里链不到。
 * lineinfo[pc] 为 ABSLINEINFO 时内核最终取的就是 abslineinfo 中 pc 相等
 * 那条的 line，而我们按 pc 递增遍历，用一个游标扫过去即可，结果等价。
 */

/* 同 ldebug.h：lineinfo 中标记“此处行号改从 abslineinfo 取” */
#define SKYTEST_ABSLINEINFO (-0x80)

static int
next_line(const Proto *p, int currentline, int pc, int *abs_cursor) {
    if (p->lineinfo[pc] != SKYTEST_ABSLINEINFO)
        return currentline + p->lineinfo[pc];
    while (*abs_cursor < p->sizeabslineinfo && p->abslineinfo[*abs_cursor].pc < pc)
        (*abs_cursor)++;
    if (*abs_cursor < p->sizeabslineinfo && p->abslineinfo[*abs_cursor].pc == pc)
        return p->abslineinfo[*abs_cursor].line;
    return currentline;
}

static void
collect_proto_lines(lua_State *L, const Proto *p, int tidx) {
    if (p->lineinfo != NULL) {
        int currentline = p->linedefined;
        int abs_cursor = 0;
        int i = 0;
        if (isvararg(p)) {
            /* 首条指令是 OP_VARARGPREP，不对应源码行 */
            currentline = next_line(p, currentline, 0, &abs_cursor);
            i = 1;
        }
        for (; i < p->sizelineinfo; i++) {
            currentline = next_line(p, currentline, i, &abs_cursor);
            lua_pushboolean(L, 1);
            lua_rawseti(L, tidx, currentline);
        }
    }
    for (int j = 0; j < p->sizep; j++) {
        collect_proto_lines(L, p->p[j], tidx);
    }
}

static int
lproto_lines(lua_State *L) {
    const LClosure *cl;
    luaL_checktype(L, 1, LUA_TFUNCTION);
    if (lua_iscfunction(L, 1))
        return luaL_argerror(L, 1, "Lua function expected, got C function");
    cl = (const LClosure *)lua_topointer(L, 1);
    if (cl == NULL || cl->p == NULL)
        return luaL_argerror(L, 1, "cannot inspect function");
    luaL_checkstack(L, 4, "proto_lines");
    lua_newtable(L);
    collect_proto_lines(L, cl->p, lua_gettop(L));
    return 1;
}

static const luaL_Reg hook_funcs[] = {
    {"proto_lines", lproto_lines},
    {"start", lstart},
    {"stop", lstop},
    {"install_on", linstall_on},
    {"wrap_create", lwrap_create},
    {"get_stats", lget_stats},
    {"set_filter", lset_filter},
    {NULL, NULL}
};

LUAMOD_API int
luaopen_skytest_hook(lua_State *L) {
    luaL_newlib(L, hook_funcs);
    return 1;
}
