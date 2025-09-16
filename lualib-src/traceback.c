#include <stddef.h>
#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <stdio.h>

#ifdef DEBUGLOG
static void
dump_stack(lua_State *L, const char * name) {
    int top = lua_gettop(L);
    for (int i=1; i<=top; i++) {
        const char * str = luaL_tolstring(L, i, NULL);
        printf("%s i:%d tp:%s v:%s\n", name, i, lua_typename(L, lua_type(L, i)), str);
        lua_pop(L, 1);
    }
}
#else
#define dump_stack(L, name)
#endif

#if (UINT_MAX >> 30) >= 1
typedef unsigned int utfint;
#else
typedef unsigned long utfint;
#endif

#define MAXUNICODE	0x10FFFFu
#define MAXUTF		0x7FFFFFFFu

static const char *
utf8_decode (const char *s) {
    static const utfint limits[] =
        {~(utfint)0, 0x80, 0x800, 0x10000u, 0x200000u, 0x4000000u};
    unsigned int c = (unsigned char)s[0];
    utfint res = 0;  // final result
    if (c < 0x80) { // ascii?
        res = c;
    } else {
        int count = 0;  // to count number of continuation bytes
        for (; c & 0x40; c <<= 1) {  // while it needs continuation bytes...
            unsigned int cc = (unsigned char)s[++count];  // read next byte
            if ((cc & 0xC0) != 0x80) { // not a continuation byte?
                return NULL;  // invalid byte sequence
            }
            res = (res << 6) | (cc & 0x3F);  // add lower 6 bits from cont. byte
        }
        res |= ((utfint)(c & 0x7F) << (count * 5));  // add first byte
        if (count > 5 || res > MAXUTF || res < limits[count]) {
            return NULL;  // invalid byte sequence
        }
        s += count;  // skip continuation bytes read
    }

    // check for invalid code points; too large or surrogates
    if (res > MAXUNICODE || (0xD800u <= res && res <= 0xDFFFu)) {
        return NULL;
    }

    return s + 1;  // +1 to include first byte
}

// from strlib
// translate a relative string position: negative means back from end
static lua_Integer u_posrelat (lua_Integer pos, size_t len) {
    if (pos >= 0) {
        return pos;
    } else if (0u - (size_t)pos > len) {
        return 0;
    } else {
        return (lua_Integer)len + pos + 1;
    }
}

static int
check_utf8(const char *s, size_t len) {
    lua_Integer posi = u_posrelat(1, len);
    lua_Integer posj = u_posrelat(-1, len);

    while (posi <= posj && posi < len) {
        const char *s1 = utf8_decode(s + posi);
        if (s1 == NULL) {  // conversion error?
            return 0;
        }
        posi = s1 - s;
    }
    return 1;
}

int buffer_append(char *buff, int *n, const char *s, size_t sz, int max_len) {
    int r = max_len - *n;
    if (r <= 0) {
        return 0;
    }

    char *b = buff + *n;
    if (sz > r) {
        sz = r;
    }
    memcpy(b, s, sz * sizeof(char));
    *n += sz;
    return 1;
}

static const char *char2hex[256] = {
    "00","01","02","03","04","05","06","07","08","09","0a","0b","0c","0d","0e","0f",
    "10","11","12","13","14","15","16","17","18","19","1a","1b","1c","1d","1e","1f",
    "20","21","22","23","24","25","26","27","28","29","2a","2b","2c","2d","2e","2f",
    "30","31","32","33","34","35","36","37","38","39","3a","3b","3c","3d","3e","3f",
    "40","41","42","43","44","45","46","47","48","49","4a","4b","4c","4d","4e","4f",
    "50","51","52","53","54","55","56","57","58","59","5a","5b","5c","5d","5e","5f",
    "60","61","62","63","64","65","66","67","68","69","6a","6b","6c","6d","6e","6f",
    "70","71","72","73","74","75","76","77","78","79","7a","7b","7c","7d","7e","7f",
    "80","81","82","83","84","85","86","87","88","89","8a","8b","8c","8d","8e","8f",
    "90","91","92","93","94","95","96","97","98","99","9a","9b","9c","9d","9e","9f",
    "a0","a1","a2","a3","a4","a5","a6","a7","a8","a9","aa","ab","ac","ad","ae","af",
    "b0","b1","b2","b3","b4","b5","b6","b7","b8","b9","ba","bb","bc","bd","be","bf",
    "c0","c1","c2","c3","c4","c5","c6","c7","c8","c9","ca","cb","cc","cd","ce","cf",
    "d0","d1","d2","d3","d4","d5","d6","d7","d8","d9","da","db","dc","dd","de","df",
    "e0","e1","e2","e3","e4","e5","e6","e7","e8","e9","ea","eb","ec","ed","ee","ef",
    "f0","f1","f2","f3","f4","f5","f6","f7","f8","f9","fa","fb","fc","fd","fe","ff",
};

