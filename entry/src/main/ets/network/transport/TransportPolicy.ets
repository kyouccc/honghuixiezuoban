import { TransportKind } from './TransportKind';

/** 决策可用的条件（纯输入，无副作用，方便单测）。 */
export interface TransportConditions {
  /** 显式强制某种通道（最高优先级，绕过策略）。 */
  forceKind?: TransportKind;
  /** 优先走内存回环（Node 验证环境 / 单测设为 true）。 */
  preferLoopback?: boolean;
  /** 软总线（分布式）是否可用（C04/C05 接入后置 true）。 */
  p2pAvailable?: boolean;
}

/**
 * 纯函数：根据可用条件决策使用哪种传输通道。
 * 无副作用、无 I/O、确定性——可直接单测（验收⑤）。
 *
 * 优先级：forceKind > preferLoopback > p2pAvailable > 默认 WS。
 * 注：即便 p2pAvailable=true，这里仍返回 P2P；P2P 的"未实现"由 TransportFactory
 * 显式抛错，策略层只负责"选它"，不负责"它能不能跑"（职责分离，避免策略层假装可用）。
 *
 * ArkTS 约束（构建实测 2026-08-08）：ArkTS 禁止无类型对象字面量
 * （arkts-no-untyped-obj-literals），故由 const 对象字面量改为 class 静态方法
 * （调用方 TransportPolicy.resolve(...) 形式不变，Node 与 ArkTS 两端均验证通过）。
 */
export class TransportPolicy {
  static resolve(conditions: TransportConditions): TransportKind {
    if (conditions.forceKind !== undefined) {
      return conditions.forceKind;
    }
    if (conditions.preferLoopback === true) {
      return TransportKind.LOOPBACK;
    }
    if (conditions.p2pAvailable === true) {
      return TransportKind.P2P;
    }
    return TransportKind.WS;
  }
}
