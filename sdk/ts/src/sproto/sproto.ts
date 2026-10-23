// @ts-nocheck
// ↑ 为什么整文件关严格检查：vendored 上游代码是 JS 风格的宽松 TS（大量
// possibly-undefined / null 转换噪音，35 处），逐处修补会让「与上游的 diff」
// 膨胀到无法同步新版本。补丁改动的路径（latin1、bigint、expand64）由
// src/*.test.ts 在运行时覆盖。升级上游后先删掉这行跑一遍 tsc 评估成本。
//
// sproto.ts - TypeScript版本的sproto协议解析库
//
// Vendored from https://github.com/hanxi/sproto-js v0.1.9 (MIT License)。
// 与上游的差异（skyext 补丁，同步上游新版本时必须全部重新应用）：
//
// 补丁 1：string 字节透明（搜「字节透明」）
//   - string2utf8 / utf82string 更名为 string2bytes / bytes2string，语义改为
//     字节透明（latin1）：编码取每个字符 charCode 的低 8 位，解码逐字节 fromCharCode。
//   - 原因：wire 上的 sproto string 是字节序列（文本字段是 UTF-8 字节，binary 字段
//     是任意字节），编解码器必须原样搬运。上游的 UTF-8 转换会静默改字节：非法
//     UTF-8 序列解码丢字节、编码再把 [0x80,0xFF] 字符扩成 2 字节，往返必坏。
//   - 补丁之后 JS 里 string 字段值是「字节串」（每个 char 码位 ∈ [0,255]），
//     binary 字段值是 number[] 字节数组。UTF-8 文本转换统一在 codec.ts 的 API
//     边界做（bin.ts 提供 helper），不下沉到 sproto 层。
//
// 补丁 2：int64 用 BigInt（搜「补丁」+ bigint / expand64）
//   - 解码：8 字节整数经 utils.int64 还原，|v| ≤ 2^53 得 number，否则得 bigint；
//     负数按补码还原（上游会解成巨大无符号数）。4 字节整数经 utils.expand64
//     符号扩展（上游不扩展，int32 负数会解成无符号正数；C 实现是扩展的）。
//   - 编码：整数字段接受 bigint，超 int32 按 8 字节补码写出（标量与数组元素）。
//   - 原因：rid 等实体 id 是 17 位 int64（> 2^53），上游只有 float64 一条路，
//     编解码都会静默丢精度，login 会带着错 rid 被服务端拒绝。

// 类型定义
export type SprotoValue = string | number | bigint | boolean | number[] | Record<string, unknown> | null;

export interface SprotoUserData {
  deep?: number;
  array_tag?: string | null;
  array_index?: number;
  result?: Record<string, unknown>;
  st?: SprotoType;
  tbl_index?: number;
  indata?: Record<string, unknown>;
  iter_index?: number;
  mainindex_tag?: number;
  key_index?: number;
  [key: string]: unknown;
}

export interface SprotoHost {
  proto: SprotoInstance;
  package: SprotoType | string;
  session: Record<number, SprotoType | boolean>;
  attachsp?: SprotoInstance;
  attach: (sp: SprotoInstance) => (name: string, args: Record<string, unknown>, session: number) => number[];
  dispatch: (buffer: number[]) => SprotoDispatchResult;
}

export interface SprotoDispatchResult {
  type: 'REQUEST' | 'RESPONSE';
  pname?: string;
  result?: Record<string, unknown>;
  responseFunc?: (args: Record<string, unknown>) => number[];
  session?: number;
}

export interface SprotoProtocolInfo {
  tag: number;
  name: string;
  request: SprotoType | null;
  response: SprotoType | null;
}

export interface SprotoConstants {
  readonly SPROTO_REQUEST: 0;
  readonly SPROTO_RESPONSE: 1;
  readonly SPROTO_TINTEGER: 0;
  readonly SPROTO_TBOOLEAN: 1;
  readonly SPROTO_TSTRING: 2;
  readonly SPROTO_TDOUBLE: 3;
  readonly SPROTO_TSTRUCT: 4;
  readonly SPROTO_TSTRING_STRING: 0;
  readonly SPROTO_TSTRING_BINARY: 1;
  readonly SPROTO_CB_ERROR: -1;
  readonly SPROTO_CB_NIL: -2;
  readonly SPROTO_CB_NOARRAY: -3;
  readonly SPROTO_TARRAY: 0x80;
  readonly CHUNK_SIZE: 1000;
  readonly SIZEOF_LENGTH: 4;
  readonly SIZEOF_HEADER: 2;
  readonly SIZEOF_FIELD: 2;
  readonly ENCODE_BUFFERSIZE: 2050;
  readonly ENCODE_MAXSIZE: 0x1000000;
  readonly ENCODE_DEEPLEVEL: 64;
}

export interface SprotoField {
  tag: number;
  type: number;
  name: string | null;
  st: number | null;
  key: number;
  extra: number;
}

export interface SprotoType {
  name: string | null;
  n: number;
  base: number;
  maxn: number;
  f: SprotoField[] | null;
}

export interface SprotoProtocol {
  name: string | null;
  tag: number;
  p: (SprotoType | null)[];
  confirm: number;
}

export interface SprotoArgs {
  ud?: SprotoUserData;
  tagname?: string;
  tagid?: number;
  type?: number;
  subtype?: SprotoType | null;
  mainindex?: number;
  extra?: number;
  index?: number;
  value?: SprotoValue;
  length?: number;
  buffer?: number[];
  buffer_idx?: number;
}

export interface SprotoInstance {
  type_n: number;
  protocol_n: number;
  type: SprotoType[] | null;
  proto: SprotoProtocol[] | null;
  tcache: Map<string | number, SprotoType>;
  pcache: Map<string | number, SprotoProtocolInfo>;
  queryproto: (protocolName: string | number) => SprotoProtocolInfo | null;
  dump: () => void;
  objlen: (type: string | number | SprotoType, inbuf: number[]) => number | null;
  encode: (type: string | number | SprotoType, indata: Record<string, unknown>) => number[] | null;
  decode: (type: string | number | SprotoType, inbuf: number[]) => Record<string, unknown> | null;
  pack: (inbuf: number[]) => number[];
  unpack: (inbuf: number[]) => number[];
  pencode: (type: string | number | SprotoType, inbuf: Record<string, unknown>) => number[] | null;
  pdecode: (type: string | number | SprotoType, inbuf: number[]) => Record<string, unknown> | null;
  host: (packagename?: string) => SprotoHost;
}

export interface SprotoAPI {
  pack: (inbuf: number[]) => number[];
  unpack: (inbuf: number[]) => number[];
  createNew: (binsch: number[]) => SprotoInstance | null;
}

