#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>

static const char base64url_enc[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

static const unsigned char base64url_dec[] = {
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x3E, 0xFF, 0xFF,
    0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
    0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0xFF, 0xFF, 0xFF, 0xFF, 0x3F,
    0xFF, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x32, 0x33, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
};

static int lb64urlencode(lua_State *L) {
    size_t input_len;
    const unsigned char *input = (const unsigned char *)luaL_checklstring(L, 1, &input_len);

    size_t output_len = ((input_len + 2) / 3) * 4;
    char *output = (char *)lua_newuserdata(L, output_len + 1);

    size_t i, j;
    for (i = 0, j = 0; i < input_len; i += 3) {
        unsigned long val = (input[i] << 16);
        if (i + 1 < input_len) val |= (input[i + 1] << 8);
        if (i + 2 < input_len) val |= input[i + 2];

        output[j++] = base64url_enc[(val >> 18) & 0x3F];
        output[j++] = base64url_enc[(val >> 12) & 0x3F];

        if (i + 1 < input_len) {
            output[j++] = base64url_enc[(val >> 6) & 0x3F];
        }
        if (i + 2 < input_len) {
            output[j++] = base64url_enc[val & 0x3F];
        }
    }

    output[j] = '\0';
    lua_pushlstring(L, output, j);
    return 1;
}

static int lb64urldecode(lua_State *L) {
    size_t input_len;
    const char *input = luaL_checklstring(L, 1, &input_len);

    while (input_len > 0 && input[input_len - 1] == '=') {
        input_len--;
    }

    size_t output_len = (input_len * 3) / 4;
    unsigned char *output = (unsigned char *)lua_newuserdata(L, output_len + 1);

    size_t i, j;
    unsigned long val = 0;
    int bits = 0;

    for (i = 0, j = 0; i < input_len; i++) {
        unsigned char c = (unsigned char)input[i];
        if (c > 127) {
            return luaL_error(L, "invalid base64url character");
        }

        unsigned char dec = base64url_dec[c];
        if (dec == 0xFF) {
            return luaL_error(L, "invalid base64url character: %c", c);
        }

        val = (val << 6) | dec;
        bits += 6;

        if (bits >= 8) {
            bits -= 8;
            output[j++] = (val >> bits) & 0xFF;
        }
    }

    output[j] = '\0';
    lua_pushlstring(L, (const char *)output, j);
    return 1;
}

static int
lhmac_sha256(lua_State *L) {
    size_t key_len = 0;
    const char* key = luaL_checklstring(L, 1, &key_len);

    size_t msg_len = 0;
    const char* msg = luaL_checklstring(L, 2, &msg_len);

    unsigned char out[32];
    unsigned int out_len = 0;

    if (!HMAC(EVP_sha256(), key, (int)key_len,
              (const unsigned char*)msg, msg_len, out, &out_len)) {
        return luaL_error(L, "HMAC-SHA256 failed");
    }

    lua_pushlstring(L, (const char*)out, out_len);
    return 1;
}

static int
lhmac_sha512(lua_State *L) {
    size_t key_len = 0;
    const char* key = luaL_checklstring(L, 1, &key_len);

    size_t msg_len = 0;
    const char* msg = luaL_checklstring(L, 2, &msg_len);

    unsigned char out[64];
    unsigned int out_len = 0;

    if (!HMAC(EVP_sha512(), key, (int)key_len,
              (const unsigned char*)msg, msg_len, out, &out_len)) {
        return luaL_error(L, "HMAC-SHA512 failed");
    }

    lua_pushlstring(L, (const char*)out, out_len);
    return 1;
}

LUAMOD_API int
luaopen_crypto(lua_State* L) {
    luaL_checkversion(L);

    luaL_Reg l[] = {
        {"hmac_sha256", lhmac_sha256},
        {"hmac_sha512", lhmac_sha512},
        {"base64urlencode", lb64urlencode},
        {"base64urldecode", lb64urldecode},
        {NULL, NULL}
    };
    luaL_newlib(L, l);
    return 1;
}
