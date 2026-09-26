/**
 * TransportKind.ets — 传输通道种类（C02 传输抽象）
 *
 * - WS：真实 WebSocket（包装既有 WSClient，零改动）
 * - LOOPBACK：内存回环，用于 Node 环境无真机端到端验证（验收④）
 * - P2P：软总线（分布式）通道 —— **仅枚举占位**，TransportFactory 遇到它显式抛错，
 *   不允许返回"看起来能跑其实什么都不做"的空实现（诚实条款）。
 *
 * ArkTS 约束（构建实测 2026-08-08）：ArkTS 禁止 const 对象 + 同名 type 双声明
 * （arkts-unique-names）、禁止 `as const`（arkts-no-as-const）、禁止无类型对象字面量
 * （arkts-no-untyped-obj-literals）。故改为 class 静态只读单例 + 实例 code 字段：
 * `TransportKind` 同时充当值空间（TransportKind.WS）与类型空间（kind: TransportKind），
 * Node（--experimental-transform-types）与 ArkTS 两端均验证通过。
 */
export class TransportKind {
  static readonly WS: TransportKind = new TransportKind('WS');
  static readonly LOOPBACK: TransportKind = new TransportKind('LOOPBACK');
  static readonly P2P: TransportKind = new TransportKind('P2P');

  /** 通道代号（'WS' / 'LOOPBACK' / 'P2P'），用于日志与错误消息。 */
  readonly code: string;

  private constructor(code: string) {
    this.code = code;
  }
}
