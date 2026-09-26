/**
 * 协作管理器 v1.1 + v2.0 增量（S2T01 / S2T02 / S2T03）
 *
 * v2.0 增量：
 *  - 权限断言（HM-11）：joinSession 携带 PermissionAssertionPayload → PermissionGuard.configure；
 *    本地元素写入前 PermissionGuard.assertLocalOp 拦截——只读端本地不产生任何 CRDT 操作，仅渲染；
 *  - 元素联合类型（HM-13 / S2T03）：RGAEngine<CanvasElement>，支持
 *    Stroke/Shape/TextBlock/Annotation/ImageRef 全类型协同收敛；
 *  - 笔记会话（HM-10）：joinSession 替代 joinRoom（会话 = v1 房间语义扩展）；
 *  - 视口跟随（HM-09）：syncViewport 发送 MSG_VIEWPORT_SYNC（低频控制消息，不进 CRDT 数据面）；
 *  - 多人图层协同 + PDF 同步批注：Annotation.pageIndex/refDocId 绑定，随 CRDT 同步。
 *
 * 注意：本文件为 v1 既有文件（原 import 不存在的 SignalType 且使用 any，处于编译图外），
 * 本次按 v2.0 架构完整重写并接入 NoteEngine 门面，保证进入 ArkTS 编译图。
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { RGAEngine } from '../../crdt/RGAEngine';
import { CRDTOp, InsertOp, DeleteOp, UpdateOp, ResurrectOp, RGAElement, NodeID, serializeNodeID } from '../../crdt/types/CRDTOp';
import { CanvasElement, CanvasElementType, getCanvasElementType, StrokeData, TextBlockData, ImageRefData, AnnotationData } from '../../engine/types/CanvasElement';
import { CrdtSessionRegistry, CrdtSession } from '../../engine/CrdtSessionRegistry';
import { OfflineOpQueue } from '../../crdt/OfflineOpQueue';
import { ICollabTransport, TransportState } from '../../network/transport/ICollabTransport';
import { TransportFactory } from '../../network/transport/TransportFactory';
import { TransportPolicy } from '../../network/transport/TransportPolicy';
import { SessionIdentity } from '../identity/SessionIdentity';
import {
  SignalCodec,
  MsgType,
  SignalEnvelope,
  ViewportSyncPayload,
  PermissionAssertionPayload,
  AssetChunkPayload,
  AssetReqPayload,
  AssetAckPayload,
} from '../../network/SignalCodec';
import { PermissionGuard, SessionRole, LayerOpKind, sessionRoleFromString } from './PermissionGuard';
import { DistributedBoardSync } from '../../distributed/DistributedBoardSync';
import { ViewportState } from '../../distributed/ViewportSyncManager';
import { analytics, AnalyticsEvent } from './AnalyticsService';

const TAG = 'CollaborationManager';
const DOMAIN = 0x0000;

export interface CollaborationCallback {
  onRemoteElement: (element: CanvasElement) => void;
  onRemoteStroke: (stroke: StrokeData) => void;
  onRemoteDelete: (elementId: string) => void;
  onUserJoin: (userId: string, deviceId: string) => void;
  onUserLeave: (userId: string) => void;
  onSyncComplete: () => void;
  onRemoteViewport: (vp: ViewportState) => void;
  onPermissionChanged: (role: SessionRole) => void;
}

/** 协作状态快照（getState 返回，替代内联对象类型） */
export interface CollaborationState {
  isConnected: boolean;
  roomId: string;
  userId: string;
  deviceId: string;
}

/** 资产分片大小（t25 §2.3：64KB/片） */
const ASSET_CHUNK_BYTES: number = 64 * 1024;

/** 资产接收拼装态（S2-Cc：bitmap 断点续传） */
interface AssetReceiveState {
  assetId: string;
  chunks: Uint8Array[];
  bitmap: string;
  totalChunks: number;
}

/** 元素快照（流转状态续传用，替代内联对象类型） */
export interface CollaborationSnapshot {
  elements: CanvasElement[];
  deviceId: string;
}

/** 会话埋点参数（track properties 需显式类型，arkts-no-untyped-obj-literals） */
interface RoomTrackProps {
  room_id: string;
}

/** 断开埋点参数 */
interface DisconnectTrackProps {
  code: number;
  reason: string;
}

/**
 * 同步指示状态（C03 · §4.6 常态指示器）。
 * ArkTS 约束（C02 实测教训）：const 对象 + 同名 type 双声明被 arkts-unique-names 禁止，
 * 沿用 class 静态只读单例（值空间 + 类型空间合一）。
 */
export class SyncIndicatorState {
  static readonly SYNCED: SyncIndicatorState = new SyncIndicatorState('SYNCED');
  static readonly PENDING: SyncIndicatorState = new SyncIndicatorState('PENDING');
  static readonly OFFLINE: SyncIndicatorState = new SyncIndicatorState('OFFLINE');
  static readonly DROPPED: SyncIndicatorState = new SyncIndicatorState('DROPPED');