static const char *char2escape[256] = {
    "\\x00", "\\x01", "\\x02", "\\x03",
    "\\x04", "\\x05", "\\x06", "\\x07",
    "\\b", "\\t", "\\n", "\\x0b",
    "\\f", "\\r", "\\x0e", "\\x0f",
    "\\x10", "\\x11", "\\x12", "\\x13",
    "\\x14", "\\x15", "\\x16", "\\x17",
    "\\x18", "\\x19", "\\x1a", "\\x1b",
    "\\x1c", "\\x1d", "\\x1e", "\\x1f",
    NULL, NULL, "\\\"", NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, "\\\\", NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, "\\x7f",
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
};

#define buffer_append_str(buff, n, str, max_len) buffer_append((buff), (n), (str), strlen(str), (max_len))

static void
seri_string(lua_State *L, int vindex, char *buff, int *n, int max_string, int max_len) {
    size_t len;
    const char *str = lua_tolstring(L, vindex, &len);
    buffer_append(buff, n, "\"", 1, max_len);

    int l = len < max_string ? len : max_string;
    if (check_utf8(str, l) == 1) {
        for (int i=0; i<l; i++) {
            const char *esc = char2escape[(unsigned char)str[i]];
            if (esc) {
                buffer_append_str(buff, n, esc, max_len);
            } else {
                buffer_append(buff, n, &str[i], 1, max_len);
            }
        }

    } else {
        // bin to hex
        buffer_append(buff, n, "0x", 2, max_len);
        for (int i=0; i<l; i++) {
            const char *hex = char2hex[(unsigned char)str[i]];
            buffer_append_str(buff, n, hex, max_len);
        }
    }

    if (len > max_string) {
        buffer_append(buff, n, "...", 3, max_len);
    } else {
        buffer_append(buff, n, "\"", 1, max_len);
    }
}

static void
seri_other(lua_State *L, int vindex, char *buff, int *n, int max_len) {
    size_t l;
    const char *s = luaL_tolstring(L, vindex, &l);
    buffer_append(buff, n, s, l, max_len);
    lua_pop(L, 1);
}

static void
_append_skey(char *buff, int *n, int *comma, const char *skey, size_t skeylen, int max_len) {
    if (*comma) {
        buffer_append(buff, n, ",", 1, max_len);
    } else {
        *comma = 1;
    }
    buffer_append(buff, n, skey, skeylen, max_len);
    buffer_append(buff, n, "=", 1, max_len);
}

