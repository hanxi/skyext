#define LUA_LIB

#include <lua.h>
#include <lauxlib.h>
#include <string.h>
#include <limits.h>
#include <openssl/hmac.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/ecdsa.h>
#include <openssl/err.h>

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

/* ---------- JWS 非对称签名（RS256 / ES256）----------
 *
 * 只收 SubjectPublicKeyInfo 形式的公钥（-----BEGIN PUBLIC KEY-----）和未加密的
 * PKCS#8 私钥。错误信息里一律不带密钥内容。
 */

struct alg_spec {
    const char *name;
    int pkey_type;   /* 期望的密钥类型，用来挡住"拿 RSA 公钥验 ES256"这类错配 */
    int min_bits;    /* RSA：低于这个强度直接拒绝 */
    int exact_bits;  /* EC：曲线宽度必须正好是这个值，裸签名长度由它推出来 */
    int coord_len;   /* ECDSA 裸签名里 R / S 各自的字节数；RSA 为 0 */
};

static const struct alg_spec ALGS[] = {
    { "RS256", EVP_PKEY_RSA, 2048, 0,   0  },
    { "ES256", EVP_PKEY_EC,  0,    256, 32 },
};

static const struct alg_spec *
find_alg(const char *name) {
    size_t i;
    for (i = 0; i < sizeof(ALGS) / sizeof(ALGS[0]); i++) {
        if (strcmp(ALGS[i].name, name) == 0) {
            return &ALGS[i];
        }
    }
    return NULL;
}

/* 加密私钥会让 OpenSSL 去终端要密码，服务进程里这等于挂死。一律拒绝。 */
static int
no_password_cb(char *buf, int size, int rwflag, void *u) {
    (void)buf; (void)size; (void)rwflag; (void)u;
    return -1;
}

static EVP_PKEY *
load_pem_key(const char *pem, size_t pem_len, int is_private) {
    if (pem_len > INT_MAX) {
        return NULL;
    }
    BIO *bio = BIO_new_mem_buf(pem, (int)pem_len);
    if (bio == NULL) {
        return NULL;
    }
    EVP_PKEY *pkey = is_private
        ? PEM_read_bio_PrivateKey(bio, NULL, no_password_cb, NULL)
        : PEM_read_bio_PUBKEY(bio, NULL, no_password_cb, NULL);
    BIO_free(bio);
    return pkey;
}

static const char *
check_key(EVP_PKEY *pkey, const struct alg_spec *spec) {
    if (EVP_PKEY_base_id(pkey) != spec->pkey_type) {
        return "key type does not match alg";
    }
    if (spec->min_bits && EVP_PKEY_bits(pkey) < spec->min_bits) {
        return "key is too weak for alg";
    }
    /* EC 曲线宽度决定裸 R||S 的长度，对不上就不能按定长切分 */
    if (spec->exact_bits && EVP_PKEY_bits(pkey) != spec->exact_bits) {
        return "key curve does not match alg";
    }
    return NULL;
}

/* JWS（RFC 7518 §3.4）里 ECDSA 签名是定长的 R || S 拼接，而 OpenSSL 收发的是
 * DER 编码的 ECDSA_SIG。两种格式之间必须来回转换，漏掉就表现为签名永远验不过。 */
static unsigned char *
ecdsa_raw_to_der(const unsigned char *raw, size_t raw_len, int coord_len, int *out_len) {
    if (raw_len != (size_t)coord_len * 2) {
        return NULL;
    }
    ECDSA_SIG *sig = ECDSA_SIG_new();
    if (sig == NULL) {
        return NULL;
    }
    BIGNUM *r = BN_bin2bn(raw, coord_len, NULL);
    BIGNUM *s = BN_bin2bn(raw + coord_len, coord_len, NULL);
    if (r == NULL || s == NULL || !ECDSA_SIG_set0(sig, r, s)) {
        /* set0 失败时 r/s 的所有权没有转移，得自己释放 */
        BN_free(r);
        BN_free(s);
        ECDSA_SIG_free(sig);
        return NULL;
    }
    unsigned char *der = NULL;
    int len = i2d_ECDSA_SIG(sig, &der);
    ECDSA_SIG_free(sig);
    if (len <= 0) {
        OPENSSL_free(der);
        return NULL;
    }
    *out_len = len;
    return der;
}

static int
ecdsa_der_to_raw(const unsigned char *der, size_t der_len, int coord_len, unsigned char *out) {
    const unsigned char *p = der;
    ECDSA_SIG *sig = d2i_ECDSA_SIG(NULL, &p, (long)der_len);
    if (sig == NULL) {
        return 0;
    }
    /* BN_bn2binpad 左侧补零到定长。换成 BN_bn2bin 会在 R 或 S 高位为 0 时少输出
     * 一两个字节，拼出来的签名短一截——这是 ECDSA 格式转换最常见的 off-by-one。 */
    int ok = BN_bn2binpad(ECDSA_SIG_get0_r(sig), out, coord_len) == coord_len
          && BN_bn2binpad(ECDSA_SIG_get0_s(sig), out + coord_len, coord_len) == coord_len;
    ECDSA_SIG_free(sig);
    return ok;
}

