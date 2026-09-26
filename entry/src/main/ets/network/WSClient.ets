import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@ohos.base';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';

const TAG_MODULE = 'WSClient';

export interface WSMessageCallback {
  onMessage: (data: string | ArrayBuffer) => void;
  onOpen: () => void;
  onClose: (code: number, reason: string) => void;
  onError: (error: Error) => void;
}

export class WSClient {
  private ws: webSocket.WebSocket | null = null;
  private url: string = '';
  private callbacks: WSMessageCallback[] = [];
  private heartbeatTimer: number = -1;
  private lastPongTime: number = 0;
  private reconnectAttempts: number = 0;
  private isConnected: boolean = false;
  private shouldReconnect: boolean = true;

  registerCallback(cb: WSMessageCallback): void {
    this.callbacks.push(cb);
  }

  /**
   * 建立 WebSocket 连接。
   * v2.0 修复（E-1/E-2）：返回 Promise<boolean>，在 'open' 事件回调内 resolve(true)
   * （resolve 前 isConnected 已置 true），调用方 await 返回时连接一定已建立、
   * 可立即发送 join 信令；失败 resolve(false)。
   */
  async connect(url: string, token?: string): Promise<boolean> {
    this.url = url;
    this.ws = webSocket.createWebSocket();

    // 传入认证 token（JWT）
    const headers: Record<string, string> = {};
    if (token && token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    return new Promise<boolean>((resolve) => {
      let settled: boolean = false;
      const settle = (value: boolean): void => {
        if (!settled) {
          settled = true;
          resolve(value);
        }
      };

      this.ws?.on('open', (err: Error) => {
        if (err) {
          Logger.error(TAG_MODULE, `WebSocket open failed: ${err.message}`);
          this.handleConnectError(err);
          settle(false);
          return;
        }
        this.isConnected = true;
        this.reconnectAttempts = 0;
        this.startHeartbeat();
        Logger.info(TAG_MODULE, `WebSocket connected: ${url}`);
        this.callbacks.forEach(cb => cb.onOpen());
        settle(true);
      });

      this.ws?.on('message', (err: Error, data: string | ArrayBuffer) => {
        if (err) {
          Logger.error(TAG_MODULE, `WS message error: ${err.message}`);
          return;
        }
        // 检查服务端 pong 应答，更新心跳计时器
        try {
          if (typeof data === 'string') {
            // arkts-no-any-unknown：JSON.parse 结果显式类型化
            const msg: Record<string, Object> = JSON.parse(data) as Record<string, Object>;
            if (msg['type'] === 'pong') {
              this.lastPongTime = Date.now();
              return; // pong 不透传给业务层
            }
          }
        } catch (_) { /* 非JSON消息或解析失败，正常走业务回调 */ }
        this.callbacks.forEach(cb => cb.onMessage(data));
      });

      // 关闭事件回调签名对齐 SDK：Callback<CloseResult>（(err, value) => void）
      this.ws?.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        if (err) {
          Logger.error(TAG_MODULE, `WS close error: ${err.message}`);
        }
        this.isConnected = false;
        this.stopHeartbeat();
        Logger.warn(TAG_MODULE, `WS closed: code=${value.code} reason=${value.reason}`);
        this.callbacks.forEach(cb => cb.onClose(value.code, value.reason));

        // CRITICAL: 指数退避重连
        if (this.shouldReconnect) {
          this.scheduleReconnect();
        }
      });

      this.ws?.on('error', (err: Error) => {
        Logger.error(TAG_MODULE, `WS error: ${err.message}`);
        this.callbacks.forEach(cb => cb.onError(err));
        settle(false);
      });

      // 发起连接（fire-and-forget）：连接成功由 'open' 事件 settle(true)；
      // 失败/异常由 catch settle(false)。SDK connect 返回 Promise<boolean>（无需类型转换）。
      try {
        const connectResult: Promise<boolean> | null =
          this.ws !== null ? this.ws.connect(url, { header: headers }) : null;
        if (connectResult !== null) {
          connectResult.catch((err: BusinessError) => {
            Logger.error(TAG_MODULE, `WS connect exception: ${JSON.stringify(err)}`);
            this.handleConnectError(err instanceof Error ? err : new Error(String(err)));
            settle(false);
          });
        }
      } catch (err) {
        Logger.error(TAG_MODULE, `WS connect threw: ${JSON.stringify(err)}`);
        this.handleConnectError(err instanceof Error ? err : new Error(String(err)));
        settle(false);
      }
    });
  }

  private handleConnectError(err: Error): void {
    this.callbacks.forEach(cb => cb.onError(err));
    if (this.shouldReconnect) {
      this.scheduleReconnect();
    }
  }

  send(data: string | ArrayBuffer): void {
    if (!this.ws || !this.isConnected) {
      Logger.warn(TAG_MODULE, 'Cannot send: not connected');
      return;
    }
    this.ws.send(data, (err: Error) => {
      if (err) {
        Logger.error(TAG_MODULE, `WS send failed: ${err.message}`);
      }
    });
  }

  disconnect(): void {
    this.shouldReconnect = false;
    this.stopHeartbeat();
    if (this.ws) {
      // close 参数为 WebSocketCloseOptions 结构
      this.ws.close({ code: 1000, reason: 'Client disconnect' });
      this.ws = null;
    }
    this.isConnected = false;
  }

  getIsConnected(): boolean {
    return this.isConnected;
  }

  // ─── 心跳 (5s间隔 / 15s超时) ───

  private startHeartbeat(): void {
    this.lastPongTime = Date.now();
    this.heartbeatTimer = setInterval(() => {
      const elapsed = Date.now() - this.lastPongTime;
      if (elapsed > Constants.WS_HEARTBEAT_TIMEOUT) {
        Logger.warn(TAG_MODULE, `Heartbeat timeout: ${elapsed}ms`);
        this.handleHeartbeatTimeout();
        return;
      }
      // 发送应用层 Ping 消息；lastPongTime 仅在收到 'pong' 应答时更新（见 message 回调）
      if (this.isConnected && this.ws) {
        this.ws.send(JSON.stringify({ type: 'ping', ts: Date.now() }), (err: Error) => {
          if (err) {
            Logger.warn(TAG_MODULE, `WS ping send failed: ${err.message}`);
          }
        });
      }
    }, Constants.WS_HEARTBEAT_INTERVAL);
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  private handleHeartbeatTimeout(): void {
    this.isConnected = false;
    this.stopHeartbeat();
    if (this.ws) {
      // close 参数为 WebSocketCloseOptions 结构
      this.ws.close({ code: 4001, reason: 'Heartbeat timeout' });
    }
  }

  // ─── 指数退避重连 (1s→2s→4s→8s→16s) ───

  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= Constants.WS_RECONNECT_MAX_RETRIES) {
      Logger.error(TAG_MODULE, `Max reconnect attempts reached: ${Constants.WS_RECONNECT_MAX_RETRIES}`);
      return;
    }

    const delay = Constants.WS_RECONNECT_BACKOFF_BASE * Math.pow(2, this.reconnectAttempts);
    this.reconnectAttempts++;
    
    Logger.info(TAG_MODULE, `Reconnecting in ${delay}ms (attempt ${this.reconnectAttempts})`);
    
    setTimeout(async () => {
      if (!this.shouldReconnect) return;
      try {
        await this.connect(this.url);
      } catch (err) {
        Logger.error(TAG_MODULE, `Reconnect failed: ${err}`);
      }
    }, delay);
  }
}
