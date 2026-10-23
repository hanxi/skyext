// 传输层。事件模型直接映射浏览器 WebSocket：帧边界即包边界，binary 帧不加
// 任何长度前缀（docs/guide/client_protocol.md 第 2 节）。小程序等没有标准
// WebSocket 的环境按 Transport 接口注入自定义实现（session 层只依赖接口）。

/** 接入点。ws_url 来自 account 的 /gates（不写死在客户端配置里） */
export interface Endpoint {
    /** "ws://host:port" 或 "wss://…" */
    url: string;
}

/** 一条已建立的连接。send 在连接已断时会抛错，调用方（会话层）容忍它，
 *  真正的断线信号是 onClosed */
export interface TransportConn {
    /** 发送一个完整的包（一次调用 = 一个 binary 帧） */
    send(bytes: Uint8Array): void;
    /** 主动关闭。幂等；关闭触发的 onClosed 由会话层按代际标记忽略 */
    close(): void;
    /** 注册收包回调。每收到一个完整包调用一次 */
    onMessage(cb: (bytes: Uint8Array) => void): void;
    /** 注册断开回调（对端关闭、网络错误、本机 close 都会触发）。至多回调一次 */
    onClosed(cb: () => void): void;
}

export interface Transport {
    /** 建连。失败 reject，由上层（会话层）换下一台 gate */
    connect(endpoint: Endpoint): Promise<TransportConn>;
}

/**
 * 标准 WebSocket 实现。WS 实现可注入（测试、或 API 兼容 WebSocket 的适配器）。
 * connect 在 onopen 时 resolve；此后 onclose/onerror 归一为一次 onClosed。
 */
export function wsTransport(WS: typeof WebSocket = globalThis.WebSocket): Transport {
    return {
        connect(endpoint: Endpoint): Promise<TransportConn> {
            return new Promise<TransportConn>((resolve, reject) => {
                const sock = new WS(endpoint.url);
                sock.binaryType = "arraybuffer";

                let opened = false;
                let closedNotified = false;
                let messageCb: ((bytes: Uint8Array) => void) | null = null;
                let closedCb: (() => void) | null = null;

                const notifyClosed = () => {
                    if (closedNotified) {
                        return;
                    }
                    closedNotified = true;
                    closedCb?.();
                };

                sock.onopen = () => {
                    opened = true;
                    resolve(conn);
                };
                sock.onmessage = (ev: MessageEvent) => {
                    // binaryType 已固定为 arraybuffer；不是就丢弃（防御异常实现）
                    if (ev.data instanceof ArrayBuffer) {
                        messageCb?.(new Uint8Array(ev.data));
                    }
                };
                sock.onerror = () => {
                    if (!opened) {
                        reject(new Error(`websocket: 无法连接 ${endpoint.url}`));
                    }
                    // 已建连的错误交给随后的 onclose 统一处理
                };
                sock.onclose = () => {
                    if (!opened) {
                        reject(new Error(`websocket: 握手失败 ${endpoint.url}`));
                        return;
                    }
                    notifyClosed();
                };

                const conn: TransportConn = {
                    send(bytes: Uint8Array): void {
                        sock.send(bytes);
                    },
                    close(): void {
                        try {
                            sock.close();
                        } catch {
                            // 已经在关闭中：忽略
                        }
                    },
                    onMessage(cb: (bytes: Uint8Array) => void): void {
                        messageCb = cb;
                    },
                    onClosed(cb: () => void): void {
                        closedCb = cb;
                        // onclose 可能在注册之前就发生过（同步失败的边缘情形）
                        if (closedNotified) {
                            cb();
                        }
                    },
                };
            });
        },
    };
}
