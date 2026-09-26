import { TransportKind } from './TransportKind';
import { WsTransport } from './WsTransport';
import { LoopbackTransport } from './LoopbackTransport';
import { UnsupportedTransportError } from './ICollabTransport';
import type { ICollabTransport } from './ICollabTransport';

/**
 * 按 Kind 构造传输实例。
 * - WS → WsTransport（包装 WSClient，零改动）
 * - LOOPBACK → LoopbackTransport（内存回环）
 * - P2P → **显式抛 UnsupportedTransportError**（诚实条款：绝不返回假实现）
 */
export class TransportFactory {
  static create(kind: TransportKind): ICollabTransport {
    if (kind === TransportKind.WS) {
      return new WsTransport();
    }
    if (kind === TransportKind.LOOPBACK) {
      return new LoopbackTransport();
    }
    if (kind === TransportKind.P2P) {
      throw new UnsupportedTransportError(TransportKind.P2P);
    }
    throw new UnsupportedTransportError(kind);
  }
}