/* crypto.pkey_verify(alg, public_pem, message, signature)
 *   -> true          签名有效
 *   -> false         签名无效（token 的问题）
 *   -> nil, reason   密钥或参数有问题（配置的问题），调用方要区别对待 */
static int
lpkey_verify(lua_State *L) {
    const char *alg_name = luaL_checkstring(L, 1);
    size_t pem_len, msg_len, sig_len;
    const char *pem = luaL_checklstring(L, 2, &pem_len);
    const char *msg = luaL_checklstring(L, 3, &msg_len);
    const unsigned char *sig = (const unsigned char *)luaL_checklstring(L, 4, &sig_len);

    const struct alg_spec *spec = find_alg(alg_name);
    if (spec == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "unsupport alg");
        return 2;
    }

    ERR_clear_error();

    EVP_PKEY *pkey = load_pem_key(pem, pem_len, 0);
    if (pkey == NULL) {
        ERR_clear_error();
        lua_pushnil(L);
        lua_pushstring(L, "invalid public key");
        return 2;
    }

    const char *key_err = check_key(pkey, spec);
    if (key_err != NULL) {
        EVP_PKEY_free(pkey);
        lua_pushnil(L);
        lua_pushstring(L, key_err);
        return 2;
    }

    unsigned char *der = NULL;
    if (spec->coord_len > 0) {
        int der_len = 0;
        der = ecdsa_raw_to_der(sig, sig_len, spec->coord_len, &der_len);
        if (der == NULL) {
            /* 长度不对的裸签名只能是坏 token，不是配置问题 */
            EVP_PKEY_free(pkey);
            ERR_clear_error();
            lua_pushboolean(L, 0);
            return 1;
        }
        sig = der;
        sig_len = (size_t)der_len;
    }

    int result = -1;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (ctx != NULL && EVP_DigestVerifyInit(ctx, NULL, EVP_sha256(), NULL, pkey) == 1) {
        result = EVP_DigestVerify(ctx, sig, sig_len, (const unsigned char *)msg, msg_len);
    }
    EVP_MD_CTX_free(ctx);
    OPENSSL_free(der);
    EVP_PKEY_free(pkey);
    ERR_clear_error();

    if (result < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "verify failed");
        return 2;
    }
    lua_pushboolean(L, result == 1);
    return 1;
}

/* crypto.pkey_sign(alg, private_pem, message)
 *   -> signature     JWS 规定的裸签名（ES256 为 R||S，不是 DER）
 *   -> nil, reason */
static int
lpkey_sign(lua_State *L) {
    const char *alg_name = luaL_checkstring(L, 1);
    size_t pem_len, msg_len;
    const char *pem = luaL_checklstring(L, 2, &pem_len);
    const char *msg = luaL_checklstring(L, 3, &msg_len);

    const struct alg_spec *spec = find_alg(alg_name);
    if (spec == NULL) {
        lua_pushnil(L);
        lua_pushstring(L, "unsupport alg");
        return 2;
    }

    ERR_clear_error();

    EVP_PKEY *pkey = load_pem_key(pem, pem_len, 1);
    if (pkey == NULL) {
        ERR_clear_error();
        lua_pushnil(L);
        lua_pushstring(L, "invalid private key");
        return 2;
    }

    const char *key_err = check_key(pkey, spec);
    if (key_err != NULL) {
        EVP_PKEY_free(pkey);
        lua_pushnil(L);
        lua_pushstring(L, key_err);
        return 2;
    }

    const char *err = NULL;
    unsigned char *sig = NULL;
    size_t sig_len = 0;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();

    if (ctx == NULL || EVP_DigestSignInit(ctx, NULL, EVP_sha256(), NULL, pkey) != 1) {
        err = "sign init failed";
    } else if (EVP_DigestSign(ctx, NULL, &sig_len, (const unsigned char *)msg, msg_len) != 1
               || sig_len == 0) {
        err = "sign failed";
    } else if ((sig = OPENSSL_malloc(sig_len)) == NULL) {
        err = "out of memory";
    } else if (EVP_DigestSign(ctx, sig, &sig_len, (const unsigned char *)msg, msg_len) != 1) {
        err = "sign failed";
    }

    if (err == NULL && spec->coord_len > 0) {
        /* OpenSSL 产出的是 DER，JWS 要的是定长裸拼接 */
        unsigned char raw[128];
        size_t raw_len = (size_t)spec->coord_len * 2;
        if (raw_len > sizeof(raw) || !ecdsa_der_to_raw(sig, sig_len, spec->coord_len, raw)) {
            err = "sign failed";
        } else {
            lua_pushlstring(L, (const char *)raw, raw_len);
        }
    } else if (err == NULL) {
        lua_pushlstring(L, (const char *)sig, sig_len);
    }

    OPENSSL_free(sig);
    EVP_MD_CTX_free(ctx);
    EVP_PKEY_free(pkey);
    ERR_clear_error();

    if (err != NULL) {
        lua_pushnil(L);
        lua_pushstring(L, err);
        return 2;
    }
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
        {"pkey_verify", lpkey_verify},
        {"pkey_sign", lpkey_sign},
        {NULL, NULL}
    };
    luaL_newlib(L, l);
    return 1;
}
