/*
 * Jump Consistent Hash from Google
 * http://arxiv.org/pdf/1406.2294.pdf
 */

#define LUA_LIB

#include <stdint.h>
#include <lua.h>
#include <lauxlib.h>

int32_t jump_consistent_hash(uint64_t key, int32_t num_buckets) {
    int64_t b = -1;
    int64_t j = 0;
    while (j < num_buckets) {
        b = j;
        key = key * 2862933555777941757ULL + 1;
        j = (b + 1) * ((double)(1LL << 31) / (double)((key >> 33) + 1));
    }
    return b;
}

static int
ljchash(lua_State *L) {
    uint64_t key = (uint64_t)luaL_checkinteger(L, 1);
    int32_t num_buckets = luaL_checkinteger(L, 2);

    if (num_buckets <= 0) {
        return luaL_error(L, "num_buckets must be positive");
    }

    int32_t result = jump_consistent_hash(key, num_buckets);
    lua_pushinteger(L, result);
    return 1;
}

LUAMOD_API int
luaopen_jchash(lua_State *L) {
    luaL_checkversion(L);

    luaL_Reg l[] = {
        { "hash", ljchash },
        { NULL, NULL },
    };

    luaL_newlib(L,l);

    return 1;
}
