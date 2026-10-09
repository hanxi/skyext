/*
 * profiler.c - Lua C module for low-overhead stack sampling
 *
 * TODO: Implement C-level sampling with:
 *   - debug hook injection into target Lua state
 *   - C-side hash table for folded stack aggregation
 *   - Signal-based sampling (vs debug hook) for lower overhead
 *
 * See docs/plans/profiler_design.md for reference projects to research.
 *
 * Target API:
 *   profiler.start(L, freq)    -- start sampling target Lua state
 *   profiler.stop()            -- stop sampling
 *   profiler.result()          -- return folded stack string
 */

#include <lua.h>
#include <lauxlib.h>

static int l_start(lua_State *L) {
    /* TODO: implement C-level sampling */
    lua_pushboolean(L, 0);
    lua_pushstring(L, "C profiler not yet implemented, use Lua profiler module");
    return 2;
}

static int l_stop(lua_State *L) {
    lua_pushboolean(L, 1);
    return 1;
}

static int l_result(lua_State *L) {
    lua_pushnil(L);
    lua_pushstring(L, "C profiler not yet implemented");
    return 2;
}

static const luaL_Reg profiler_funcs[] = {
    {"start", l_start},
    {"stop", l_stop},
    {"result", l_result},
    {NULL, NULL},
};

LUAMOD_API int luaopen_profiler_c(lua_State *L) {
    luaL_newlib(L, profiler_funcs);
    return 1;
}