const sproto = (() => {
  const api: SprotoAPI = {} as SprotoAPI;
  const host: Partial<SprotoHost> = {};
  let headerTemp: Record<string, unknown> = {};

  // 常量定义
  const CONSTANTS: SprotoConstants = {
    SPROTO_REQUEST: 0,
    SPROTO_RESPONSE: 1,
    SPROTO_TINTEGER: 0,
    SPROTO_TBOOLEAN: 1,
    SPROTO_TSTRING: 2,
    SPROTO_TDOUBLE: 3,
    SPROTO_TSTRUCT: 4,
    SPROTO_TSTRING_STRING: 0,
    SPROTO_TSTRING_BINARY: 1,
    SPROTO_CB_ERROR: -1,
    SPROTO_CB_NIL: -2,
    SPROTO_CB_NOARRAY: -3,
    SPROTO_TARRAY: 0x80,
    CHUNK_SIZE: 1000,
    SIZEOF_LENGTH: 4,
    SIZEOF_HEADER: 2,
    SIZEOF_FIELD: 2,
    ENCODE_BUFFERSIZE: 2050,
    ENCODE_MAXSIZE: 0x1000000,
    ENCODE_DEEPLEVEL: 64
  };

  // 工具函数
  const utils = {
    // 补丁：4 字节整数按 int32 符号扩展，与 C 实现的 expand64 一致。
    // 上游把 0x80000000 以上当无符号返回，int32 负数（如 -5）会解成 4294967291
    expand64: (v: number): number => v | 0,

    hiLowUint64: (low: number, hi: number): number => (hi & 0xFFFFFFFF) * 0x100000000 + low,

    // 补丁：两个 32 位字拼 int64。|v| ≤ 2^53 时给 number，否则给 bigint；负数按
    // 二进制补码还原。上游的 hiLowUint64 只有 float64 一条路：超过 2^53 静默丢精度
    // （rid 是 17 位 int64），负数会解成巨大的无符号数
    int64: (low: number, hi: number): number | bigint => {
      const u = (BigInt(hi >>> 0) << 32n) | BigInt(low >>> 0);
      if ((hi & 0x80000000) !== 0) {
        return u - 0x10000000000000000n;
      }
      return u <= 9007199254740991n ? Number(u) : u;
    },

    uint64Lshift: (num: number, offset: number): number => num * Math.pow(2, offset),

    uint64Rshift: (num: number, offset: number): number => Math.floor(num / Math.pow(2, offset)),

    toWord: (stream: number[]): number => (stream[0] & 0xff) | ((stream[1] & 0xff) << 8),

    toDword: (stream: number[]): number => (
      (stream[0] & 0xff) |
      ((stream[1] & 0xff) << 8) |
      ((stream[2] & 0xff) << 16) |
      ((stream[3] & 0xff) << 24)
    ) >>> 0,

    // 字节透明（latin1）：每个字符取 charCode 低 8 位。上游这里是 UTF-8 编码，
    // 会破坏二进制 string 字段（如 16 字节随机 nonce），见文件头补丁说明
    string2bytes: (str: string): number[] => {
      if (typeof str !== 'string') {
        throw new TypeError('Expected a string');
      }

      const result: number[] = [];

      for (let i = 0; i < str.length; i++) {
        result.push(str.charCodeAt(i) & 0xff);
      }

      return result;
    },

    // 字节透明（latin1）：逐字节 fromCharCode。上游这里是 UTF-8 解码，
    // 非法序列会被静默跳过（丢字节），见文件头补丁说明
    bytes2string: (arr: number[]): string | null => {
      if (typeof arr === 'string') {
        return null;
      }

      if (!Array.isArray(arr)) {
        throw new TypeError('Expected an array');
      }

      let result = '';

      for (let i = 0; i < arr.length && arr[i] != null; i++) {
        result += String.fromCharCode(arr[i] & 0xff);
      }

      return result;
    },

    arrayconcat: (a1: number[], a2: number[]): number[] => {
      if (!Array.isArray(a1) || !Array.isArray(a2)) {
        throw new TypeError('Both arguments must be arrays');
      }
      return [...a1, ...a2];
    }
  };

  function calcPow(base: number, exp: number): number {
    return Math.pow(base, exp);
  }

  const countArray = (stream: number[]): number => {
    const length = utils.toDword(stream);
    let n = 0;
    let currentStream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
    let remainingLength = length;

    while (remainingLength > 0) {
      if (remainingLength < CONSTANTS.SIZEOF_LENGTH) {
        return -1;
      }

      const nsz = utils.toDword(currentStream) + CONSTANTS.SIZEOF_LENGTH;
      if (nsz > remainingLength) {
        return -1;
      }

      n++;
      currentStream = currentStream.slice(nsz);
      remainingLength -= nsz;
    }

    return n;
  };

  const structField = (stream: number[], sz: number): number => {
    if (sz < CONSTANTS.SIZEOF_LENGTH) {
      return -1;
    }

    const fn = utils.toWord(stream);
    const header = CONSTANTS.SIZEOF_HEADER + CONSTANTS.SIZEOF_FIELD * fn;

    if (sz < header) {
      return -1;
    }

    const field = stream.slice(CONSTANTS.SIZEOF_HEADER);
    let remainingSz = sz - header;
    let currentStream = stream.slice(header);

    for (let i = 0; i < fn; i++) {
      const value = utils.toWord(field.slice(i * CONSTANTS.SIZEOF_FIELD + CONSTANTS.SIZEOF_HEADER));

      if (value !== 0) {
        continue;
      }

      if (remainingSz < CONSTANTS.SIZEOF_LENGTH) {
        return -1;
      }

      const dsz = utils.toDword(currentStream);
      if (remainingSz < CONSTANTS.SIZEOF_LENGTH + dsz) {
        return -1;
      }

      currentStream = currentStream.slice(CONSTANTS.SIZEOF_LENGTH + dsz);
      remainingSz -= CONSTANTS.SIZEOF_LENGTH + dsz;
    }

    return fn;
  };

  const importString = (s: SprotoInstance, stream: number[]): string => {
    const sz = utils.toDword(stream);
    const arr = stream.slice(CONSTANTS.SIZEOF_LENGTH, CONSTANTS.SIZEOF_LENGTH + sz);
    return String.fromCharCode(...arr);
  };

  function importField(s: SprotoInstance, f: SprotoField, stream: number[]): number[] | null {
    let sz: number, result: number[], fn: number;
    let array = 0;
    let tag = -1;
    f.tag = -1;
    f.type = -1;
    f.name = null;
    f.st = null;
    f.key = -1;
    f.extra = 0;

    sz = utils.toDword(stream);
    stream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
    result = stream.slice(sz);
    fn = structField(stream, sz);
    if (fn < 0) return null;

    stream = stream.slice(CONSTANTS.SIZEOF_HEADER);
    for (let i = 0; i < fn; i++) {
      let value: number;
      ++tag;
      value = utils.toWord(stream.slice(CONSTANTS.SIZEOF_FIELD * i));
      if ((value & 1) !== 0) {
        tag += Math.floor(value / 2);
        continue;
      }

      if (tag === 0) {
        if (value !== 0) return null;
        f.name = importString(s, stream.slice(fn * CONSTANTS.SIZEOF_FIELD));
        continue;
      }

      if (value === 0) return null;
      value = Math.floor(value / 2) - 1;
      switch (tag) {
        case 1:
          if (value >= CONSTANTS.SPROTO_TSTRUCT) {
            return null;
          }
          f.type = value;
          break;
        case 2:
          if (f.type === CONSTANTS.SPROTO_TINTEGER) {
            f.extra = calcPow(10, value);
          } else if (f.type === CONSTANTS.SPROTO_TSTRING) {
            f.extra = value;
          } else {
            if (value >= s.type_n) {
              return null;
            }

            if (f.type >= 0) {
              return null;
            }

            f.type = CONSTANTS.SPROTO_TSTRUCT;
            f.st = value;
          }
          break;
        case 3:
          f.tag = value;
          break;
        case 4:
          if (value !== 0) {
            array = CONSTANTS.SPROTO_TARRAY;
          }
          break;
        case 5:
          f.key = value;
          break;
        default:
          return null;
      }
    }
    if (f.tag < 0 || f.type < 0 || f.name === null) {
      return null;
    }
    f.type |= array;
    return result;
  }

  function importType(s: SprotoInstance, t: SprotoType, stream: number[]): number[] | null {
    let result: number[], fn: number, n: number, maxn: number, last: number;
    const sz = utils.toDword(stream);
    stream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
    result = stream.slice(sz);
    fn = structField(stream, sz);
    if (fn <= 0 || fn > 2) {
      return null;
    }

    for (let i = 0; i < fn * CONSTANTS.SIZEOF_FIELD; i += CONSTANTS.SIZEOF_FIELD) {
      const v = utils.toWord(stream.slice(CONSTANTS.SIZEOF_HEADER + i));
      if (v !== 0) return null;
    }

    t.name = null;
    t.n = 0;
    t.base = 0;
    t.maxn = 0;
    t.f = null;
    stream = stream.slice(CONSTANTS.SIZEOF_HEADER + fn * CONSTANTS.SIZEOF_FIELD);
    t.name = importString(s, stream);

    if (fn === 1) {
      return result;
    }

    stream = stream.slice(utils.toDword(stream) + CONSTANTS.SIZEOF_LENGTH);
    n = countArray(stream);
    if (n < 0) {
      return null;
    }

    stream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
    maxn = n;
    last = -1;
    t.n = n;
    t.f = [];
    for (let i = 0; i < n; i++) {
      let tag: number;
      t.f[i] = {} as SprotoField;
      const f = t.f[i];
      const newStream = importField(s, f, stream);
      if (newStream === null) {
        return null;
      }
      stream = newStream;

      tag = f.tag;
      if (tag <= last) {
        return null;
      }
      if (tag > last + 1) {
        ++maxn;
      }
      last = tag;
    }
    t.maxn = maxn;
    t.base = t.f[0].tag;
    n = t.f[n - 1].tag - t.base + 1;
    if (n !== t.n) {
      t.base = -1;
    }
    return result;
  }

  function importProtocol(s: SprotoInstance, p: SprotoProtocol, stream: number[]): number[] | null {
    let result: number[], sz: number, fn: number, tag: number;
    sz = utils.toDword(stream);
    stream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
    result = stream.slice(sz);
    fn = structField(stream, sz);
    stream = stream.slice(CONSTANTS.SIZEOF_HEADER);
    p.name = null;
    p.tag = -1;
    p.p = [];
    p.p[CONSTANTS.SPROTO_REQUEST] = null;
    p.p[CONSTANTS.SPROTO_RESPONSE] = null;
    p.confirm = 0;
    tag = 0;
    for (let i = 0; i < fn; i++, tag++) {
      let value = utils.toWord(stream.slice(CONSTANTS.SIZEOF_FIELD * i));
      if ((value & 1) !== 0) {
        tag += Math.floor(value - 1) / 2;
        continue;
      }
      value = Math.floor(value / 2) - 1;
      switch (i) {
        case 0:
          if (value !== -1) {
            return null;
          }
          p.name = importString(s, stream.slice(CONSTANTS.SIZEOF_FIELD * fn));
          break;
        case 1:
          if (value < 0) {
            return null;
          }
          p.tag = value;
          break;
        case 2:
          if (value < 0 || value >= s.type_n)
            return null;
          p.p[CONSTANTS.SPROTO_REQUEST] = s.type?.[value] || null;
          break;
        case 3:
          if (value < 0 || value > s.type_n)
            return null;
          p.p[CONSTANTS.SPROTO_RESPONSE] = s.type?.[value] || null;
          break;
        case 4:
          p.confirm = value;
          break;
        default:
          return null;
      }
    }

    if (p.name === null || p.tag < 0) {
      return null;
    }
    return result;
  }

  function createFromBundle(s: SprotoInstance, stream: number[], sz: number): SprotoInstance | null {
    let content: number[], typedata: number[], protocoldata: number[];
    const fn = structField(stream, sz);
    if (fn < 0 || fn > 2)
      return null;
    stream = stream.slice(CONSTANTS.SIZEOF_HEADER);
    content = stream.slice(fn * CONSTANTS.SIZEOF_FIELD);

    for (let i = 0; i < fn; i++) {
      const value = utils.toWord(stream.slice(i * CONSTANTS.SIZEOF_FIELD));
      if (value !== 0) {
        return null;
      }

      const n = countArray(content);
      if (n < 0) {
        return null;
      }

      if (i === 0) {
        typedata = content.slice(CONSTANTS.SIZEOF_LENGTH);
        s.type_n = n;
        s.type = [];
      } else {
        protocoldata = content.slice(CONSTANTS.SIZEOF_LENGTH);
        s.protocol_n = n;
        s.proto = [];
      }
      content = content.slice(utils.toDword(content) + CONSTANTS.SIZEOF_LENGTH);
    }

    for (let i = 0; i < s.type_n; i++) {
      if (s.type) {
        s.type[i] = {} as SprotoType;
        const newTypedata = importType(s, s.type[i], typedata!);
        if (newTypedata === null) {
          return null;
        }
        typedata = newTypedata;
      }
    }

    for (let i = 0; i < s.protocol_n; i++) {
      if (s.proto) {
        s.proto[i] = {} as SprotoProtocol;
        const newProtocoldata = importProtocol(s, s.proto[i], protocoldata!);
        if (newProtocoldata === null) {
          return null;
        }
        protocoldata = newProtocoldata;
      }
    }

    return s;
  }

  function sprotoDump(s: SprotoInstance): void {
    console.log(s);
  }

  function sprotoProtoTag(sp: SprotoInstance, name: string): number {
    if (!sp.proto) return -1;
    for (let i = 0; i < sp.protocol_n; i++) {
      if (name === sp.proto[i].name) {
        return sp.proto[i].tag;
      }
    }
    return -1;
  }

  function queryProto(sp: SprotoInstance, tag: number): SprotoProtocol | null {
    if (!sp.proto) return null;
    let begin = 0;
    let end = sp.protocol_n;
    while (begin < end) {
      const mid = Math.floor((begin + end) / 2);
      const t = sp.proto[mid].tag;
      if (t === tag) {
        return sp.proto[mid];
      }

      if (tag > t) {
        begin = mid + 1;
      } else {
        end = mid;
      }
    }
    return null;
  }

  function sprotoProtoQuery(sp: SprotoInstance, proto: number, what: number): SprotoType | null {
    if (what < 0 || what > 1) {
      return null;
    }

    const p = queryProto(sp, proto);
    if (p) {
      return p.p[what];
    }
    return null;
  }

  function sprotoProtoResponse(sp: SprotoInstance, proto: number): boolean {
    const p = queryProto(sp, proto);
    return (p !== null && (!!p.p[CONSTANTS.SPROTO_RESPONSE] || !!p.confirm));
  }

  function sprotoProtoName(sp: SprotoInstance, proto: number): string | null {
    const p = queryProto(sp, proto);
    if (p) {
      return p.name;
    }
    return null;
  }

  function sprotoType(sp: SprotoInstance, typeName: string): SprotoType | null {
    if (!sp.type) return null;
    for (let i = 0; i < sp.type_n; i++) {
      if (typeName === sp.type[i].name) {
        return sp.type[i];
      }
    }
    return null;
  }

  function sprotoName(st: SprotoType): string | null {
    return st.name;
  }

  function findTag(st: SprotoType, tag: number): SprotoField | null {
    if (st.base >= 0) {
      tag -= st.base;
      if (tag < 0 || tag > st.n) {
        return null;
      }
      return st.f![tag];
    }

    let begin = 0;
    let end = st.n;
    while (begin < end) {
      const mid = Math.floor((begin + end) / 2);
      const f = st.f![mid];
      const t = f.tag;
      if (t === tag) {
        return f;
      }
      if (tag > t) {
        begin = mid + 1;
      } else {
        end = mid;
      }
    }
    return null;
  }

  function fillSize(data: number[], dataIdx: number, sz: number): number {
    data[dataIdx] = sz & 0xff;
    data[dataIdx + 1] = (sz >> 8) & 0xff;
    data[dataIdx + 2] = (sz >> 16) & 0xff;
    data[dataIdx + 3] = (sz >> 24) & 0xff;
    return sz + CONSTANTS.SIZEOF_LENGTH;
  }

  function encodeInteger(v: number, data: number[], dataIdx: number, size: number): number {
    data[dataIdx + 4] = v & 0xff;
    data[dataIdx + 5] = (v >> 8) & 0xff;
    data[dataIdx + 6] = (v >> 16) & 0xff;
    data[dataIdx + 7] = (v >> 24) & 0xff;
    return fillSize(data, dataIdx, 4);
  }

  function encodeUint64(v: number | bigint, data: number[], dataIdx: number, size: number): number {
    if (typeof v === 'bigint') {
      // 补丁：bigint 直接按补码逐字节写，不经过 float64
      let u = v < 0n ? v + 0x10000000000000000n : v;
      for (let i = 0; i < 8; i++) {
        data[dataIdx + 4 + i] = Number(u & 0xffn);
        u >>= 8n;
      }
      return fillSize(data, dataIdx, 8);
    }
    data[dataIdx + 4] = v & 0xff;
    data[dataIdx + 5] = utils.uint64Rshift(v, 8) & 0xff;
    data[dataIdx + 6] = utils.uint64Rshift(v, 16) & 0xff;
    data[dataIdx + 7] = utils.uint64Rshift(v, 24) & 0xff;
    data[dataIdx + 8] = utils.uint64Rshift(v, 32) & 0xff;
    data[dataIdx + 9] = utils.uint64Rshift(v, 40) & 0xff;
    data[dataIdx + 10] = utils.uint64Rshift(v, 48) & 0xff;
    data[dataIdx + 11] = utils.uint64Rshift(v, 56) & 0xff;
    return fillSize(data, dataIdx, 8);
  }

  function decToBinTail(dec: number, pad: number): string {
    let bin = "";
    for (let i = 0; i < pad; i++) {
      dec *= 2;
      if (dec >= 1) {
        dec -= 1;
        bin += "1";
      } else {
        bin += "0";
      }
    }
    return bin;
  }

  function decToBinHead(data: number, len: number): string {
    let result = "";
    for (let i = len - 1; i >= 0; i--) {
      const mask = 1 << i;
      if ((mask & data) === 0) {
        result += "0";
      } else {
        result += "1";
      }
    }
    return result;
  }

  function getDoubleHex(decString: string): string {
    let sign: number;
    let signString: string;
    let exponent: number;
    const decValue = parseFloat(Math.abs(parseFloat(decString)).toString());
    if (decString.toString().charAt(0) === '-') {
      sign = 1;
      signString = "1";
    } else {
      sign = 0;
      signString = "0";
    }
    if (decValue === 0) {
      exponent = 0;
    } else {
      exponent = 1023;
      let tempDecValue = decValue;
      if (tempDecValue >= 2) {
        while (tempDecValue >= 2) {
          exponent++;
          tempDecValue /= 2;
        }
      } else if (tempDecValue < 1) {
        while (tempDecValue < 1) {
          exponent--;
          tempDecValue *= 2;
          if (exponent === 0) {
            break;
          }
        }
      }
      if (exponent !== 0) tempDecValue -= 1; else tempDecValue /= 2;
      const fractionString = decToBinTail(tempDecValue, 52);
      const exponentString = decToBinHead(exponent, 11);
      const doubleBinStr = signString + exponentString + fractionString;
      let doubleHexStr = "";
      for (let i = 0, j = 0; i < 8; i++, j += 8) {
        const m = 3 - (j % 4);
        const hexUnit = parseInt(doubleBinStr[j]) * Math.pow(2, m) + parseInt(doubleBinStr[j + 1]) * Math.pow(2, m - 1) + parseInt(doubleBinStr[j + 2]) * Math.pow(2, m - 2) + parseInt(doubleBinStr[j + 3]) * Math.pow(2, m - 3);
        const hexDecade = parseInt(doubleBinStr[j + 4]) * Math.pow(2, m) + parseInt(doubleBinStr[j + 5]) * Math.pow(2, m - 1) + parseInt(doubleBinStr[j + 6]) * Math.pow(2, m - 2) + parseInt(doubleBinStr[j + 7]) * Math.pow(2, m - 3);
        doubleHexStr = doubleHexStr + hexUnit.toString(16) + hexDecade.toString(16);
      }
      return doubleHexStr;
    }
    return "";
  }

  function doubleToBinary(v: number, data: number[], dataIdx: number): number {
    const str = Number(v).toString();
    const hexStr = getDoubleHex(str);
    if (!hexStr) {
      // Handle case where getDoubleHex returns empty string
      for (let i = 0; i < 8; i++) {
        data[dataIdx + i + 4] = 0;
      }
      return fillSize(data, dataIdx, 8);
    }
    const arr: number[] = [];
    for (let i = 0, j = 0; i < 8; i++, j += 2) {
      const dec = parseInt(hexStr[j] || '0', 16) * 16 + parseInt(hexStr[j + 1] || '0', 16);
      arr.push(dec);
    }
    arr.reverse();
    for (let i = 0; i < 8; i++) {
      const dec = arr[i] || 0;
      data[dataIdx + i + 4] = dec;
    }
    return fillSize(data, dataIdx, 8);
  }

  function binaryToDouble(data: number[]): number {
    const buf = new Uint8Array(data);
    const buf64 = new Float64Array(buf.buffer);
    return buf64[0];
  }

  function encodeObject(cb: (args: SprotoArgs) => number, args: SprotoArgs, data: number[], dataIdx: number): number {
    let sz: number;
    args.buffer = data;
    args.buffer_idx = dataIdx + CONSTANTS.SIZEOF_LENGTH;
    sz = cb(args);
    if (sz < 0) {
      if (sz === CONSTANTS.SPROTO_CB_NIL) {
        return 0;
      }
      return -1;
    }
    return fillSize(data, dataIdx, sz);
  }

  function uint32ToUint64(negative: boolean, buffer: number[], bufferIdx: number): void {
    if (negative) {
      buffer[bufferIdx + 4] = 0xff;
      buffer[bufferIdx + 5] = 0xff;
      buffer[bufferIdx + 6] = 0xff;
      buffer[bufferIdx + 7] = 0xff;
    } else {
      buffer[bufferIdx + 4] = 0;
      buffer[bufferIdx + 5] = 0;
      buffer[bufferIdx + 6] = 0;
      buffer[bufferIdx + 7] = 0;
    }
  }

  function encodeIntegerArray(cb: (args: SprotoArgs) => number, args: SprotoArgs, buffer: number[], bufferIdx: number, noarray: { value: number }): number | null {
    let intlen: number, index: number;
    const headerIdx = bufferIdx;

    bufferIdx++;
    intlen = 4;
    index = 1;
    noarray.value = 0;

    for (; ;) {
      let sz: number;
      args.value = null;
      args.length = 8;
      args.index = index;
      sz = cb(args);
      if (sz <= 0) {
        if (sz === CONSTANTS.SPROTO_CB_NIL) {
          break;
        }

        if (sz === CONSTANTS.SPROTO_CB_NOARRAY) {
          noarray.value = 1;
          break;
        }

        return null;
      }

      if (sz === 4) {
        const v = args.value as number;
        buffer[bufferIdx] = v & 0xff;
        buffer[bufferIdx + 1] = (v >> 8) & 0xff;
        buffer[bufferIdx + 2] = (v >> 16) & 0xff;
        buffer[bufferIdx + 3] = (v >> 24) & 0xff;

        if (intlen === 8) {
          uint32ToUint64((v & 0x80000000) !== 0, buffer, bufferIdx);
        }
      } else {
        if (sz !== 8) {
          return null;
        }

        if (intlen === 4) {
          bufferIdx += (index - 1) * 4;
          for (let i = index - 2; i >= 0; i--) {
            let negative: boolean;
            for (let j = (1 + i * 8); j < (1 + i * 8 + 4); j++) {
              buffer[headerIdx + j] = buffer[headerIdx + j - i * 4];
            }
            negative = (buffer[headerIdx + 1 + i * 8 + 3] & 0x80) !== 0;
            uint32ToUint64(negative, buffer, headerIdx + 1 + i * 8);
          }
          intlen = 8;
        }

        const v = args.value as number | bigint;
        if (typeof v === 'bigint') {
          // 补丁：bigint 元素按补码逐字节写，不经过 float64 除法
          let u = v < 0n ? v + 0x10000000000000000n : v;
          for (let k = 0; k < 8; k++) {
            buffer[bufferIdx + k] = Number(u & 0xffn);
            u >>= 8n;
          }
        } else {
          buffer[bufferIdx] = v & 0xff;
          buffer[bufferIdx + 1] = utils.uint64Rshift(v, 8) & 0xff;
          buffer[bufferIdx + 2] = utils.uint64Rshift(v, 16) & 0xff;
          buffer[bufferIdx + 3] = utils.uint64Rshift(v, 24) & 0xff;
          buffer[bufferIdx + 4] = utils.uint64Rshift(v, 32) & 0xff;
          buffer[bufferIdx + 5] = utils.uint64Rshift(v, 40) & 0xff;
          buffer[bufferIdx + 6] = utils.uint64Rshift(v, 48) & 0xff;
          buffer[bufferIdx + 7] = utils.uint64Rshift(v, 56) & 0xff;
        }
      }

      bufferIdx += intlen;
      index++;
    }

    if (bufferIdx === headerIdx + 1) {
      return headerIdx;
    }
    buffer[headerIdx] = intlen & 0xff;
    return bufferIdx;
  }

  function encodeArray(cb: (args: SprotoArgs) => number, args: SprotoArgs, data: number[], dataIdx: number): number {
    let sz: number;
    const buffer = data;
    let bufferIdx = dataIdx + CONSTANTS.SIZEOF_LENGTH;
    switch (args.type) {
      case CONSTANTS.SPROTO_TINTEGER:
        const noarray = { value: 0 };
        const result = encodeIntegerArray(cb, args, buffer, bufferIdx, noarray);
        if (result === null) {
          return -1;
        }
        bufferIdx = result;

        if (noarray.value !== 0) {
          return 0;
        }
        break;
      case CONSTANTS.SPROTO_TBOOLEAN:
        args.index = 1;
        for (; ;) {
          let v = 0;
          args.value = v;
          args.length = 4;
          sz = cb(args);
          if (sz < 0) {
            if (sz === CONSTANTS.SPROTO_CB_NIL)
              break;
            if (sz === CONSTANTS.SPROTO_CB_NOARRAY)
              return 0;
            return -1;
          }

          if (sz < 1) {
            return -1;
          }

          buffer[bufferIdx] = (args.value === 1) ? 1 : 0;
          bufferIdx++;
          ++args.index!;
        }
        break;
      default:
        args.index = 1;
        for (; ;) {
          args.buffer = buffer;
          args.buffer_idx = bufferIdx + CONSTANTS.SIZEOF_LENGTH;
          sz = cb(args);
          if (sz < 0) {
            if (sz === CONSTANTS.SPROTO_CB_NIL) {
              break;
            }

            if (sz === CONSTANTS.SPROTO_CB_NOARRAY) {
              return 0;
            }

            return -1;
          }

          fillSize(buffer, bufferIdx, sz);
          bufferIdx += CONSTANTS.SIZEOF_LENGTH + sz;
          ++args.index!;
        }
        break;
    }

    sz = bufferIdx - (dataIdx + CONSTANTS.SIZEOF_LENGTH);
    return fillSize(buffer, dataIdx, sz);
  }

  function decodeArrayObject(cb: (args: SprotoArgs) => number, args: SprotoArgs, stream: number[], sz: number): number {
    let hsz: number;
    let index = 1;
    while (sz > 0) {
      if (sz < CONSTANTS.SIZEOF_LENGTH) {
        return -1;
      }

      hsz = utils.toDword(stream);
      stream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
      sz -= CONSTANTS.SIZEOF_LENGTH;
      if (hsz > sz) {
        return -1;
      }

      args.index = index;
      args.value = stream;
      args.length = hsz;
      if (cb(args) !== 0) {
        return -1;
      }

      sz -= hsz;
      stream = stream.slice(hsz);
      ++index;
    }
    return 0;
  }

  function decodeArray(cb: (args: SprotoArgs) => number, args: SprotoArgs, stream: number[]): number {
    const sz = utils.toDword(stream);
    const type = args.type;
    if (sz === 0) {
      args.index = -1;
      args.value = null;
      args.length = 0;
      cb(args);
      return 0;
    }

    stream = stream.slice(CONSTANTS.SIZEOF_LENGTH);
    switch (type) {
      case CONSTANTS.SPROTO_TINTEGER:
        const len = stream[0];
        stream = stream.slice(1);
        let remainingSz = sz - 1;
        if (len === 4) {
          if (remainingSz % 4 !== 0) {
            return -1;
          }
          for (let i = 0; i < Math.floor(remainingSz / 4); i++) {
            const value = utils.expand64(utils.toDword(stream.slice(i * 4)));
            args.index = i + 1;
            args.value = value;
            args.length = 8;
            cb(args);
          }
        } else if (len === 8) {
          if (remainingSz % 8 !== 0) {
            return -1;
          }

          for (let i = 0; i < Math.floor(remainingSz / 8); i++) {
            const low = utils.toDword(stream.slice(i * 8));
            const hi = utils.toDword(stream.slice(i * 8 + 4));
            const value = utils.int64(low, hi);
            args.index = i + 1;
            args.value = value;
            args.length = 8;
            cb(args);
          }
        } else {
          return -1;
        }
        break;
      case CONSTANTS.SPROTO_TBOOLEAN:
        for (let i = 0; i < sz; i++) {
          const value = stream[i];
          args.index = i + 1;
          args.value = value;
          args.length = 8;
          cb(args);
        }
        break;
      case CONSTANTS.SPROTO_TSTRING:
      case CONSTANTS.SPROTO_TSTRUCT:
        return decodeArrayObject(cb, args, stream, sz);
      default:
        return -1;
    }
    return 0;
  }

  function packSeg(src: number[], srcIdx: number, buffer: number[], bufferIdx: number, sz: number, n: number): number {
    let header = 0;
    let notzero = 0;
    const obufferIdx = bufferIdx;
    bufferIdx++;
    sz--;
    if (sz < 0) {
      return 10;
    }

    for (let i = 0; i < 8; i++) {
      if (src[srcIdx + i] !== 0) {
        notzero++;
        header |= 1 << i;
        if (sz > 0) {
          buffer[bufferIdx] = src[srcIdx + i];
          ++bufferIdx;
          --sz;
        }
      }
    }

    if ((notzero === 7 || notzero === 6) && n > 0) {
      notzero = 8;
    }

    if (notzero === 8) {
      if (n > 0) {
        return 8;
      } else {
        return 10;
      }
    }

    buffer[obufferIdx] = header;
    return notzero + 1;
  }

  function writeFf(src: number[], srcIdx: number, des: number[], destIdx: number, n: number): void {
    const align8N = (n + 7) & (~7);
    des[destIdx] = 0xff;
    des[destIdx + 1] = Math.floor(align8N / 8) - 1;

    for (let i = 0; i < n; i++) {
      des[destIdx + i + 2] = src[srcIdx + i];
    }

    for (let i = 0; i < align8N - n; i++) {
      des[destIdx + n + 2 + i] = 0;
    }
  }

  function sprotoPack(srcv: number[], srcIdx: number, bufferv: number[], bufferIdx: number): number {
    const tmp = new Array(8);
    let ffSrcstart: number[] = [];
    let ffDesstart: number[] = [];
    let ffSrcstartIdx = 0;
    let ffDesstartIdx = 0;
    let ffN = 0;
    let size = 0;
    let src = srcv;
    const buffer = bufferv;
    const srcsz = srcv.length;
    let bufsz = 1 << 30;

    for (let i = 0; i < srcsz; i += 8) {
      let n: number;
      const padding = i + 8 - srcsz;
      if (padding > 0) {
        for (let j = 0; j < 8 - padding; j++) {
          tmp[j] = src[srcIdx + j];
        }

        for (let j = 0; j < padding; j++) {
          tmp[7 - j] = 0;
        }

        src = tmp;
        srcIdx = 0;
      }

      n = packSeg(src, srcIdx, buffer, bufferIdx, bufsz, ffN);
      bufsz -= n;
      if (n === 10) {
        ffSrcstart = src;
        ffSrcstartIdx = srcIdx;
        ffDesstart = buffer;
        ffDesstartIdx = bufferIdx;
        ffN = 1;
      } else if (n === 8 && ffN > 0) {
        ++ffN;
        if (ffN === 256) {
          if (bufsz >= 0) {
            writeFf(ffSrcstart, ffSrcstartIdx, ffDesstart, ffDesstartIdx, 256 * 8);
          }
          ffN = 0;
        }
      } else {
        if (ffN > 0) {
          if (bufsz >= 0) {
            writeFf(ffSrcstart, ffSrcstartIdx, ffDesstart, ffDesstartIdx, ffN * 8);
          }
          ffN = 0;
        }
      }
      srcIdx += 8;
      bufferIdx += n;
      size += n;
    }
    if (bufsz >= 0) {
      if (ffN === 1) {
        writeFf(ffSrcstart, ffSrcstartIdx, ffDesstart, ffDesstartIdx, 8);
      } else if (ffN > 1) {
        writeFf(ffSrcstart, ffSrcstartIdx, ffDesstart, ffDesstartIdx, srcsz - ffSrcstartIdx);
      }
      if (buffer.length > size) {
        for (let i = size; i < buffer.length; i++) {
          buffer[i] = 0;
        }
      }
    }
    return size;
  }

  function sprotoUnpack(srcv: number[], srcIdx: number, bufferv: number[], bufferIdx: number): number {
    const src = srcv;
    const buffer = bufferv;
    let size = 0;
    let srcsz = srcv.length;
    let bufsz = 1 << 30;
    while (srcsz > 0) {
      const header = src[srcIdx];
      --srcsz;
      ++srcIdx;
      if (header === 0xff) {
        let n: number;
        if (srcsz < 0) {
          return -1;
        }

        n = (src[srcIdx] + 1) * 8;
        if (srcsz < n + 1)
          return -1;

        srcsz -= n + 1;
        ++srcIdx;
        if (bufsz >= n) {
          for (let i = 0; i < n; i++) {
            buffer[bufferIdx + i] = src[srcIdx + i];
          }
        }

        bufsz -= n;
        bufferIdx += n;
        srcIdx += n;
        size += n;
      } else {
        for (let i = 0; i < 8; i++) {
          const nz = (header >>> i) & 1;
          if (nz !== 0) {
            if (srcsz < 0)
              return -1;

            if (bufsz > 0) {
              buffer[bufferIdx] = src[srcIdx];
              --bufsz;
              ++bufferIdx;
            }

            ++srcIdx;
            --srcsz;
          } else {
            if (bufsz > 0) {
              buffer[bufferIdx] = 0;
              --bufsz;
              ++bufferIdx;
            }
          }
          ++size;
        }
      }
    }
    return size;
  }

  // 导出方法
  api.pack = (inbuf: number[]): number[] => {
    const srcIdx = 0;
    const buffer: number[] = [];
    const bufferIdx = 0;
    sprotoPack(inbuf, srcIdx, buffer, bufferIdx);
    return buffer;
  };

  api.unpack = (inbuf: number[]): number[] => {
    const srcIdx = 0;
    const buffer: number[] = [];
    const bufferIdx = 0;
    sprotoUnpack(inbuf, srcIdx, buffer, bufferIdx);
    return buffer;
  };

  api.createNew = (binsch: number[]): SprotoInstance | null => {
    const s: Partial<SprotoInstance> = {};
    let enbuffer: number[];
    s.type_n = 0;
    s.protocol_n = 0;
    s.type = null;
    s.proto = null;
    s.tcache = new Map();
    s.pcache = new Map();
    const sp = createFromBundle(s as SprotoInstance, binsch, binsch.length);
    if (sp === null) return null;

    function sprotoEncode(st: SprotoType, buffer: number[], bufferIdx: number, cb: (args: SprotoArgs) => number, ud: SprotoUserData): number {
      const args: SprotoArgs = {};
      const headerIdx = bufferIdx;
      let dataIdx = bufferIdx;
      const headerSz = CONSTANTS.SIZEOF_HEADER + st.maxn * CONSTANTS.SIZEOF_FIELD;
      let index: number, lasttag: number, datasz: number;

      args.ud = ud;
      dataIdx = headerIdx + headerSz;
      index = 0;
      lasttag = -1;
      for (let i = 0; i < st.n; i++) {
        const f = st.f![i];
        const type = f.type;
        let value = 0;
        let sz = -1;
        args.tagname = f.name || undefined;
        args.tagid = f.tag;
        if (f.st !== null) {
          args.subtype = sp.type?.[f.st] || null;
        } else {
          args.subtype = null;
        }

        args.mainindex = f.key;
        args.extra = f.extra;
        if ((type & CONSTANTS.SPROTO_TARRAY) !== 0) {
          args.type = type & ~CONSTANTS.SPROTO_TARRAY;
          sz = encodeArray(cb, args, buffer, dataIdx);
        } else {
          args.type = type;
          args.index = 0;
          switch (type) {
            case CONSTANTS.SPROTO_TDOUBLE:
            case CONSTANTS.SPROTO_TINTEGER:
            case CONSTANTS.SPROTO_TBOOLEAN:
              args.value = 0;
              args.length = 8;
              args.buffer = buffer;
              args.buffer_idx = bufferIdx;
              sz = cb(args);
              if (sz < 0) {
                if (sz === CONSTANTS.SPROTO_CB_NIL)
                  continue;
                if (sz === CONSTANTS.SPROTO_CB_NOARRAY)
                  return 0;
                return -1;
              }
              if (sz === 4) {
                if (args.value < 0x7fff) {
                  value = (args.value + 1) * 2;
                  sz = 2;
                } else {
                  sz = encodeInteger(args.value, buffer, dataIdx, sz);
                }
              } else if (sz === 8) {
                if (type === CONSTANTS.SPROTO_TDOUBLE) {
                  sz = doubleToBinary(args.value, buffer, dataIdx);
                } else {
                  sz = encodeUint64(args.value, buffer, dataIdx, sz);
                }
              } else {
                return -1;
              }
              break;
            case CONSTANTS.SPROTO_TSTRUCT:
            case CONSTANTS.SPROTO_TSTRING:
              sz = encodeObject(cb, args, buffer, dataIdx);
              break;
          }
        }

        if (sz < 0)
          return -1;

        if (sz > 0) {
          let recordIdx: number, tag: number;
          if (value === 0) {
            dataIdx += sz;
          }
          recordIdx = headerIdx + CONSTANTS.SIZEOF_HEADER + CONSTANTS.SIZEOF_FIELD * index;
          tag = f.tag - lasttag - 1;
          if (tag > 0) {
            tag = (tag - 1) * 2 + 1;
            if (tag > 0xffff)
              return -1;
            buffer[recordIdx] = tag & 0xff;
            buffer[recordIdx + 1] = (tag >> 8) & 0xff;
            ++index;
            recordIdx += CONSTANTS.SIZEOF_FIELD;
          }
          ++index;
          buffer[recordIdx] = value & 0xff;
          buffer[recordIdx + 1] = (value >> 8) & 0xff;
          lasttag = f.tag;
        }
      }

      buffer[headerIdx] = index & 0xff;
      buffer[headerIdx + 1] = (index >> 8) & 0xff;

      datasz = dataIdx - (headerIdx + headerSz);
      dataIdx = headerIdx + headerSz;
      if (index !== st.maxn) {
        const v = buffer.slice(dataIdx, dataIdx + datasz);
        for (let s = 0; s < v.length; s++) {
          buffer[headerIdx + CONSTANTS.SIZEOF_HEADER + index * CONSTANTS.SIZEOF_FIELD + s] = v[s];
        }
        buffer.splice(headerIdx + CONSTANTS.SIZEOF_HEADER + index * CONSTANTS.SIZEOF_FIELD + v.length, buffer.length);
      }

      return CONSTANTS.SIZEOF_HEADER + index * CONSTANTS.SIZEOF_FIELD + datasz;
    }

    function encode(args: SprotoArgs): number {
      const self = args.ud;
      if (!self) {
        return CONSTANTS.SPROTO_CB_ERROR;
      }

      const currentDeep = self.deep ?? 0;
      if (currentDeep >= CONSTANTS.ENCODE_DEEPLEVEL) {
        alert("table is too deep");
        return -1;
      }

      if (!self.indata || self.indata[args.tagname!] === null || self.indata[args.tagname!] === undefined) {
        return CONSTANTS.SPROTO_CB_NIL;
      }

      let target: any = null;
      if (args.index! > 0) {
        if (args.tagname !== self.array_tag) {
          self.array_tag = args.tagname;

          if (typeof (self.indata[args.tagname!]) !== "object") {
            self.array_index = 0;
            return CONSTANTS.SPROTO_CB_NIL;
          }

          if (self.indata[args.tagname!] === null || self.indata[args.tagname!] === undefined) {
            self.array_index = 0;
            return CONSTANTS.SPROTO_CB_NOARRAY;
          }
        }
        target = self.indata[args.tagname!][args.index! - 1];
        if (target === null || target === undefined) {
          return CONSTANTS.SPROTO_CB_NIL;
        }
      } else {
        target = self.indata[args.tagname!];
      }

      switch (args.type) {
        case CONSTANTS.SPROTO_TINTEGER:
          {
            // 补丁：bigint 走独立分支。超过 int32 的直接按 8 字节编码；
            // 小值转回 number，后续路径（含 2 字节 tag 打包）与原来完全一致
            if (args.extra! <= 0 && typeof target === 'bigint') {
              if (target > 0x7FFFFFFFn || target < -0x80000000n) {
                args.value = target;
                return 8;
              }
              args.value = Number(target) >>> 0;
              return 4;
            }
            let v: number, vh: number;
            if (args.extra! > 0) {
              const vn = target as number;
              v = Math.floor(vn * args.extra! + 0.5);
            } else {
              v = target as number;
            }
            vh = utils.uint64Rshift(v, 31);
            if (vh === 0 || vh === -1) {
              args.value = v >>> 0;
              return 4;
            } else {
              args.value = v;
              return 8;
            }
          }
        case CONSTANTS.SPROTO_TDOUBLE:
          {
            args.value = target as number;
            return 8;
          }
        case CONSTANTS.SPROTO_TBOOLEAN:
          {
            const boolValue = target as boolean;
            if (boolValue === true) {
              args.value = 1;
            } else if (boolValue === false) {
              args.value = 0;
            }
            return 4;
          }
        case CONSTANTS.SPROTO_TSTRING:
          {
            let arr: number[];
            if (args.extra) {
              arr = target as number[];
            } else {
              const str = target as string;
              arr = utils.string2bytes(str);
            }

            const sz = arr.length;
            if (sz > args.length!) {
              args.length = sz;
            }
            for (let i = 0; i < arr.length; i++) {
              args.buffer![args.buffer_idx! + i] = arr[i];
            }
            return sz;
          }
        case CONSTANTS.SPROTO_TSTRUCT:
          {
            const sub: any = {};
            sub.st = args.subtype;
            sub.deep = currentDeep + 1;
            sub.indata = target as Record<string, unknown>;
            const r = sprotoEncode(args.subtype!, args.buffer!, args.buffer_idx!, encode, sub);
            if (r < 0) {
              return CONSTANTS.SPROTO_CB_ERROR;
            }
            return r;
          }
        default:
          alert("Invalid filed type " + args.type);
          return CONSTANTS.SPROTO_CB_ERROR;
      }
    }

    function sprotoDecode(st: SprotoType, data: number[], size: number, cb: (args: SprotoArgs) => number, ud: SprotoUserData): number {
      const args: SprotoArgs = {};
      const total = size;
      let stream: number[], datastream: number[], fn: number, tag: number;
      if (size < CONSTANTS.SIZEOF_HEADER) return -1;
      stream = data.slice(0);
      fn = utils.toWord(stream);
      stream = stream.slice(CONSTANTS.SIZEOF_HEADER);
      size -= CONSTANTS.SIZEOF_HEADER;
      if (size < fn * CONSTANTS.SIZEOF_FIELD)
        return -1;
      datastream = stream.slice(fn * CONSTANTS.SIZEOF_FIELD);
      size -= fn * CONSTANTS.SIZEOF_FIELD;
      args.ud = ud;

      tag = -1;
      for (let i = 0; i < fn; i++) {
        let currentdata: number[] | null = null;
        let f: SprotoField | null = null;
        let value = utils.toWord(stream.slice(i * CONSTANTS.SIZEOF_FIELD));
        ++tag;
        if ((value & 1) !== 0) {
          tag += Math.floor(value / 2);
          continue;
        }
        value = Math.floor(value / 2) - 1;
        currentdata = datastream.slice(0);
        if (value < 0) {
          let sz: number;
          if (size < CONSTANTS.SIZEOF_LENGTH) {
            return -1;
          }
          sz = utils.toDword(datastream);
          if (size < sz + CONSTANTS.SIZEOF_LENGTH) {
            return -1;
          }
          datastream = datastream.slice(sz + CONSTANTS.SIZEOF_LENGTH);
          size -= sz + CONSTANTS.SIZEOF_LENGTH;
        }
        f = findTag(st, tag);
        if (f === null) {
          continue;
        }
        args.tagname = f.name;
        args.tagid = f.tag;
        args.type = f.type & ~CONSTANTS.SPROTO_TARRAY;
        if (f.st !== null) {
          args.subtype = sp.type[f.st];
        } else {
          args.subtype = null;
        }

        args.index = 0;
        args.mainindex = f.key;
        args.extra = f.extra;
        if (value < 0) {
          if ((f.type & CONSTANTS.SPROTO_TARRAY) !== 0) {
            if (decodeArray(cb, args, currentdata)) {
              return -1;
            }
          } else {
            switch (f.type) {
              case CONSTANTS.SPROTO_TDOUBLE:
                {
                  const sz = utils.toDword(currentdata);
                  if (sz === 8) {
                    const doubleBin = currentdata.slice(CONSTANTS.SIZEOF_LENGTH, CONSTANTS.SIZEOF_LENGTH + 8);
                    args.value = binaryToDouble(doubleBin);
                    args.length = 8;
                    cb(args);
                  } else {
                    return -1;
                  }
                  break;
                }
              case CONSTANTS.SPROTO_TINTEGER:
                {
                  const sz = utils.toDword(currentdata);
                  if (sz === 4) {
                    const v = utils.expand64(utils.toDword(currentdata.slice(CONSTANTS.SIZEOF_LENGTH)));
                    args.value = v;
                    args.length = 8;
                    cb(args);
                  } else if (sz === 8) {
                    const low = utils.toDword(currentdata.slice(CONSTANTS.SIZEOF_LENGTH));
                    const hi = utils.toDword(currentdata.slice(CONSTANTS.SIZEOF_LENGTH + 4));
                    const v = utils.int64(low, hi);
                    args.value = v;
                    args.length = 8;
                    cb(args);
                  } else {
                    return -1;
                  }
                  break;
                }
              case CONSTANTS.SPROTO_TSTRING:
              case CONSTANTS.SPROTO_TSTRUCT:
                {
                  const sz = utils.toDword(currentdata);
                  args.value = currentdata.slice(CONSTANTS.SIZEOF_LENGTH);
                  args.length = sz;
                  if (cb(args) !== 0) {
                    return -1;
                  }
                  break;
                }
              default:
                return -1;
            }
          }
        } else if (f.type !== CONSTANTS.SPROTO_TINTEGER && f.type !== CONSTANTS.SPROTO_TBOOLEAN) {
          return -1;
        } else {
          args.value = value;
          args.length = 8;
          cb(args);
        }
      }
      return total - size;
    }

    function decode(args: SprotoArgs): number {
      const self = args.ud;
      let value: any;
      if (self.deep >= CONSTANTS.ENCODE_DEEPLEVEL) {
        alert("the table is too deep");
      }

      if (args.index !== 0) {
        if (args.tagname !== self.array_tag) {
          self.array_tag = args.tagname;
          self.result[args.tagname!] = [];
          if (args.index! < 0) {
            return 0;
          }
        }
      }

      switch (args.type) {
        case CONSTANTS.SPROTO_TINTEGER:
          {
            if (args.extra) {
              // 补丁：小数定点字段先转回 number 再除（定点值不应超过 2^53）
              const v = args.value as number | bigint;
              value = (typeof v === 'bigint' ? Number(v) : v) / args.extra;
            } else {
              value = args.value;
            }
            break;
          }
        case CONSTANTS.SPROTO_TDOUBLE:
          {
            value = args.value;
            break;
          }
        case CONSTANTS.SPROTO_TBOOLEAN:
          {
            if (args.value === 1) {
              value = true;
            } else if (args.value === 0) {
              value = false;
            } else {
              value = null;
            }
            break;
          }
        case CONSTANTS.SPROTO_TSTRING:
          {
            const arr: number[] = [];
            const valueArray = args.value as number[];
            for (let i = 0; i < args.length!; i++) {
              arr.push(valueArray[i]);
            }
            if (args.extra) {
              value = arr;
            } else {
              value = utils.bytes2string(arr);
            }
            break;
          }
        case CONSTANTS.SPROTO_TSTRUCT:
          {
            const sub: any = {};
            let r: number;
            sub.deep = self.deep + 1;
            sub.array_index = 0;
            sub.array_tag = null;
            sub.result = {};
            if (args.mainindex! >= 0) {
              sub.mainindex_tag = args.mainindex;
              r = sprotoDecode(args.subtype!, args.value as number[], args.length!, decode, sub);
              if (r < 0 || r !== args.length) {
                return r;
              }
              value = sub.result;
              break;
            } else {
              sub.mainindex_tag = -1;
              sub.key_index = 0;
              r = sprotoDecode(args.subtype!, args.value as number[], args.length!, decode, sub);
              if (r < 0) {
                return CONSTANTS.SPROTO_CB_ERROR;
              }
              if (r !== args.length!)
                return r;
              value = sub.result;
              break;
            }
          }
        default:
          alert("Invalid type");
      }

      if (args.index! > 0) {
        self.result[args.tagname!][args.index! - 1] = value;
      } else {
        self.result[args.tagname!] = value;
      }

      return 0;
    }

    function queryType(sp: SprotoInstance, typename: string): SprotoType | null {
      if (sp.tcache.has(typename)) {
        return sp.tcache.get(typename);
      }
      const typeinfo = sprotoType(sp, typename);
      if (typeinfo) {
        sp.tcache.set(typename, typeinfo);
        return typeinfo;
      }
      return null;
    }

    function protocol(sp: SprotoInstance, pname: string | number): SprotoProtocolInfo | null {
      let tag: number | null = null;
      let name: string | null = null;

      if (typeof (pname) === "number") {
        tag = pname;
        name = sprotoProtoName(sp, pname);
        if (!name)
          return null;
      } else {
        tag = sprotoProtoTag(sp, pname);
        name = pname;

        if (tag === -1) return null;
      }

      const request = sprotoProtoQuery(sp, tag, CONSTANTS.SPROTO_REQUEST);
      const response = sprotoProtoQuery(sp, tag, CONSTANTS.SPROTO_RESPONSE);
      return {
        tag: tag,
        name: name,
        request: request,
        response: response
      };
    }

    function queryProtoFunc(sp: SprotoInstance, pname: string | number): SprotoProtocolInfo | null {
      if (sp.pcache.has(pname)) {
        return sp.pcache.get(pname);
      }
      const protoinfo = protocol(sp, pname);
      if (protoinfo) {
        sp.pcache.set(protoinfo.name, protoinfo);
        sp.pcache.set(protoinfo.tag, protoinfo);
        return protoinfo;
      }
      return null;
    }

    sp.queryproto = function (protocolName: string | number): any {
      return queryProtoFunc(sp, protocolName);
    };
    sp.dump = function (): void {
      sprotoDump(this);
    };

    sp.objlen = function (type: string | number | SprotoType, inbuf: number[]): number | null {
      let st: SprotoType | null = null;
      if (typeof (type) === "string" || typeof (type) === "number") {
        st = queryType(sp, type as string);
        if (st === null) {
          return null;
        }
      } else {
        st = type;
      }

      const ud: any = {};
      ud.array_tag = null;
      ud.deep = 0;
      ud.result = {};
      return sprotoDecode(st, inbuf, inbuf.length, decode, ud);
    };

    sp.encode = function (type: string | number | SprotoType, indata: any): number[] | null {
      const self: any = {};

      let st: SprotoType | null = null;
      if (typeof (type) === "string" || typeof (type) === "number") {
        st = queryType(sp, type as string);
        if (st === null)
          return null;
      } else {
        st = type;
      }

      const tblIndex = 2;
      enbuffer = [];
      const bufferIdx = 0;
      self.st = st;
      self.tbl_index = tblIndex;
      self.indata = indata;
      for (; ;) {
        self.array_tag = null;
        self.array_index = 0;
        self.deep = 0;
        self.iter_index = tblIndex + 1;
        const r = sprotoEncode(st, enbuffer, bufferIdx, encode, self);
        if (r < 0) {
          return null;
        } else {
          return enbuffer;
        }
      }
    };

    sp.decode = function (type: string | number | SprotoType, inbuf: number[]): any {
      let st: SprotoType | null = null;
      if (typeof (type) === "string" || typeof (type) === "number") {
        st = queryType(sp, type as string);
        if (st === null) {
          return null;
        }
      } else {
        st = type;
      }

      const buffer = inbuf;
      const sz = inbuf.length;
      const ud: any = {};
      ud.array_tag = null;
      ud.deep = 0;
      ud.result = {};
      const r = sprotoDecode(st, buffer, sz, decode, ud);
      if (r < 0) {
        return null;
      }

      return ud.result;
    };

    sp.pack = function (inbuf: number[]): number[] {
      return api.pack(inbuf);
    };

    sp.unpack = function (inbuf: number[]): number[] {
      return api.unpack(inbuf);
    };

    sp.pencode = function (type: string | number | SprotoType, inbuf: any): number[] | null {
      const obuf = sp.encode(type, inbuf);
      if (obuf === null) {
        return null;
      }
      return sp.pack(obuf);
    };

    sp.pdecode = function (type: string | number | SprotoType, inbuf: number[]): any {
      const obuf = sp.unpack(inbuf);
      if (obuf === null) {
        return null;
      }
      return sp.decode(type, obuf);
    };

    sp.host = function (packagename?: string): any {
      function cla(this: SprotoHost, packagename?: string): void {
        const pkgName = packagename ? packagename : "package";
        this.proto = sp!; // sp is guaranteed to be non-null at this point
        const packageType = queryType(sp!, pkgName);
        this.package = packageType ? packageType : pkgName;
        this.session = {};
      }
      cla.prototype = host;

      return new (cla as any)(packagename);
    };

    host.attach = function (sp: SprotoInstance): (name: string, args: Record<string, unknown>, session?: number) => number[] {
      this.attachsp = sp;
      const self = this;
      return (name: string, args: Record<string, unknown>, session?: number): number[] => {
        const proto = queryProtoFunc(sp, name);
        if (!proto) {
          throw new Error('Protocol not found');
        }
        if (args && !proto.request) {
          throw new Error('Request not found');
        }
        if (!self.package) {
          throw new Error('Package not found');
        }
        if (!self.session) {
          throw new Error('Session not found');
        }

        headerTemp.type = proto.tag;
        headerTemp.session = session;

        const headerbuffer = sp.encode(self.package, headerTemp);
        if (headerbuffer === null) {
          throw new Error('Failed to encode header');
        }
        if (session!==undefined) {
          self.session[session] = proto.response ? proto.response : true;
        }

        if (args) {
          const databuffer = sp.encode(proto.request, args);
          if (databuffer === null) {
            throw new Error('Failed to encode data');
          }
          return sp.pack(utils.arrayconcat(headerbuffer, databuffer));
        } else {
          return sp.pack(headerbuffer);
        }
      };
    };

    function genResponse(self: SprotoHost, response: SprotoType | null, session: number): (args: Record<string, unknown>) => number[] {
      return function (args: Record<string, unknown>): number[] {
        headerTemp.type = null;
        headerTemp.session = session;
        const headerbuffer = self.proto.encode(self.package, headerTemp);
        if (response) {
          const databuffer = self.proto.encode(response, args);
          return self.proto.pack(utils.arrayconcat(headerbuffer, databuffer));
        } else {
          return self.proto.pack(headerbuffer);
        }
      };
    }

    host.dispatch = function (buffer: number[]): SprotoDispatchResult {
      const sp = this.proto;
      const bin = sp.unpack(buffer);
      let headerData: Record<string, unknown> = {};
      headerData.type = null;
      headerData.session = null;
      headerData = sp.decode(this.package, bin) || {};

      const usedSz = sp.objlen(this.package, bin);
      const leftbuffer = bin.slice(usedSz || 0, bin.length);
      if (headerData.type) {
        const proto = queryProtoFunc(sp, headerData.type as string | number);
        if (!proto) {
          throw new Error('Protocol not found');
        }

        let result: Record<string, unknown> | undefined;
        if (proto.request) {
          result = sp.decode(proto.request, leftbuffer) || undefined;
        }

        if (headerData.session && typeof headerData.session === 'number') {
          return {
            type: "REQUEST",
            pname: proto.name,
            result: result,
            responseFunc: genResponse(this, proto.response, headerData.session),
            session: headerData.session,
          };
        } else {
          return {
            type: "REQUEST",
            pname: proto.name,
            result: result,
          };
        }
      } else {
        const attachedSp = this.attachsp;
        const session = headerData.session as number;
        const response = this.session[session];
        delete this.session[session];

        if (response === true) {
          return {
            type: "RESPONSE",
            session: session,
          };
        } else {
          const result = attachedSp?.decode(response as SprotoType, leftbuffer) || undefined;
          return {
            type: "RESPONSE",
            session: session,
            result: result,
          };
        }
      }
    };

    return sp as SprotoInstance;
  };

  return api;
})();

export default sproto;
