/**
 * ViewportSyncManager.ets — 视口/页码跟随管理器（v2.0 增量，S2T01 / HM-09）
 *
 * 职责：
 *  - 维护本地视口状态（中心坐标/缩放/当前页/时间戳）；
 *  - 低频节流（≤ VIEWPORT_SYNC_MAX_HZ，架构 §8.3 约定 5），视口跟随是 LWW 展示态，
 *    不进 CRDT 数据面、不进 op log；
 *  - 接收远端视口（MSG_VIEWPORT_SYNC），通知监听者渲染"当前位置"标识。
 *
 * 纯逻辑模块：不依赖 @kit.*（QA 可在 Node 环境直接验证）。
 */

import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';

const TAG_MODULE = 'ViewportSyncManager';

/** 视口状态（与 proto ViewportSyncMessage 对齐） */
export interface ViewportState {
  centerX: number;
  centerY: number;
  scale: number;
  currentPage: number;
  timestamp: number;
  senderDeviceId: string;
}

/** 视口跟随监听者 */
export interface ViewportSyncListener {
  onLocalViewportSynced: (vp: ViewportState) => void;
  onRemoteViewportReceived: (vp: ViewportState) => void;
}

export class ViewportSyncManager {
  private static instance: ViewportSyncManager | null = null;
  private lastLocalViewport: ViewportState | null = null;
  private lastRemoteViewport: ViewportState | null = null;
  private lastSentAt: number = 0;
  private listeners: ViewportSyncListener[] = [];
  private localDeviceId: string = 'local';

  static getInstance(): ViewportSyncManager {
    if (!ViewportSyncManager.instance) {
      ViewportSyncManager.instance = new ViewportSyncManager();
    }
    return ViewportSyncManager.instance;
  }

  setLocalDeviceId(deviceId: string): void {
    if (deviceId.length > 0) {
      this.localDeviceId = deviceId;
    }
  }

  getLocalDeviceId(): string {
    return this.localDeviceId;
  }

  /** 是否已过节流窗口（距上次发送 ≥ 1/MAX_HZ） */
  shouldSend(now: number): boolean {
    const intervalMs: number = 1000 / Constants.VIEWPORT_SYNC_MAX_HZ;
    return (now - this.lastSentAt) >= intervalMs;
  }

  /**
   * 更新本地视口并返回待同步的 ViewportState；未达节流窗口返回 null（不发）。
   * 由引擎视口变化入口（DistributedBoardSync.syncViewportFromEngine）调用。
   */
  updateLocalViewport(centerX: number, centerY: number, scale: number, currentPage: number): ViewportState | null {
    const now: number = Date.now();
    if (!this.shouldSend(now)) {
      return null;
    }
    const vp: ViewportState = {
      centerX: centerX,
      centerY: centerY,
      scale: scale,
      currentPage: currentPage,
      timestamp: now,
      senderDeviceId: this.localDeviceId
    };
    this.lastLocalViewport = vp;
    this.lastSentAt = now;
    for (const listener of this.listeners) {
      listener.onLocalViewportSynced(vp);
    }
    return vp;
  }

  /** 网络层收到远端 MSG_VIEWPORT_SYNC 后调用：记录 + 通知本地渲染"当前位置" */
  onRemoteViewport(vp: ViewportState): void {
    this.lastRemoteViewport = vp;
    Logger.info(TAG_MODULE, `Remote viewport: page=${vp.currentPage} scale=${vp.scale} from=${vp.senderDeviceId}`);
    for (const listener of this.listeners) {
      listener.onRemoteViewportReceived(vp);
    }
  }

  getLastRemoteViewport(): ViewportState | null {
    return this.lastRemoteViewport;
  }

  getLastLocalViewport(): ViewportState | null {
    return this.lastLocalViewport;
  }

  registerListener(listener: ViewportSyncListener): void {
    this.listeners.push(listener);
  }

  unregisterListener(listener: ViewportSyncListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reset(): void {
    this.lastLocalViewport = null;
    this.lastRemoteViewport = null;
    this.lastSentAt = 0;
    this.listeners = [];
  }
}
