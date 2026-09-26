/**
 * CrdtSessionRegistry.ets — CRDT 会话注册表（S2-Cc / T2-5c 新建，t25 §5）
 *
 * 按 noteId 分区：同 note 多窗口共享同一 CrdtSession（一个 RGA 引擎 + 一个 lamport 时钟 +
 * 一份 processedOps）——避免同 note 双引擎分叉（t25 §5.2）。
 *
 * 引用计数生命周期（架构师特别提醒）：
 *  - acquire(noteId)：refCount++；不存在则新建 session（RGAEngine 实例 + 资产待同步集合）；
 *  - release(noteId)：refCount--；归零且无活动 op 时 flush + 可销毁（remove）；
 *  - 再打开窗口 → acquire 重建 session，由调用方从 oplog 恢复（本类不负责文件 I/O）。
 *
 * ArkTS 严格模式：无 any/unknown、显式类型。
 */

import { Logger } from '../common/Logger';
import { RGAEngine } from '../crdt/RGAEngine';
import { CanvasElement } from './types/CanvasElement';

const TAG_MODULE = 'CrdtSessionRegistry';

/** 单个 note 的 CRDT 会话（t25 §5.2 CrdtSession） */
export interface CrdtSession {
  noteId: string;
  /** RGA 引擎（同 note 多窗口共享同一实例） */
  rgaEngine: RGAEngine<CanvasElement>;
  /** 资产待同步集合（imageHash；分片收齐校验通过后移除） */
  assetPending: Set<string>;
  /** 引用计数（打开窗口数；归零且无活动 op 时可销毁） */
  refCount: number;
  /** 最近活动时间戳（生命周期诊断用） */
  lastActiveAt: number;
}

export class CrdtSessionRegistry {
  private static instance: CrdtSessionRegistry | null = null;
  private sessions: Map<string, CrdtSession> = new Map();
  private siteId: string = 'local';

  private constructor() {
    this.siteId = this.readSiteId();
  }

  static getInstance(): CrdtSessionRegistry {
    if (!CrdtSessionRegistry.instance) {
      CrdtSessionRegistry.instance = new CrdtSessionRegistry();
    }
    return CrdtSessionRegistry.instance;
  }

  /**
   * 获取 note 的会话（引用计数 +1）。
   * 不存在则新建：RGAEngine(siteId) + 空资产集合。调用方负责从 oplog 恢复（applyRemoteOp 重放）。
   */
  acquire(noteId: string): CrdtSession {
    const existing: CrdtSession | undefined = this.sessions.get(noteId);
    if (existing !== undefined) {
      existing.refCount++;
      existing.lastActiveAt = Date.now();
      return existing;
    }
    const session: CrdtSession = {
      noteId: noteId,
      rgaEngine: new RGAEngine<CanvasElement>(this.siteId),
      assetPending: new Set<string>(),
      refCount: 1,
      lastActiveAt: Date.now(),
    };
    this.sessions.set(noteId, session);
    Logger.info(TAG_MODULE, `Session acquired: ${noteId} (refCount=1)`);
    return session;
  }

  /**
   * 释放 note 的会话（引用计数 -1）。
   * 归零 → 销毁（remove）：窗口数=0，session 可重建并从 oplog 恢复（t25 §5.4 生命周期）。
   */
  release(noteId: string): void {
    const session: CrdtSession | undefined = this.sessions.get(noteId);
    if (session === undefined) {
      return;
    }
    session.refCount = Math.max(0, session.refCount - 1);
    if (session.refCount === 0) {
      this.sessions.delete(noteId);
      Logger.info(TAG_MODULE, `Session destroyed (refCount=0): ${noteId}`);
    }
  }

  /** 取会话（不增计数；不存在返回 null） */
  getSession(noteId: string): CrdtSession | null {
    const session: CrdtSession | undefined = this.sessions.get(noteId);
    return session !== undefined ? session : null;
  }

  /** 活跃会话数（诊断） */
  sessionCount(): number {
    return this.sessions.size;
  }

  /** 销毁全部会话（进程退出 / 测试重置） */
  clearAll(): void {
    this.sessions.clear();
  }

  private readSiteId(): string {
    const stored: string | undefined = AppStorage.get<string>('siteId');
    return stored !== undefined && stored.length > 0 ? stored : 'local';
  }
}
