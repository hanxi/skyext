// int64 安全的 JSON 解析。account 的 HTTP API（/roles、/create_role）里 rid 是
// 17 位 int64（如 70067467908940524 > 2^53），裸 JSON.parse 会静默丢精度，
// 拿着错 rid 去 login 会被服务端拒绝。
//
// 做法：先扫一遍响应文本（正确跳过字符串字面量与转义），把超出 Number.isSafeInteger
// 的整数字面量替换成带哨兵的字符串，JSON.parse 之后在 reviver 里还原成 bigint。
// 安全范围内的整数保持 number 不变，浮点数不动。

// 私用区码位做哨兵，业务文本里出现即视为数据损坏（概率可忽略，且会在测试里盯着）
const SENTINEL = "\uE000";
const SENTINEL_RE = /^\uE000(-?\d+)\uE000$/;

function isDigit(c: string): boolean {
    return c >= "0" && c <= "9";
}

/**
 * 把 JSON 文本中不安全的整数字面量替换为哨兵字符串。
 * 逐字符扫描并跟踪「是否在字符串内」，不会误伤字符串内容里的数字样文本。
 */
export function quoteUnsafeIntegers(text: string): string {
    let out = "";
    let i = 0;
    const n = text.length;
    while (i < n) {
        const c = text[i];
        if (c === '"') {
            // 原样搬运整个字符串字面量（含转义）
            out += c;
            i++;
            while (i < n) {
                const sc = text[i];
                out += sc;
                i++;
                if (sc === "\\") {
                    if (i < n) {
                        out += text[i];
                        i++;
                    }
                } else if (sc === '"') {
                    break;
                }
            }
            continue;
        }
        if (c === "-" || isDigit(c)) {
            // 扫一个完整的 number token
            const start = i;
            if (c === "-") {
                i++;
            }
            while (i < n && isDigit(text[i])) {
                i++;
            }
            const intEnd = i;
            let isFloat = false;
            if (i < n && text[i] === ".") {
                isFloat = true;
                i++;
                while (i < n && isDigit(text[i])) {
                    i++;
                }
            }
            if (i < n && (text[i] === "e" || text[i] === "E")) {
                isFloat = true;
                i++;
                if (i < n && (text[i] === "+" || text[i] === "-")) {
                    i++;
                }
                while (i < n && isDigit(text[i])) {
                    i++;
                }
            }
            const token = text.slice(start, i);
            if (!isFloat && !Number.isSafeInteger(Number(token))) {
                out += `"${SENTINEL}${token}${SENTINEL}"`;
            } else {
                out += token;
            }
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

/** JSON.parse 的 int64 安全版：超出 2^53 的整数还原为 bigint，其余语义不变 */
export function parseJson(text: string): unknown {
    return JSON.parse(quoteUnsafeIntegers(text), (_key, value) => {
        if (typeof value === "string") {
            const m = SENTINEL_RE.exec(value);
            if (m) {
                return BigInt(m[1]);
            }
        }
        return value;
    });
}
