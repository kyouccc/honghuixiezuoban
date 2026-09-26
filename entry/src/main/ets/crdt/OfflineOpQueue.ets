/**
 * OfflineOpQueue.ets — 离线操作补发队列（C03 · Q14）
 *
 * 断网期间 CRDT op 入队，恢复连接后按序补发（onOpen 排空）。
 * 语义（Q14 已拍板，architecture-harmonycanvas-dualchannel-v1.md §4.5）：
 *  - 容量上限 2000 条：超限按 **FIFO 淘汰最旧**（保新不保旧：用户更在意刚画的）；
 *  - 持久化：不做（.hcnote 落盘链路超出本期范围）；
 *  - 淘汰行为：Logger.warn（由调用方记录）+ droppedCount 累计 + UI 告警（§4.6，
 *    DROPPED 持续可见，非一闪 toast——直到用户主动确认/离开会话）。
 *
 * 纯逻辑模块：不依赖任何 @kit / AppStorage，可在 Node 验证环境直接运行（沿用
 * tests/ets-loader.mjs 的 loader 模式）。
 */
import type { CRDTOp } from './types/CRDTOp';

export class OfflineOpQueue {
  /** 队列容量上限（Q14 拍板：2000 条） */
  private static readonly DEFAULT_MAX_SIZE: number = 2000;

  /** FIFO 队列（队首最旧，队尾最新） */
  private queue: CRDTOp[] = [];
  /** 容量上限 */
  private maxSize: number = OfflineOpQueue.DEFAULT_MAX_SIZE;
  /** 累计淘汰（丢弃）条数——只增不减，供 DROPPED 持续可见 */
  private droppedCount: number = 0;

  /** 测试/配置用：允许自定义容量（默认 2000） */
  constructor(maxSize?: number) {
    if (maxSize !== undefined && maxSize !== null && maxSize > 0) {
      this.maxSize = maxSize;
    }
  }

  /**
   * 入队。满时先 FIFO 淘汰最旧（droppedCount++），再入队最新。
   * 不抛异常：丢弃是显式语义，由调用方据 dropped() 变化触发 UI 告警。
   */
  enqueue(op: CRDTOp): void {
    if (this.queue.length >= this.maxSize) {
      // FIFO 淘汰最旧（保新不保旧）
      this.queue.shift();
      this.droppedCount++;
    }
    this.queue.push(op);
  }

  /**
   * 排空：返回全部待补发 op（队首→队尾，即产生顺序），并清空队列。
   * 注意：**不重置 droppedCount**——DROPPED 状态持续可见，直到 clear() / 用户确认。
   */
  drain(): CRDTOp[] {
    const out: CRDTOp[] = this.queue.slice();
    this.queue = [];
    return out;
  }

  /** 当前待补发条数（pendingOpCount） */
  size(): number {
    return this.queue.length;
  }

  /** 累计丢弃条数（droppedOpCount，DROPPED 持续可见依据） */
  dropped(): number {
    return this.droppedCount;
  }

  /** 是否已满 */
  isFull(): boolean {
    return this.queue.length >= this.maxSize;
  }

  /** 用户主动确认 / 离开会话时调用：清空队列并复位丢弃计数 */
  clear(): void {
    this.queue = [];
    this.droppedCount = 0;
  }
}