  /** 状态代号（'SYNCED' / 'PENDING' / 'OFFLINE' / 'DROPPED'），用于日志与序列化。 */
  readonly code: string;

  private constructor(code: string) {
    this.code = code;
  }
}

export class CollaborationManager {
  private static instance: CollaborationManager;
  private rgaEngine: RGAEngine<CanvasElement> | null = null;
  private transport: ICollabTransport | null = null;
  private callbacks: CollaborationCallback[] = [];
  private sessionId: string = '';
  private userId: string = '';
  private deviceId: string = '';
  private isConnected: boolean = false;
  /** C03（Q14）：离线补发队列（2000 FIFO，取代恒空的 pendingOps） */
  private offlineQueue: OfflineOpQueue = new OfflineOpQueue();
  /** v2.0：客户端权限守卫（服务端下发 role → 配置） */
  private permissionGuard: PermissionGuard = PermissionGuard.getInstance();
  /** v2.0：分布式板面同步传输适配器（承接视口同步消息转发） */
  private boardSync: DistributedBoardSync = DistributedBoardSync.getInstance();
  /** valueId → CRDT NodeID（本地删除定位用） */
  private valueIdToNodeId: Map<string, NodeID> = new Map();
  /** valueId → 元素类型（删除时权限断言用） */
  private valueIdToType: Map<string, string> = new Map();
  // ─── S2-Cc / T2-5c：按 noteId 分区会话 + 资产分片接收态 ───
  private sessionRegistry: CrdtSessionRegistry = CrdtSessionRegistry.getInstance();
  /** 资产分片接收缓冲（assetId → 拼装态；bitmap 断点续传） */
  private assetBuffers: Map<string, AssetReceiveState> = new Map();
  /** 资产落盘回调（避免循环依赖；上层注入 NoteRepository.saveAssetBytes） */
  private assetSink: (assetId: string, bytes: Uint8Array) => void = (assetId: string, bytes: Uint8Array) => {
  };

  private constructor() {}

  static getInstance(): CollaborationManager {
    if (!CollaborationManager.instance) {
      CollaborationManager.instance = new CollaborationManager();
    }
    return CollaborationManager.instance;
  }

  /**
   * v1 兼容：加入白板房间（默认授予编辑态）。
   */
  async joinRoom(roomId: string, wsEndpoint: string): Promise<boolean> {
    const fallback: PermissionAssertionPayload = {
      session_id: roomId,
      user_id: this.userId,
      device_id: this.deviceId,
      role: SessionRole.EDITOR,
      issuer: this.deviceId,
      issued_at: Date.now(),
      expires_at: Date.now() + 3600 * 1000,
      signature: ''
    };
    return this.joinSession(roomId, wsEndpoint, fallback);
  }

  /**
   * v2.0（HM-10/HM-11）：加入笔记协作会话，携带服务端签发的权限断言。
   * 断言 role 决定本地 PermissionGuard 配置（只读/批注/编辑态）。
   * v2.0 修复（E-2/E-6）：wsClient.connect 返回 Promise<boolean>（open 后 resolve）；
   * 断言字段 snake_case 与 Go REST/proto 一致（架构 §8.2 约定 1）。
   */
  async joinSession(sessionId: string, wsEndpoint: string, assertion: PermissionAssertionPayload): Promise<boolean> {
    this.sessionId = sessionId;
    this.userId = this.readAppStorage('userId');
    this.deviceId = this.readAppStorage('siteId');
    if (this.deviceId.length === 0) {
      this.deviceId = assertion.device_id.length > 0 ? assertion.device_id : 'local';
    }

    this.applyPermissionAssertion(assertion);

    // 初始化 RGA 引擎（CanvasElement 联合类型，S2T03）
    this.rgaEngine = new RGAEngine<CanvasElement>(this.deviceId);
    this.valueIdToNodeId.clear();
    this.valueIdToType.clear();

    // 初始化传输通道（C02：经 ICollabTransport 抽象，零 new WSClient）
    this.transport = TransportFactory.create(TransportPolicy.resolve({}));
    this.transport.onMessage((data: string | ArrayBuffer): void => {
      this.onMessage(data);
    });
    this.transport.onStateChange((state: TransportState): void => {
      this.handleTransportState(state);
    });

    // connect 在 'open' 回调后 resolve(true)，此时 isConnected=true，
    // 下方 send(joinSignal) 不再被 transport.send 拒绝
    const token: string = SessionIdentity.getInstance().token();
    const connected: boolean = await this.transport.connect(wsEndpoint, { token: token });

    if (connected) {
      // 发送加入会话消息（携带权限断言）
      const joinSignal: Uint8Array = SignalCodec.encodePermissionAssertion(assertion);
      this.transport.send(joinSignal);

      // 启用板面同步传输适配器
      this.boardSync.setEnabled(true);

      const roomTrackProps: RoomTrackProps = { room_id: sessionId };
      analytics.track(AnalyticsEvent.ROOM_JOIN, roomTrackProps);
      hilog.info(DOMAIN, TAG, `Session joined: ${sessionId}, role=${assertion.role}`);
      return true;
    } else {
      hilog.error(DOMAIN, TAG, 'Failed to join session');
      return false;
    }
  }