static void
_seri_table(lua_State *L, int tbl_index, char *buff, int *n, const char *parent,
            int mark_index, int assign_index,
            int depth, int limit, int max_string, int max_len) {
    if (--depth < 0 || *n >= max_len) {
        seri_other(L, tbl_index, buff, n, max_len);
        return;
    }

    // mark[tbl] = parent
    lua_pushvalue(L, tbl_index);
    lua_pushstring(L, parent);
    lua_rawset(L, mark_index);

    buffer_append(buff, n, "{", 1, max_len);

    int comma = 0;
    int ktype = 0;
    int vtype = 0;
    lua_pushnil(L);
    while (lua_next(L, tbl_index) != 0) {
        if (--limit < 0) {
            buffer_append(buff, n, "...", 3, max_len);
            lua_pop(L, 2); // pop value, key
            break;
        }


        int kindex = lua_gettop(L) - 1; // -2:key
        int vindex = lua_gettop(L); // -1:value
        const char * keystr = luaL_tolstring(L, kindex, NULL);
        // stack: key, value, keystr
        ktype = lua_type(L, kindex);
        if (ktype == LUA_TNUMBER) {
            lua_pushfstring(L, "[%s]", keystr);
        } else {
            lua_pushfstring(L, "['%s']", keystr);
        }
        // stack: key, value, keystr, skey
        size_t skeylen = 0;
        const char * skey = lua_tolstring(L, -1, &skeylen);
        // stack: key, value, keystr, skey

        vtype = lua_type(L, vindex);
        switch (vtype) {
            case LUA_TSTRING:
                _append_skey(buff, n, &comma, skey, skeylen, max_len);
                seri_string(L, vindex, buff, n, max_string, max_len);
                break;
            case LUA_TTABLE:
                lua_pushstring(L, parent);
                // stack: key, value, keystr, skey, parent
                lua_pushstring(L, skey);
                // stack: key, value, keystr, skey, parent, skey
                lua_concat(L, 2);
                // stack: key, value, keystr, [key], dotkey
                const char *dotkey = lua_tostring(L, -1);

                // if mark[v] then
                lua_pushvalue(L, vindex);
                lua_rawget(L, mark_index);
                // stack: key, value, keystr, skey, dotkey, mark[v]
                if (!lua_isnil(L, -1)) {
                    int sz = lua_rawlen(L, assign_index);
                    lua_pushfstring(L, "%s = %s", dotkey, lua_tostring(L, -1));
                    lua_rawseti(L, assign_index, sz+1);
                    // stack: key, value, keystr, skey, dotkey, mark[v]
                } else {
                    _append_skey(buff, n, &comma, skey, skeylen, max_len);
                    // stack: key, value, keystr, skey
                    _seri_table(L, vindex, buff, n, dotkey, mark_index, assign_index, depth, limit, max_string, max_len);
                }
                lua_pop(L, 2); // pop nil/mark[v], dotkey
                // stack: key, value, keystr, skey
                break;
            default:
                _append_skey(buff, n, &comma, skey, skeylen, max_len);
                seri_other(L, vindex, buff, n, max_len);
                break;
        }
        // stack: key, value, keystr, skey
        lua_pop(L, 3); // pop skey, keystr, value
        // stack: key
    }
    buffer_append(buff, n, "}", 1, max_len);
}


static void
seri_table(lua_State *L, int tbl_index, char *buff, int *n, const char *name,
           int max_depth, int max_ele, int max_string, int max_len) {
    //mark = {}
    lua_newtable(L);
    int mark_index = lua_gettop(L);

    //assign = {}
    lua_newtable(L);
    int assign_index = lua_gettop(L);

    // stack: tbl, mark, assign
    _seri_table(L, tbl_index, buff, n, name, mark_index, assign_index, max_depth, max_ele, max_string, max_len);
    // stack: tbl, mark, assign

    // append assign
    int sz = lua_rawlen(L, assign_index);
    for (size_t i = 1; i <= sz; i++) {
        buffer_append(buff, n, "\n\t\t\t", 4, max_len);
        lua_rawgeti(L, assign_index, i);
        size_t l = 0;
        const char * s = lua_tolstring(L, -1, &l);
        buffer_append(buff, n, s, l, max_len);
        lua_pop(L, 1);
    }
    lua_pop(L, 2); // pop assign, mark
    // stack: tbl
}

// input top is value, no change stack
static void
seri(lua_State *L, char *buff, int *n, const char *name,
     int max_depth, int max_ele, int max_string, int max_len) {
    int vindex = lua_gettop(L);
    int vtype = lua_type(L, vindex);
    switch (vtype) {
        case LUA_TSTRING:
            seri_string(L, vindex, buff, n, max_string, max_len);
            break;
        case LUA_TTABLE:
            seri_table(L, vindex, buff, n, name, max_depth, max_ele, max_string, max_len);
            break;
        default:
            seri_other(L, vindex, buff, n, max_len);
            break;
    }
}

static lua_State *
getthread (lua_State *L, int *arg) {
    if (lua_isthread(L, 1)) {
        *arg = 1;
        return lua_tothread(L, 1);
    } else {
        *arg = 0;
        return L;  // function will operate over current thread
    }
}

