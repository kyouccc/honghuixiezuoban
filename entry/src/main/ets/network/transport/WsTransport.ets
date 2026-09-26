/**
 * WsTransport.ets — WebSocket 传输实现（C02）
 *
 * 把既有 WSClient 收口到 ICollabTransport 后面，**不改 WSClient 一行**（验收②）。
 *
 * 红线修复（C02 核心）：WSClient 内部重连（scheduleReconnect → connect(this.url)）
 * **不带 token**，一旦断线重连，HTTP 升级头的 Authorization: Bearer 就丢了。
 * 实测结论：WSClient 的重连是内部自愈式，没有单独的"重连中"事件，只有常规
 * onClose/onOpen 回调。因此"监听重连事件后重新注入鉴权"无法在已建立的 socket 上
 * 补回 HTTP 头（应用层重发 JOIN 也补不回升级头）。故选 **transport 接管重连** 这一支：
 * WsTransport 自己驱动 connect(endpoint, token)，保证每次（含重连）握手都带鉴权头。
 *
 * 为在不动 WSClient 前提下压制其内置（无 token）自动重连：本类在 onClose 里调用
 * wsClient.disconnect()（这是唯一能把 WSClient.shouldReconnect 翻成 false 的路径）。
 * 经核对 WSClient 的 close 回调逻辑，disconnect() 在回调循环 evaluate
 * `if (shouldReconnect) scheduleReconnect()` 之前就把标志置 false，故内部重连不会被排程。
 * 重入安全：用 reconnectTimer 守卫，即便 disconnect() 再触发一次 onClose 也不会双排程。
 */
import { WSClient } from '../../network/WSClient';
import type { WSMessageCallback } from '../../network/WSClient';
import { Logger } from '../../common/Logger';
import { Constants } from '../../common/Constants';
import { SessionIdentity } from '../../common/identity/SessionIdentity';
import { TransportState } from './ICollabTransport';
import type { ICollabTransport, TransportCredential, MessageHandler, StateHandler } from './ICollabTransport';

const TAG = 'WsTransport';

export class WsTransport implements ICollabTransport {
  private ws: WSClient | null = null;
  private endpoint: string = '';
  private credential: TransportCredential | null = null;
  private intentionalClose: boolean = false;
  private reconnectAttempts: number = 0;
  private reconnectTimer: number = -1;
  private msgCb: MessageHandler | null = null;
  private stateCb: StateHandler | null = null;

  private static readonly MAX_RETRIES: number = Constants.WS_RECONNECT_MAX_RETRIES;
  private static readonly BACKOFF_BASE_MS: number = Constants.WS_RECONNECT_BACKOFF_BASE;

  async connect(endpoint: string, credential: TransportCredential): Promise<boolean> {
    this.endpoint = endpoint;
    this.credential = credential;
    this.intentionalClose = false;
    this.reconnectAttempts = 0;
    return this.openOnce();
  }

  /** 建立单次连接（携带 token）。重连也走这里，确保每次握手都带 Authorization。 */
  private async openOnce(): Promise<boolean> {
    this.clearReconnectTimer();
    const client: WSClient = new WSClient();
    this.ws = client;
    client.registerCallback(this.makeCallback());

    // 转派④：endpoint 优先取服务端下发的 ws_endpoint（SessionIdentity 已存），
    // 缺失才回退调用方传入的本地拼接地址，并留日志说明原因。
    const serverEndpoint: string = SessionIdentity.getInstance().wsEndpoint();
    const effectiveEndpoint: string =
      (serverEndpoint !== undefined && serverEndpoint.length > 0) ? serverEndpoint : this.endpoint;
    if (effectiveEndpoint === this.endpoint) {
      Logger.info(TAG, `WsTransport: ws_endpoint 回退到本地拼接 ${this.endpoint}（服务端未下发 ws_endpoint）`);
    } else {
      Logger.info(TAG, `WsTransport: 使用服务端下发 ws_endpoint ${effectiveEndpoint}`);
    }

    const token: string = this.credential !== null ? this.credential.token : '';
    this.notifyState(TransportState.CONNECTING);
    const ok: boolean = await client.connect(effectiveEndpoint, token.length > 0 ? token : undefined);
    if (ok) {
      this.reconnectAttempts = 0;
      this.notifyState(TransportState.OPEN);
    } else {
      this.notifyState(TransportState.ERROR);
    }
    return ok;
  }

  /** 构造 WSClient 回调适配器（避免与 ICollabTransport.onMessage 命名冲突）。 */
  private makeCallback(): WSMessageCallback {
    return {
      onMessage: (data: string | ArrayBuffer): void => {
        if (this.msgCb !== null) {
          this.msgCb(data);
        }
      },
      onOpen: (): void => {
        this.reconnectAttempts = 0;
        this.notifyState(TransportState.OPEN);
      },
      onClose: (code: number, reason: string): void => {
        this.handleWsClose(code, reason);
      },
      onError: (err: Error): void => {
        this.notifyState(TransportState.ERROR);
      }
    };
  }

  /**
   * WSClient 断线回调。非主动关闭时，接管重连（带 token）并压制 WSClient 内置无 token 重连。
   */
  private handleWsClose(code: number, reason: string): void {
    Logger.info(TAG, `WsTransport: 连接关闭 code=${code} reason=${reason}`);
    this.notifyState(TransportState.CLOSED);
    if (this.intentionalClose) {
      return;
    }
    if (this.reconnectTimer !== -1) {
      // 重入守卫：disconnect() 可能再触发一次 onClose，避免双排程
      return;
    }
    this.scheduleReconnect();
    // 压制 WSClient 内置（无 token）自动重连：disconnect() 把 shouldReconnect 翻 false，
    // 早于 WSClient 自身 `if (shouldReconnect) scheduleReconnect()` 的判定，故内部重连被取消。
    this.suppressInternalReconnect();
  }

  /** 接管重连：指数退避，每次都带 token（修复红线）。 */
  private scheduleReconnect(): void {
    if (this.reconnectAttempts >= WsTransport.MAX_RETRIES) {
      Logger.error(TAG, `WsTransport: 重连次数耗尽（${WsTransport.MAX_RETRIES}），放弃`);
      this.notifyState(TransportState.FAILED);
      return;
    }
    const delay: number = WsTransport.BACKOFF_BASE_MS * Math.pow(2, this.reconnectAttempts);
    this.reconnectAttempts++;
    this.notifyState(TransportState.RECONNECTING);
    Logger.info(TAG, `WsTransport: ${delay}ms 后重连（第 ${this.reconnectAttempts} 次，带鉴权）`);
    this.reconnectTimer = setTimeout((): void => {
      this.openOnce();
    }, delay) as number;
  }

  /** 压制 WSClient 内置自动重连（见类注释）。 */
  private suppressInternalReconnect(): void {
    if (this.ws !== null) {
      this.ws.disconnect();
    }
  }

  send(payload: string | ArrayBuffer): void {
    if (this.ws !== null) {
      this.ws.send(payload);
    } else {
      Logger.warn(TAG, 'WsTransport: send 忽略，未连接');
    }
  }

  close(): void {
    this.intentionalClose = true;
    this.clearReconnectTimer();
    if (this.ws !== null) {
      this.ws.disconnect();
      this.ws = null;
    }
    this.notifyState(TransportState.CLOSED);
  }

  onMessage(cb: MessageHandler): void {
    this.msgCb = cb;
  }

  onStateChange(cb: StateHandler): void {
    this.stateCb = cb;
  }

  private notifyState(state: TransportState): void {
    if (this.stateCb !== null) {
      this.stateCb(state);
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer !== -1) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
  }
}