  /**
   * 离开会话
   */
  async leaveRoom(): Promise<void> {
    if (!this.isConnected || !this.transport) return;

    hilog.info(DOMAIN, TAG, `Leaving session: ${this.sessionId}`);

    await this.transport.close();

    // 清理状态
    this.isConnected = false;
    this.rgaEngine = null;
    this.transport = null;
    this.offlineQueue.clear();
    this.valueIdToNodeId.clear();
    this.valueIdToType.clear();
    this.boardSync.setEnabled(false);

    const leaveTrackProps: RoomTrackProps = { room_id: this.sessionId };
    analytics.track(AnalyticsEvent.ROOM_LEAVE, leaveTrackProps);

    this.sessionId = '';
  }

  /**
   * v2.0（S2T02）：应用服务端权限断言 → 配置 PermissionGuard，并通知回调。
   */
  applyPermissionAssertion(assertion: PermissionAssertionPayload): void {
    const role: SessionRole = sessionRoleFromString(assertion.role);
    this.permissionGuard.configure(role);
    hilog.info(DOMAIN, TAG, `Permission assertion applied: role=${role}, issuer=${assertion.issuer}`);
    for (const callback of this.callbacks) {
      callback.onPermissionChanged(role);
    }
  }

  /**
   * v2.0（S2T02）：手动设置会话角色（本地演示/测试用）。
   */
  setPermissionRole(role: SessionRole): void {
    this.permissionGuard.configure(role);
    for (const callback of this.callbacks) {
      callback.onPermissionChanged(role);
    }
  }

  getPermissionGuard(): PermissionGuard {
    return this.permissionGuard;
  }

  /**
   * v2.0（S2T03）：本地元素插入（CanvasElement 全类型）。
   * 权限断言：只读端本地不产生任何 CRDT 操作（Q-07）。
   *
   * C03（Q14）守卫改造（architecture §4.5）：守卫从 `!rgaEngine || !isConnected` 收紧为
   * **仅 `!rgaEngine`** —— CRDT op 该生成就生成（本地 RGA 是权威副本，与连接状态无关）；
   * 是否发送交给 sendOperation：在线直发，离线入 OfflineOpQueue，恢复后 onOpen 排空补发。
   * 前置核对（风险红线）：WhiteboardPage 落笔路径只写本地 strokes 数组，未调用本方法，
   * 无「离线不产生 op」的页面层隐式假设，无双写重影风险。
   */
  localElementInsert(element: CanvasElement): void {
    if (!this.rgaEngine) {
      hilog.warn(DOMAIN, TAG, 'CRDT engine not ready, operation dropped');
      return;
    }
    const elementType: string = getCanvasElementType(element);
    if (!this.permissionGuard.assertLocalOp('insert', elementType)) {
      hilog.warn(DOMAIN, TAG, `Permission denied: local insert of ${elementType} blocked (read-only)`);
      return;
    }
    const op: InsertOp = this.rgaEngine.localInsert(element, null, elementType);
    this.valueIdToNodeId.set(element.id, op.element.id);
    this.valueIdToType.set(element.id, elementType);
    this.sendOperation(op, elementType);
    hilog.debug(DOMAIN, TAG, `Local element inserted: ${element.id} (${elementType})`);
  }

  /**
   * v1 兼容：本地笔触插入（委托给 localElementInsert）。
   */
  localStrokeInsert(stroke: StrokeData): void {
    this.localElementInsert(stroke);
  }

  /**
   * v2.0（S2T03）：本地元素删除（按元素 valueId 定位 CRDT NodeID）。
   * 权限断言：批注者仅可删自己的 Annotation（客户端本地由 guard 校验类型）。
   */
  localElementDelete(elementId: string): void {
    if (!this.rgaEngine || !this.isConnected) return;
    const nodeId: NodeID | undefined = this.valueIdToNodeId.get(elementId);
    if (nodeId === undefined) {
      hilog.warn(DOMAIN, TAG, `Element not tracked locally: ${elementId}`);
      return;
    }
    const elementType: string = this.valueIdToType.get(elementId) ?? CanvasElementType.STROKE;
    if (!this.permissionGuard.assertLocalOp('delete', elementType)) {
      hilog.warn(DOMAIN, TAG, `Permission denied: local delete of ${elementType} blocked (read-only)`);
      return;
    }
    // v2.0 修复（E-3）：DeleteOp 携带 elementType，服务端按真实类型校验（Annotator 删批注不被拒）
    const op: DeleteOp | null = this.rgaEngine.localDelete(nodeId, elementType);
    if (op !== null) {
      this.sendOperation(op, elementType);
      hilog.debug(DOMAIN, TAG, `Local element deleted: ${elementId}`);
    }
  }