// Search for 'objidx' in table at index -1. ('objidx' must be an
// absolute index.) Return 1 + string at top if it found a good name.
static int
findfield (lua_State *L, int objidx, int level) {
    if (level == 0 || !lua_istable(L, -1)) {
        return 0;  // not found
    }
    lua_pushnil(L);  // start 'next' loop
    while (lua_next(L, -2)) {  // for each pair in table
        if (lua_type(L, -2) == LUA_TSTRING) {  // ignore non-string keys
            if (lua_rawequal(L, objidx, -1)) {  // found object?
                lua_pop(L, 1);  // remove value (but keep name)
                return 1;
            } else if (findfield(L, objidx, level - 1)) {  // try recursively
                // stack: lib_name, lib_table, field_name (top)
                lua_pushliteral(L, ".");  // place '.' between the two names
                lua_replace(L, -3);  // (in the slot occupied by table)
                lua_concat(L, 3);  // lib_name.field_name
                return 1;
            }
        }
        lua_pop(L, 1);  // remove value
    }
    return 0;  // not found
}


// Search for a name for a function in all loaded modules
static int
pushglobalfuncname (lua_State *L, lua_Debug *ar) {
    int top = lua_gettop(L);
    lua_getinfo(L, "f", ar);  // push function
    lua_getfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
    if (findfield(L, top + 1, 2)) {
        const char *name = lua_tostring(L, -1);
        if (strncmp(name, LUA_GNAME ".", 3) == 0) {  // name start with '_G.'?
            lua_pushstring(L, name + 3);  // push name without prefix
            lua_remove(L, -2);  // remove original name
        }
        lua_copy(L, -1, top + 1);  // copy name to proper place
        lua_settop(L, top + 1);  // remove table "loaded" and name copy
        return 1;
    } else {
        lua_settop(L, top);  // remove function and global table
        return 0;
    }
}


static void
pushfuncname (lua_State *L, lua_Debug *ar) {
    if (pushglobalfuncname(L, ar)) {  // try first a global name
        lua_pushfstring(L, "function '%s'", lua_tostring(L, -1));
        lua_remove(L, -2);  // remove name
    } else if (*ar->namewhat != '\0') {  // is there a name from code?
        lua_pushfstring(L, "%s '%s'", ar->namewhat, ar->name);  // use it
    } else if (*ar->what == 'm') {// main?
        lua_pushliteral(L, "main chunk");
    } else if (*ar->what != 'C') { // for Lua functions, use <file:line>
        lua_pushfstring(L, "function <%s:%d>", ar->short_src, ar->linedefined);
    } else {  // nothing left...
        lua_pushliteral(L, "?");
    }
}

static void
pushotherinfo(lua_State *L, lua_Debug *ar,
              int max_depth, int max_ele, int max_string, int max_len) {
    luaL_Buffer b;
    char *buff = luaL_buffinitsize(L, &b, max_len+4);
    int n = 0;
    // stack: buffer

    lua_getinfo(L, "fu", ar);  // push function
    // stack: buffer, function

    int i;
    for (i = 1; i <= ar->nparams; i++) {
        const char * name = lua_getlocal(L, ar, i);
        if (name == NULL) {
            break;
        }

        lua_pushfstring(L, "\n\t\t<arg %d> %s = ", i, name);
        size_t l = 0;
        const char *s = lua_tolstring(L, -1, &l);
        buffer_append(buff, &n, s, l, max_len);
        lua_pop(L, 1);

        // top is value
        seri(L, buff, &n, name, max_depth, max_ele, max_string, max_len); // no change stack
        lua_pop(L, 1);
    }

    for (i = 1; i <= ar->nups; i++) {
        const char * name = lua_getupvalue(L, -1, i);
        if (name == NULL) {
            break;
        }

        lua_pushfstring(L, "\n\t\t<upvalue %d> %s = ", i, name);
        size_t l = 0;
        const char *s = lua_tolstring(L, -1, &l);
        buffer_append(buff, &n, s, l, max_len);
        lua_pop(L, 1);

        // top is value
        seri(L, buff, &n, name, max_depth, max_ele, max_string, max_len); // no change stack
        lua_pop(L, 1);
    }
    lua_pop(L, 1); // pop function
    // stack: buffer
    if (n>=max_len) {
        memcpy(buff+n, "...", 3 * sizeof(char));
        n += 3;
    }
    luaL_addsize(&b, n);
    luaL_pushresult(&b);
    // stack: str
}

