/**
 * LoopbackTransport.ets — 内存回环通道（C02）
 *
 * 用于 Node 环境无真机跑通协同链路（验收④）。设计：两个实例通过静态 registry
 * 以 endpoint 名配对（或显式 pair）。send() 把消息投递给所有已配对的对端 deliver()，
 * 模拟网络传输。不依赖任何 @kit / AppStorage，可在纯 Node 中运行。
 */
import { TransportState } from './ICollabTransport';
import type { ICollabTransport, TransportCredential, MessageHandler, StateHandler } from './ICollabTransport';

export class LoopbackTransport implements ICollabTransport {
  private static registry: Map<string, LoopbackTransport> = new Map();
  private name: string = '';
  private peers: LoopbackTransport[] = [];
  private connected: boolean = false;
  private msgCb: MessageHandler | null = null;
  private stateCb: StateHandler | null = null;

  /** 测试用：清空静态配对表（避免用例间串扰）。 */
  static resetRegistry(): void {
    LoopbackTransport.registry.clear();
  }

  /** 显式配对两个实例（双向）。 */
  static pair(a: LoopbackTransport, b: LoopbackTransport): void {
    a.peers.push(b);
    b.peers.push(a);
  }

  async connect(endpoint: string, _credential: TransportCredential): Promise<boolean> {
    this.name = endpoint;
    LoopbackTransport.registry.set(endpoint, this);
    this.connected = true;
    this.notifyState(TransportState.OPEN);
    return true;
  }

  send(payload: string | ArrayBuffer): void {
    if (!this.connected) {
      return;
    }
    for (let i = 0; i < this.peers.length; i++) {
      this.peers[i].deliver(payload);
    }
  }

  /** 内部接收路径（对端 send → 本端 onMessage）。 */
  private deliver(payload: string | ArrayBuffer): void {
    if (this.msgCb !== null) {
      this.msgCb(payload);
    }
  }

  onMessage(cb: MessageHandler): void {
    this.msgCb = cb;
  }

  onStateChange(cb: StateHandler): void {
    this.stateCb = cb;
  }

  close(): void {
    this.connected = false;
    if (this.name.length > 0) {
      LoopbackTransport.registry.delete(this.name);
    }
    this.notifyState(TransportState.CLOSED);
  }

  private notifyState(state: TransportState): void {
    if (this.stateCb !== null) {
      this.stateCb(state);
    }
  }
}