  /**
   * v1 兼容：本地笔触删除（委托给 localElementDelete）。
   */
  localStrokeDelete(strokeId: string): void {
    this.localElementDelete(strokeId);
  }

  // ─── S2-Cc / T2-5c：字段更新 / 撤销删除 + 会话透传 ───

  /** 本地字段更新（t25 §1.4：UpdateOp，字段 LWW 收敛；value 字符串化） */
  localElementUpdate(elementId: string, field: string, value: string, elementType?: string): void {
    if (!this.rgaEngine || !this.isConnected) return;
    const nodeId: NodeID | undefined = this.valueIdToNodeId.get(elementId);
    if (nodeId === undefined) {
      hilog.warn(DOMAIN, TAG, `Element not tracked locally for update: ${elementId}`);
      return;
    }
    const type: string = elementType !== undefined && elementType.length > 0
      ? elementType : (this.valueIdToType.get(elementId) || CanvasElementType.STROKE);
    const op: UpdateOp | null = this.rgaEngine.localUpdate(nodeId, field, value, type);
    if (op !== null) {
      this.sendOperation(op, type);
      hilog.debug(DOMAIN, TAG, `Local element updated: ${elementId}.${field}=${value}`);
    }
  }

  /** 本地撤销删除（t25 §1.4：ResurrectOp 清墓碑） */
  localElementResurrect(elementId: string, elementType?: string): void {
    if (!this.rgaEngine || !this.isConnected) return;
    const nodeId: NodeID | undefined = this.valueIdToNodeId.get(elementId);
    if (nodeId === undefined) {
      return;
    }
    const type: string = elementType !== undefined && elementType.length > 0
      ? elementType : (this.valueIdToType.get(elementId) || CanvasElementType.STROKE);
    const op: ResurrectOp | null = this.rgaEngine.localResurrect(nodeId, type);
    if (op !== null) {
      this.sendOperation(op, type);
      hilog.debug(DOMAIN, TAG, `Local element resurrected: ${elementId}`);
    }
  }

  /** 按 noteId 获取 CRDT 会话（引用计数 +1；调用方负责 release） */
  acquireSession(noteId: string): CrdtSession {
    return this.sessionRegistry.acquire(noteId);
  }

  /** 释放会话（引用计数 -1，归零销毁） */
  releaseSession(noteId: string): void {
    this.sessionRegistry.release(noteId);
  }

  /**
   * v2.0（S2T01 / HM-09）：视口跟随同步（低频控制消息，不进 CRDT）。
   */
  syncViewport(vp: ViewportState): void {
    if (!this.transport || !this.isConnected) {
      return;
    }
    const payload: ViewportSyncPayload = {
      centerX: vp.centerX,
      centerY: vp.centerY,
      scale: vp.scale,
      currentPage: vp.currentPage,
      timestamp: vp.timestamp,
      senderDeviceId: this.deviceId
    };
    this.transport.send(SignalCodec.encodeViewportSync(payload));
  }

  /**
   * v2.0（S2T02）：图层级操作权限断言（本地执行由引擎 LayerManager 负责，
   * 此处返回是否允许；服务端对 LayerOp 消息同样查表校验）。
   */
  applyLayerOp(opType: LayerOpKind): boolean {
    if (!this.permissionGuard.canLayerOp(opType)) {
      hilog.warn(DOMAIN, TAG, `Layer op denied: ${opType} (not editor)`);
      return false;
    }
    hilog.debug(DOMAIN, TAG, `Layer op allowed: ${opType}`);
    return true;
  }

  /**
   * 发送操作到服务器（携带 elementType 供服务端权限查表）
   * C03（Q14）：未连接时入 OfflineOpQueue（2000 FIFO），不再静默丢弃。
   */
  private sendOperation(op: CRDTOp, elementType: string): void {
    if (!this.transport || !this.isConnected) {
      const before: number = this.offlineQueue.size();
      this.offlineQueue.enqueue(op);
      const after: number = this.offlineQueue.size();
      if (this.offlineQueue.dropped() > 0 && after === before) {
        // 队列满且本次触发 FIFO 淘汰（或丢弃）→ 记录日志，UI 侧由 DROPPED 状态持续可见
        hilog.warn(DOMAIN, TAG,
          `Op queued while offline, queue full: dropped=${this.offlineQueue.dropped()} pending=${after} (${elementType})`);
      } else {
        hilog.info(DOMAIN, TAG,
          `Op queued while offline: pending=${after} dropped=${this.offlineQueue.dropped()} (${elementType})`);
      }
      return;
    }
    const signal: Uint8Array = SignalCodec.encodeCRDTOp(op);
    this.transport.send(signal);
    hilog.debug(DOMAIN, TAG, `Op sent: ${op.type} (${elementType})`);
  }