static int lastlevel (lua_State *L) {
    lua_Debug ar;
    int li = 1, le = 1;
    // find an upper bound
    while (lua_getstack(L, le, &ar)) { li = le; le *= 2; }
    // do a binary search
    while (li < le) {
        int m = (li + le)/2;
        if (lua_getstack(L, m, &ar)) li = m + 1;
        else le = m;
    }
    return le - 1;
}

static void
do_traceback (lua_State *L, lua_State *L1, const char *msg, int level,
              int max_depth, int max_ele, int max_string, int max_len,
              int levels1, int levels2) {
    luaL_Buffer b;
    lua_Debug ar;
    int last = lastlevel(L1);
    int limit2show = (last - level > levels1 + levels2) ? levels1 : -1;
    luaL_buffinit(L, &b);
    if (msg) {
        luaL_addstring(&b, msg);
        luaL_addstring(&b, "\n");
    }
    luaL_addstring(&b, "stack traceback:");
    while (lua_getstack(L1, level++, &ar)) {
        if (limit2show-- == 0) {  // too many levels?
            int n = last - level - levels2 + 1;  // number of levels to skip
            lua_pushfstring(L, "\n\t...\t(skipping %d levels)", n);
            luaL_addvalue(&b);  // add warning about skip
            level += n;  // and skip to last levels
        } else {
            lua_getinfo(L1, "Slnt", &ar);
            if (ar.currentline <= 0) {
                lua_pushfstring(L, "\n\t%s: in ", ar.short_src);
            } else {
                lua_pushfstring(L, "\n\t%s:%d: in ", ar.short_src, ar.currentline);
            }
            luaL_addvalue(&b);
            pushfuncname(L, &ar);
            luaL_addvalue(&b);
            if (ar.istailcall) {
                luaL_addstring(&b, "\n\t(...tail calls...)");
            } else {
                pushotherinfo(L, &ar, max_depth, max_ele, max_string, max_len);
                luaL_addvalue(&b);
            }
        }
    }
    luaL_pushresult(&b);
}

static int
traceback(lua_State *L) {
    // upvalue: max_depth, max_ele, max_string, max_len
    int max_depth = luaL_optinteger(L, lua_upvalueindex(1), 10);
    int max_ele = luaL_optinteger(L, lua_upvalueindex(2), 10);
    int max_string = luaL_optinteger(L, lua_upvalueindex(3), 100);
    int max_len = luaL_optinteger(L, lua_upvalueindex(4), 1000);
    // size of the first part of the stack
    int levels1 = luaL_optinteger(L, lua_upvalueindex(5), 10);
    // size of the second part of the stack
    int levels2 = luaL_optinteger(L, lua_upvalueindex(6), 11);

    int arg;
    lua_State *L1 = getthread(L, &arg);
    const char *msg = lua_tostring(L, arg + 1);
    if (msg == NULL && !lua_isnoneornil(L, arg + 1)) {  // non-string 'msg'?
        lua_pushvalue(L, arg + 1);  // return it untouched
    } else {
        int level = (int)luaL_optinteger(L, arg + 2, (L == L1) ? 1 : 0);
        do_traceback(L, L1, msg, level,
                     max_depth, max_ele, max_string, max_len,
                     levels1, levels2);
    }
    return 1;
}

static int
get_traceback(lua_State *L) {
    // stack: max_depth, max_ele, max_string, max_len, levels1, levels2
    lua_pushcclosure(L, traceback, 6);
    return 1;
}

LUAMOD_API int
luaopen_traceback_c(lua_State * L) {
    luaL_checkversion(L);
    luaL_Reg l[] = {
        { "get_traceback", get_traceback },
        { NULL, NULL },
    };
    luaL_newlib(L, l);
    return 1;
}
