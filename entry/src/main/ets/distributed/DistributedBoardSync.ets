/**
 * DistributedBoardSync.ets — 分布式画布/笔记同步传输适配器（v2.0 增量，S2T01 / S2T03）
 *
 * 说明：架构 v2.0 §2 将本文件标注为 [改]（v1 传输适配器扩展），但 v1 代码库中不存在
 * 同名文件，故按"以现有代码实际结构为准做最小兼容扩展"原则【新建】本文件，
 * 承担传输适配器职责：
 *  - 把 SessionManager 会话状态（超级终端流转）与 ViewportSyncManager 视口跟随
 *    桥接到网络层（CollaborationManager / WS）；
 *  - 承接视口同步消息转发（MSG_VIEWPORT_SYNC，低频控制消息，不进 CRDT 数据面）；
 *  - 转发远端元素（CanvasElement 全类型，S2T03）与状态续传快照。
 *
 * 纯逻辑模块：不依赖 @kit.*（QA 可在 Node 环境直接验证）。
 */

import { Logger } from '../common/Logger';
import { SessionManager, FlowSessionState, SessionDeviceRole } from './SessionManager';
import { ViewportSyncManager, ViewportState } from './ViewportSyncManager';
import { CanvasElement } from '../engine/types/CanvasElement';

const TAG_MODULE = 'DistributedBoardSync';

/** 板面同步监听者（由网络层/页面层注册） */
export interface BoardSyncListener {
  onViewportSyncReceived: (vp: ViewportState) => void;
  onRemoteElementReceived: (element: CanvasElement) => void;
  onSessionResumed: (state: FlowSessionState) => void;
}

export class DistributedBoardSync {
  private static instance: DistributedBoardSync | null = null;
  private sessionManager: SessionManager = SessionManager.getInstance();
  private viewportSync: ViewportSyncManager = ViewportSyncManager.getInstance();
  private listeners: BoardSyncListener[] = [];
  private enabled: boolean = false;

  static getInstance(): DistributedBoardSync {
    if (!DistributedBoardSync.instance) {
      DistributedBoardSync.instance = new DistributedBoardSync();
    }
    return DistributedBoardSync.instance;
  }

  setEnabled(enabled: boolean): void {
    this.enabled = enabled;
    Logger.info(TAG_MODULE, `Board sync ${enabled ? 'enabled' : 'disabled'}`);
  }

  isEnabled(): boolean {
    return this.enabled;
  }

  getSessionManager(): SessionManager {
    return this.sessionManager;
  }

  getViewportSyncManager(): ViewportSyncManager {
    return this.viewportSync;
  }

  /** 创建笔记会话（本机 NoteHost），返回会话状态 */
  attachSession(noteId: string, deviceGroupId: string): FlowSessionState {
    return this.sessionManager.createSession(noteId, deviceGroupId);
  }

  /** 状态续传（网络层收到主机快照后调用） */
  resumeFromNetwork(state: FlowSessionState): void {
    const resumed: boolean = this.sessionManager.resumeSession(state.sessionId, state);
    if (resumed) {
      for (const listener of this.listeners) {
        listener.onSessionResumed(state);
      }
    }
  }

  /**
   * 引擎视口变化入口：节流后返回待同步 ViewportState（null=未达节流窗口）。
   * 上层（CollaborationManager/页面）拿到返回值后发送 MSG_VIEWPORT_SYNC。
   */
  syncViewportFromEngine(centerX: number, centerY: number, scale: number, currentPage: number): ViewportState | null {
    if (!this.enabled) {
      return null;
    }
    const vp: ViewportState | null = this.viewportSync.updateLocalViewport(centerX, centerY, scale, currentPage);
    if (vp !== null) {
      this.sessionManager.syncViewport(vp);
    }
    return vp;
  }

  /** 网络层收到远端 MSG_VIEWPORT_SYNC 后转发到本地监听者（渲染"当前位置"标识） */
  onRemoteViewport(vp: ViewportState): void {
    this.viewportSync.onRemoteViewport(vp);
    for (const listener of this.listeners) {
      listener.onViewportSyncReceived(vp);
    }
  }

  /** 网络层收到远端 CRDT 元素（S2T03，CanvasElement 全类型）后转发 */
  onRemoteElement(element: CanvasElement): void {
    for (const listener of this.listeners) {
      listener.onRemoteElementReceived(element);
    }
  }

  registerListener(listener: BoardSyncListener): void {
    this.listeners.push(listener);
  }

  unregisterListener(listener: BoardSyncListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  getLocalRole(): SessionDeviceRole {
    return this.sessionManager.getLocalRole();
  }

  canWrite(): boolean {
    return this.sessionManager.canWrite();
  }

  reset(): void {
    this.enabled = false;
    this.listeners = [];
    this.sessionManager.reset();
    this.viewportSync.reset();
  }
}