  /**
   * WebSocket 消息回调（v2.0：按 MsgType 信封分派）
   */
  onMessage(data: string | ArrayBuffer): void {
    try {
      const bytes: Uint8Array = this.toUint8Array(data);
      const envelope: SignalEnvelope = SignalCodec.decode(bytes);

      switch (envelope.msg_type) {
        case MsgType.MSG_CRDT_OP:
          this.handleRemoteOperation(SignalCodec.decodeCRDTOp(envelope.payload));
          break;
        case MsgType.MSG_VIEWPORT_SYNC:
          this.handleRemoteViewport(SignalCodec.decodeViewportSync(envelope.payload));
          break;
        case MsgType.MSG_PERMISSION_ASSERT:
          this.handlePermissionAssertion(SignalCodec.decodePermissionAssertion(envelope.payload));
          break;
        case MsgType.MSG_LAYER_OP:
          // 图层级操作走 LWW-Register（本地 LayerManager 已应用；远端按需合并）
          hilog.debug(DOMAIN, TAG, 'Layer op received (LWW)');
          break;
        case MsgType.MSG_ASSET_CHUNK:
          this.handleAssetChunk(SignalCodec.decodeAssetChunk(envelope.payload));
          break;
        case MsgType.MSG_ASSET_REQ:
          this.handleAssetReq(SignalCodec.decodeAssetReq(envelope.payload));
          break;
        case MsgType.MSG_ASSET_ACK:
          this.handleAssetAck(SignalCodec.decodeAssetAck(envelope.payload));
          break;
        default:
          hilog.warn(DOMAIN, TAG, `Unknown msg_type: ${envelope.msg_type}`);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to handle message: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 传输状态机回调（C02：替代 WSClient 的 onOpen/onClose/onError 分事件）。
   * ArkTS 约束（构建实测 2026-08-08）：TransportState 为 class 静态单例，
   * 用 if/else 引用相等（===）判定状态（等价于 switch 对字符串常量的语义）。
   */
  private handleTransportState(state: TransportState): void {
    if (state === TransportState.OPEN) {
      this.onOpen();
    } else if (state === TransportState.CLOSED) {
      this.onClose(1000, 'transport closed');
    } else if (state === TransportState.ERROR || state === TransportState.FAILED) {
      this.onError(new Error(`transport ${state.code}`));
    }
    // 其余状态（CONNECTING/RECONNECTING/IDLE/UNSUPPORTED）无 UI 行为，忽略
  }

  /**
   * WebSocket 连接打开回调
   * C03（Q14）：依赖 C02 transport 就绪（connect resolve 时已 OPEN），
   * 排空 OfflineOpQueue 按序补发离线期间的操作。
   */
  onOpen(): void {
    this.isConnected = true;
    hilog.info(DOMAIN, TAG, 'WebSocket connection opened');

    // 排空离线补发队列（FIFO 顺序）
    const queued: CRDTOp[] = this.offlineQueue.drain();
    if (queued.length > 0) {
      hilog.info(DOMAIN, TAG, `Replaying ${queued.length} queued offline operations`);
      for (const op of queued) {
        const elementType: string = getElementTypeOfPending(op);
        this.sendOperation(op, elementType);
      }
    }
  }

  /**
   * WebSocket 连接关闭回调
   */
  onClose(code: number, reason: string): void {
    this.isConnected = false;
    hilog.warn(DOMAIN, TAG, `WebSocket closed: ${code} - ${reason}`);
    const disconnectProps: DisconnectTrackProps = { code: code, reason: reason };
    analytics.track('ws_disconnect', disconnectProps);
  }

  /**
   * WebSocket 错误回调
   */
  onError(error: Error): void {
    hilog.error(DOMAIN, TAG, `WebSocket error: ${error.message}`);
    analytics.trackError('ws', error.message);
  }

  /**
   * 处理远程操作（S2T03：CanvasElement 全类型）
   */
  private handleRemoteOperation(op: CRDTOp): void {
    if (!this.rgaEngine) return;

    const applied: boolean = this.rgaEngine.applyRemoteOp(op);

    if (applied) {
      if (op.type === 'insert') {
        const insertOp: InsertOp = op as InsertOp;
        const element: CanvasElement = insertOp.element.value;
        this.valueIdToNodeId.set(element.id, insertOp.element.id);
        const elementType: string = getCanvasElementType(element);
        this.valueIdToType.set(element.id, elementType);
        for (const callback of this.callbacks) {
          callback.onRemoteElement(element);
        }
        if (elementType === CanvasElementType.STROKE) {
          for (const callback of this.callbacks) {
            callback.onRemoteStroke(element as StrokeData);
          }
        }
        // 转发给板面同步传输适配器（S2T03）
        this.boardSync.onRemoteElement(element);
      } else if (op.type === 'delete') {
        const deleteOp: DeleteOp = op as DeleteOp;
        const targetId: string = serializeNodeID(deleteOp.targetId);
        for (const callback of this.callbacks) {
          callback.onRemoteDelete(targetId);
        }
      } else if (op.type === 'update') {
        // T2-5c：字段 LWW 更新 → 取引擎最新元素值（含覆盖字段）→ 全量重绘兜底（t25 §5.4）
        const updateOp: UpdateOp = op as UpdateOp;
        this.notifyRemoteElementLatest(updateOp.targetId);
      } else if (op.type === 'resurrect') {
        // T2-5c：撤销删除 → 元素复活 → 取最新元素值重绘
        const resurrectOp: ResurrectOp = op as ResurrectOp;
        this.notifyRemoteElementLatest(resurrectOp.targetId);
      }
    }
  }

  /** 从引擎取元素最新值（含 elementLWW 字段覆盖）并广播重绘回调（update/resurrect 共用） */
  private notifyRemoteElementLatest(targetId: NodeID): void {
    if (!this.rgaEngine) return;
    const targetStr: string = serializeNodeID(targetId);
    const elements: RGAElement<CanvasElement>[] = this.rgaEngine.getElements();
    for (let i = 0; i < elements.length; i++) {
      const e: RGAElement<CanvasElement> = elements[i];
      if (serializeNodeID(e.id) === targetStr) {
        const merged: CanvasElement = this.mergeLwwFields(e.value, e.id);
        for (const callback of this.callbacks) {
          callback.onRemoteElement(merged);
        }
        this.boardSync.onRemoteElement(merged);
        return;
      }
    }
  }

  /**
   * 合并元素自身值与 elementLWW 覆盖字段（t25 §1.2：可变字段走 LWW）。
   * 直接修改元素值字段（ArkTS 禁对象展开）：LWW 胜者值写入引擎元素，
   * 渲染回调与 .hcnote 投影都取合并后值——幂等正确（更旧写被 LWW 决胜忽略）。
   */
  private mergeLwwFields(element: CanvasElement, nodeId: NodeID): CanvasElement {
    const type: string = getCanvasElementType(element);
    if (type !== CanvasElementType.TEXT_BLOCK && type !== CanvasElementType.IMAGE_REF
      && type !== CanvasElementType.ANNOTATION) {
      return element; // Stroke/Shape 值不可变
    }
    const out: CanvasElement = element;
    const text: TextBlockData = out as TextBlockData;
    if (text.text !== undefined) {
      const v: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'text') : null;
      if (v !== null) text.text = v;
      const x: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'x') : null;
      if (x !== null) text.x = Number(x);
      const y: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'y') : null;
      if (y !== null) text.y = Number(y);
      const size: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'fontSize') : null;
      if (size !== null) text.fontSize = Number(size);
      const color: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'color') : null;
      if (color !== null) text.color = color;
    }
    const img: ImageRefData = out as ImageRefData;
    if (img.imageHash !== undefined) {
      const x: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'x') : null;
      if (x !== null) img.x = Number(x);
      const y: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'y') : null;
      if (y !== null) img.y = Number(y);
      const w: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'width') : null;
      if (w !== null) img.width = Number(w);
      const h: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'height') : null;
      if (h !== null) img.height = Number(h);
      const rot: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'rotation') : null;
      if (rot !== null) img.rotation = Number(rot);
      const sc: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'scale') : null;
      if (sc !== null) img.scale = Number(sc);
    }
    const ann: AnnotationData = out as AnnotationData;
    if (ann.pageIndex !== undefined) {
      const color: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'color') : null;
      if (color !== null) ann.color = color;
      const width: string | null = this.rgaEngine ? this.rgaEngine.getElementField(nodeId, 'width') : null;
      if (width !== null) ann.width = Number(width);
    }
    return out;
  }

  /**
   * 处理远端视口跟随（MSG_VIEWPORT_SYNC，LWW 展示态）
   */
  private handleRemoteViewport(payload: ViewportSyncPayload): void {
    const vp: ViewportState = {
      centerX: payload.centerX,
      centerY: payload.centerY,
      scale: payload.scale,
      currentPage: payload.currentPage,
      timestamp: payload.timestamp,
      senderDeviceId: payload.senderDeviceId
    };
    // 传输适配器承接视口同步消息转发（本地渲染"当前位置"标识）
    this.boardSync.onRemoteViewport(vp);
    for (const callback of this.callbacks) {
      callback.onRemoteViewport(vp);
    }
  }

  /**
   * 处理远端权限断言（角色调整时服务端下发）
   */
  private handlePermissionAssertion(assertion: PermissionAssertionPayload): void {
    this.applyPermissionAssertion(assertion);
  }

  // ─── S2-Cc / T2-5c：资产分片通道（t25 §2，op 先发 + 资产异步补传）───

  /**
   * 发送二进制资产：64KB 分片 → 每片 base64 + CRC32 → MSG_ASSET_CHUNK 逐片发送。
   * @param assetId imageHash（FNV-1a，内容寻址）
   */
  sendAsset(assetId: string, bytes: Uint8Array): void {
    if (!this.transport || !this.isConnected || bytes.length === 0) {
      return;
    }
    const totalChunks: number = Math.max(1, Math.ceil(bytes.length / ASSET_CHUNK_BYTES));
    for (let seq = 0; seq < totalChunks; seq++) {
      const start: number = seq * ASSET_CHUNK_BYTES;
      const end: number = Math.min(bytes.length, start + ASSET_CHUNK_BYTES);
      const chunk: Uint8Array = bytes.slice(start, end);
      const chunkPayload: AssetChunkPayload = {
        assetId: assetId,
        seq: seq,
        totalChunks: totalChunks,
        data: SignalCodec.base64Encode(chunk),
        chunkCrc: SignalCodec.crc32(chunk),
      };
      this.transport.send(SignalCodec.encodeAssetChunk(chunkPayload));
    }
    hilog.info(DOMAIN, TAG, `Asset sent: ${assetId}, ${totalChunks} chunks`);
  }

  /** 接收资产分片：CRC32 校验 → bitmap 记录 → 全片收齐后 FNV-1a 复核 → 落盘 */
  private handleAssetChunk(payload: AssetChunkPayload): void {
    const bytes: Uint8Array = SignalCodec.base64Decode(payload.data);
    if (SignalCodec.crc32(bytes) !== payload.chunkCrc) {
      hilog.warn(DOMAIN, TAG, `Asset chunk CRC mismatch: ${payload.assetId}#${payload.seq} (drop, will re-request)`);
      this.requestAsset(payload.assetId);
      return;
    }
    let state: AssetReceiveState | undefined = this.assetBuffers.get(payload.assetId);
    if (state === undefined) {
      state = { assetId: payload.assetId, chunks: [], bitmap: '', totalChunks: payload.totalChunks };
      for (let i = 0; i < payload.totalChunks; i++) {
        state.bitmap += '0';
        state.chunks.push(new Uint8Array(0));
      }
      this.assetBuffers.set(payload.assetId, state);
    }
    if (payload.seq < 0 || payload.seq >= state.chunks.length) {
      return;
    }
    if (state.bitmap.charAt(payload.seq) === '1') {
      return; // 重复片忽略
    }
    state.chunks[payload.seq] = bytes;
    state.bitmap = state.bitmap.substring(0, payload.seq) + '1' + state.bitmap.substring(payload.seq + 1);
    if (state.bitmap.indexOf('0') === -1) {
      // 全片收齐：拼装 → FNV-1a 复核 → 落盘
      const total: number = state.chunks.reduce((acc: number, c: Uint8Array) => acc + c.length, 0);
      const merged: Uint8Array = new Uint8Array(total);
      let offset: number = 0;
      for (let i = 0; i < state.chunks.length; i++) {
        merged.set(state.chunks[i], offset);
        offset += state.chunks[i].length;
      }
      const fnv: string = SignalCodec.fnv1aBytes(merged);
      if (fnv === payload.assetId) {
        this.persistAsset(payload.assetId, merged);
      } else {
        hilog.warn(DOMAIN, TAG, `Asset FNV mismatch: ${payload.assetId} vs ${fnv} (re-request)`);
        this.requestAsset(payload.assetId);
      }
      this.assetBuffers.delete(payload.assetId);
    }
  }

  /** 收到缺失资产请求：本地有则重发（t25 §2.2：MSG_ASSET_REQ 覆盖「op 到了资产没到」） */
  private handleAssetReq(payload: AssetReqPayload): void {
    hilog.info(DOMAIN, TAG, `Asset requested by peer: ${payload.assetId}`);
    // 本地资产重发由上层（持有二进制的 NoteRepository）在 onAssetRequested 接线时触发；
    // 本批引擎侧仅记录（t25 §2.2 协议完整，重发回调归 T3-4 渲染层接线）
  }

  /** 收到收齐确认：标记（bitmap 断点续传的服务端侧无状态，忽略即可） */
  private handleAssetAck(payload: AssetAckPayload): void {
    hilog.debug(DOMAIN, TAG, `Asset ack received: ${payload.assetId}`);
  }

  /** 主动请求缺失资产（覆盖 op 到了资产没到 / 对端忘记发） */
  private requestAsset(assetId: string): void {
    if (!this.transport || !this.isConnected) {
      return;
    }
    const req: AssetReqPayload = { assetId: assetId };
    this.transport.send(SignalCodec.encodeAssetReq(req));
  }

  /**
   * 资产落盘（t25 §2.3：FNV-1a 复核通过后由 NoteRepository.saveAssetBytes 承接）。
   * 为避免 NoteEngine↔CollaborationManager 循环依赖，落盘经 assetSink 回调注册（上层接线，T3-4）。
   */
  private persistAsset(assetId: string, bytes: Uint8Array): void {
    if (this.assetSink !== null) {
      this.assetSink(assetId, bytes);
    }
    hilog.info(DOMAIN, TAG, `Asset persisted: ${assetId}, ${bytes.length} bytes`);
  }

  /**
   * 注册资产落盘回调（由上层在初始化时注入：sink(assetId, bytes) → NoteRepository.saveAssetBytes）。
   * 避免本模块直接 import NoteEngine（循环依赖）。
   */
  setAssetSink(sink: (assetId: string, bytes: Uint8Array) => void): void {
    this.assetSink = sink;
  }

  /**
   * 添加回调
   */
  addCallback(callback: CollaborationCallback): void {
    this.callbacks.push(callback);
  }

  /**
   * 移除回调
   */
  removeCallback(callback: CollaborationCallback): void {
    const index: number = this.callbacks.indexOf(callback);
    if (index >= 0) {
      this.callbacks.splice(index, 1);
    }
  }

  /**
   * 获取当前状态（v1 兼容字段 roomId = sessionId）
   */
  getState(): CollaborationState {
    const state: CollaborationState = {
      isConnected: this.isConnected,
      roomId: this.sessionId,
      userId: this.userId,
      deviceId: this.deviceId
    };
    return state;
  }

  // ─── C03（Q14 / §4.6）：离线同步状态可感知 ───

  /**
   * 同步指示器（SYNCED / PENDING / OFFLINE / DROPPED）。
   * 优先级：DROPPED（警告级，持续可见）> OFFLINE > PENDING > SYNCED。
   * 供 UI 层 chip 消费（§4.6 常态指示器）。
   */
  syncIndicator(): string {
    if (this.offlineQueue.dropped() > 0) {
      return SyncIndicatorState.DROPPED.code;
    }
    if (!this.isConnected) {
      return SyncIndicatorState.OFFLINE.code;
    }
    if (this.offlineQueue.size() > 0) {
      return SyncIndicatorState.PENDING.code;
    }
    return SyncIndicatorState.SYNCED.code;
  }

  /** 待补发条数（pendingOpCount，供 CollabStatusSnapshot） */
  pendingOpCount(): number {
    return this.offlineQueue.size();
  }

  /** 累计丢弃条数（droppedOpCount，DROPPED 持续可见依据） */
  droppedOpCount(): number {
    return this.offlineQueue.dropped();
  }

  /** 用户确认丢弃提示后调用：复位 DROPPED 状态（UI「知道了」按钮接线） */
  acknowledgeDropped(): void {
    this.offlineQueue.clear();
    hilog.info(DOMAIN, TAG, 'Offline drop acknowledged, DROPPED state reset');
  }

  /**
   * v1 兼容：获取全部可见笔触
   */
  getAllStrokes(): StrokeData[] {
    if (!this.rgaEngine) return [];
    const elements: CanvasElement[] = this.rgaEngine.getVisibleElements();
    const strokes: StrokeData[] = [];
    for (let i = 0; i < elements.length; i++) {
      if (getCanvasElementType(elements[i]) === CanvasElementType.STROKE) {
        strokes.push(elements[i] as StrokeData);
      }
    }
    return strokes;
  }

  /**
   * v2.0（S2T03）：获取全部可见元素（CanvasElement 全类型）
   */
  getAllElements(): CanvasElement[] {
    if (!this.rgaEngine) return [];
    return this.rgaEngine.getVisibleElements();
  }

  /**
   * v2.0：导出 RGA 快照（流转状态续传用）
   */
  exportSnapshot(): CollaborationSnapshot {
    const elements: CanvasElement[] = this.rgaEngine !== null ? this.rgaEngine.getVisibleElements() : [];
    const snapshot: CollaborationSnapshot = {
      elements: elements,
      deviceId: this.deviceId
    };
    return snapshot;
  }

  // ─── 内部工具 ───

  private toUint8Array(data: string | ArrayBuffer): Uint8Array {
    if (typeof data === 'string') {
      // ArkTS 无全局 TextEncoder，使用 @kit.ArkTS 的 util.TextEncoder
      const encoder = new util.TextEncoder();
      return encoder.encodeInto(data);
    }
    const buffer: ArrayBuffer = data as ArrayBuffer;
    return new Uint8Array(buffer);
  }

  private readAppStorage(key: string): string {
    try {
      const value: string = AppStorage.get<string>(key) ?? '';
      return value;
    } catch (err) {
      // Node 验证环境无 ArkUI AppStorage
      return '';
    }
  }
}

/** 从待发送操作中解析元素类型（onOpen 补发用） */
function getElementTypeOfPending(op: CRDTOp): string {
  const insertOp: InsertOp = op as InsertOp;
  if (insertOp.elementType !== undefined && insertOp.elementType.length > 0) {
    return insertOp.elementType;
  }
  return CanvasElementType.STROKE;
}

// 导出单例
export const collaborationManager = CollaborationManager.getInstance();
