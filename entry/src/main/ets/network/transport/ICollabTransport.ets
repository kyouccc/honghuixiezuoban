import { TransportKind } from './TransportKind';

/**
 * 传输连接状态机（transport 层向上暴露的状态，替代 WSClient 的内部连接态）。
 *
 * ArkTS 约束（构建实测 2026-08-08）：ArkTS 禁止 const 对象 + 同名 type 双声明
 * （arkts-unique-names）、禁止 `as const`（arkts-no-as-const）、禁止无类型对象字面量
 * （arkts-no-untyped-obj-literals）。故改为 class 静态只读单例 + 实例 code 字段：
 * `TransportState` 同时充当值空间（TransportState.OPEN）与类型空间（state: TransportState），
 * Node（--experimental-transform-types）与 ArkTS 两端均验证通过。
 */
export class TransportState {
  static readonly IDLE: TransportState = new TransportState('IDLE');
  static readonly CONNECTING: TransportState = new TransportState('CONNECTING');
  static readonly OPEN: TransportState = new TransportState('OPEN');
  static readonly CLOSED: TransportState = new TransportState('CLOSED');
  static readonly RECONNECTING: TransportState = new TransportState('RECONNECTING');
  static readonly ERROR: TransportState = new TransportState('ERROR');
  static readonly UNSUPPORTED: TransportState = new TransportState('UNSUPPORTED');
  static readonly FAILED: TransportState = new TransportState('FAILED');

  /** 状态代号（'OPEN' / 'CLOSED' / ...），用于日志与序列化。 */
  readonly code: string;

  private constructor(code: string) {
    this.code = code;
  }
}

/** 连接凭证（握手用）。WS 通道至少携带 JWT token。 */
export interface TransportCredential {
  token: string;
  userId?: string;
}

export type MessageHandler = (data: string | ArrayBuffer) => void;
export type StateHandler = (state: TransportState) => void;

/**
 * 协同传输通道统一抽象（C02）。CollaborationManager 只依赖本接口，
 * 不再直接 new WSClient，从而为 C04/C05 的 P2P / 软总线通道预留插槽。
 */
export interface ICollabTransport {
  /** 建立连接（握手带上 credential，如 Authorization: Bearer）。 */
  connect(endpoint: string, credential: TransportCredential): Promise<boolean>;
  /** 发送（payload 为已编码的信令字节，如 SignalCodec.encode 产物）。 */
  send(payload: string | ArrayBuffer): void;
  /** 主动关闭（不再重连）。 */
  close(): void;
  /** 注册消息接收回调（替代 WSClient 的 onMessage）。 */
  onMessage(cb: MessageHandler): void;
  /** 注册状态变化回调（替代 WSClient 的 onOpen/onClose/onError 分事件）。 */
  onStateChange(cb: StateHandler): void;
}

/** 诚实条款：P2P 占位未实现时抛出的显式错误（绝不返回假装能用的空实现）。 */
export class UnsupportedTransportError extends Error {
  constructor(kind: TransportKind) {
    super(`TransportKind.${kind.code} is a placeholder only and not implemented yet (C04/C05 pending).`);
    this.name = 'UnsupportedTransportError';
  }
}
