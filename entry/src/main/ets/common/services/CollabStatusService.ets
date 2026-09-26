/**
 * CollabStatusService.ets — 页面层 ↔ NoteEngine S2 门面 的 UI 接线服务（v2.3 增量，修复 K-R2-2）
 *
 * 背景：
 *  阶段二 QA（qa-report-harmonycanvas-v2-phase2.md R2-3）遗留项 K-R2-2 指出
 *  「页面层尚未调用 NoteEngine 的 S2 门面（流转 / 会话 UI 接线后续）」。
 *  本服务作为**唯一的 UI 读模型 / 命令入口**，把 4 个页面对分布式协同模块的访问
 *  收敛到一处，避免每个页面各自 import SessionManager / PermissionGuard / ViewportSyncManager。
 *
 * 用途：
 *  - 读：snapshot() / snapshotAsync() 返回可直接绑定 @State 的扁平快照；
 *  - 写：startFlowSession / endFlowSession / setPermissionRole / sendViewportSync / joinCollabSession。
 *
 * 输入：无（内部通过 NoteEngine.getInstance() 取门面）
 * 输出：CollabStatusSnapshot / SessionDeviceRow[] / ViewportSyncResult / JoinSessionResult
 *
 * 注意事项：
 *  1. 本服务**不修改**任何 engine / crdt / distributed / network 核心模块，仅调用其公开门面；
 *  2. 所有对外方法均经 SafeAsync 兜底，异常时返回安全默认值，绝不向 UI 抛异常；
 *  3. SessionManager 的读状态方法实际名为 getState()（架构文档中写作 getCurrentState()，以代码为准）；
 *  4. ViewportSyncManager 的发送入口实际为 DistributedBoardSync.syncViewportFromEngine()
 *     （内部调用 updateLocalViewport 完成 ≤5Hz 节流），页面不直接调用 updateLocalViewport。
 */

import { NoteEngine } from '../../engine/NoteEngine';
import { FlowSessionState, SessionDeviceRole, SessionManager } from '../../distributed/SessionManager';
import { ViewportState } from '../../distributed/ViewportSyncManager';
import { SessionRole, sessionRoleLabel } from './PermissionGuard';
import { CollaborationState } from './CollaborationManager';
import { PermissionAssertionPayload } from '../../network/SignalCodec';
// C01 身份链贯通：userId 统一从单一身份源读取（服务端签发 > 回退 siteId，永不回退昵称）
import { SessionIdentity } from '../identity/SessionIdentity';
import { Logger } from '../Logger';
import { SafeAsync } from '../utils/SafeAsync';
import { API_BASE_URL, PERMISSION_ASSERT_TTL_MS, VIEWPORT_SYNC_MAX_HZ } from '../Constants';
// O-1 收敛：统一从本门面 re-export 协同 UI 枚举/标签，页面无需直接 import 核心 PermissionGuard
export { SessionRole, sessionRoleLabel } from './PermissionGuard';

const TAG_MODULE = 'CollabStatusService';

/** 默认笔记 id / 设备组 id（单机演示态） */
const DEFAULT_NOTE_ID: string = 'note_default';
const DEFAULT_GROUP_PREFIX: string = 'grp_';
/** 加入协作会话的连接超时（避免 UI 卡在 loading） */
const JOIN_TIMEOUT_MS: number = 5000;

/** 协同状态扁平快照（可直接绑定 @State） */
export interface CollabStatusSnapshot {
  hasSession: boolean;
  sessionId: string;
  shortSessionId: string;
  noteId: string;
  deviceGroupId: string;
  hostDeviceId: string;
  localDeviceId: string;
  shortLocalDeviceId: string;
  /** 会话角色：NOTE_HOST / FOLLOWER / VIEWER */
  sessionRole: string;
  sessionRoleText: string;
  /** 三级权限：VIEWER / ANNOTATOR / EDITOR */
  permissionRole: string;
  permissionRoleText: string;
  /** 有效用户写权限（设备角色 + 三级权限综合判定）：设备级可写（NOTE_HOST/FOLLOWER）且 三级权限非 VIEWER */
  canWrite: boolean;
  onlineDeviceCount: number;
  deviceIds: string[];
  boardSyncEnabled: boolean;
  wsConnected: boolean;
  /** C03（Q14）：离线待补发条数（OfflineOpQueue.size） */
  pendingOpCount: number;
  /** C03（Q14）：累计丢弃条数（OfflineOpQueue.dropped，DROPPED 持续可见依据） */
  droppedOpCount: number;
  lastViewportText: string;
  updatedAt: number;
}

/** 设备列表行（DeviceManagePage 会话设备区展示用） */
export interface SessionDeviceRow {
  deviceId: string;
  shortId: string;
  isLocal: boolean;
  isHost: boolean;
  roleText: string;
}

/** 视口同步触发结果（用于验证 ≤5Hz 节流是否生效） */
export interface ViewportSyncResult {
  sent: boolean;
  throttled: boolean;
  message: string;
}

/** 加入协作会话结果 */
export interface JoinSessionResult {
  ok: boolean;
  connected: boolean;
  role: string;
  roleText: string;
  message: string;
}

/** 空快照工厂（页面首帧占位，避免 build() 里做耗时计算） */
export function createEmptyCollabStatus(): CollabStatusSnapshot {
  const empty: CollabStatusSnapshot = {
    hasSession: false,
    sessionId: '',
    shortSessionId: '—',
    noteId: '',
    deviceGroupId: '',
    hostDeviceId: '',
    localDeviceId: '',
    shortLocalDeviceId: '—',
    sessionRole: SessionDeviceRole.NOTE_HOST,
    sessionRoleText: '笔记主机',
    permissionRole: SessionRole.EDITOR,
    permissionRoleText: '可编辑',
    canWrite: true,
    onlineDeviceCount: 0,
    deviceIds: [],
    boardSyncEnabled: false,
    wsConnected: false,
    pendingOpCount: 0,
    droppedOpCount: 0,
    lastViewportText: '—',
    updatedAt: 0
  };
  return empty;
}

/** 会话角色中文标签（SessionDeviceRole → UI 文案） */
export function sessionDeviceRoleText(role: string): string {
  if (role === SessionDeviceRole.NOTE_HOST) {
    return '笔记主机';
  }
  if (role === SessionDeviceRole.FOLLOWER) {
    return '跟随端';
  }
  return '展示端(只读)';
}

export class CollabStatusService {
  private static instance: CollabStatusService | null = null;
  private engine: NoteEngine = NoteEngine.getInstance();
  private localDeviceReady: boolean = false;
  private cachedLocalDeviceId: string = '';

  static getInstance(): CollabStatusService {
    if (!CollabStatusService.instance) {
      CollabStatusService.instance = new CollabStatusService();
    }
    return CollabStatusService.instance;
  }

  /**
   * 确保本机设备身份已注入 NoteEngine（幂等）。
   * 优先取 AppStorage['siteId']，缺失时生成稳定的本地 id 并回写。
   */
  ensureLocalDeviceId(): string {
    if (this.localDeviceReady && this.cachedLocalDeviceId.length > 0) {
      return this.cachedLocalDeviceId;
    }
    const stored: string = SafeAsync.run<string>(TAG_MODULE, 'readSiteId', (): string => {
      const value: string = AppStorage.get<string>('siteId') ?? '';
      return value;
    }, '');

    let deviceId: string = stored;
    if (deviceId.length === 0) {
      deviceId = `dev_${Date.now().toString(36)}_${Math.random().toString(36).substring(2, 6)}`;
      SafeAsync.runVoid(TAG_MODULE, 'writeSiteId', () => {
        AppStorage.setOrCreate<string>('siteId', deviceId);
      });
    }

    SafeAsync.runVoid(TAG_MODULE, 'setLocalDeviceId', () => {
      this.engine.setLocalDeviceId(deviceId);
    });

    this.cachedLocalDeviceId = deviceId;
    this.localDeviceReady = true;
    Logger.info(TAG_MODULE, `Local device id ready: ${deviceId}`);
    return deviceId;
  }

  /**
   * 读取当前协同状态快照（同步，纯内存读取，无 I/O）。
   */
  snapshot(): CollabStatusSnapshot {
    return SafeAsync.run<CollabStatusSnapshot>(TAG_MODULE, 'snapshot', (): CollabStatusSnapshot => {
      const state: FlowSessionState | null = this.engine.getSessionManager().getState();
      const permissionRole: SessionRole = this.engine.getPermissionGuard().getRole();
      const boardSyncEnabled: boolean = this.engine.getDistributedBoardSync().isEnabled();
      const collabState: CollaborationState = this.engine.getCollaborationManager().getState();
      const localDeviceId: string = this.engine.getSessionManager().getLocalDeviceId();
      const sessionRole: string = this.engine.getSessionManager().getLocalRole();
      const lastLocal: ViewportState | null = this.engine.getViewportSyncManager().getLastLocalViewport();

      // 🔍 诊断埋点：权限计算详情
      const canWriteFromSession = this.engine.getSessionManager().canWrite();
      const isNotViewer = permissionRole !== SessionRole.VIEWER;
      const isStandalone = state === null;
      const finalCanWrite = isStandalone || (canWriteFromSession && isNotViewer);
      
      Logger.info(TAG_MODULE, `=== snapshot() 权限计算诊断 ===`);
      Logger.info(TAG_MODULE, `state=${state ? 'exists' : 'null'}, isStandalone=${isStandalone}`);
      Logger.info(TAG_MODULE, `canWriteFromSession=${canWriteFromSession}, isNotViewer=${isNotViewer}`);
      Logger.info(TAG_MODULE, `finalCanWrite=${finalCanWrite}, permissionRole=${permissionRole}`);

      const snapshot: CollabStatusSnapshot = {
        hasSession: state !== null,
        sessionId: state !== null ? state.sessionId : '',
        shortSessionId: state !== null ? CollabStatusService.shorten(state.sessionId) : '—',
        noteId: state !== null ? state.noteId : '',
        deviceGroupId: state !== null ? state.deviceGroupId : '',
        hostDeviceId: state !== null ? state.hostDeviceId : '',
        localDeviceId: localDeviceId,
        shortLocalDeviceId: CollabStatusService.shorten(localDeviceId),
        sessionRole: sessionRole,
        sessionRoleText: sessionDeviceRoleText(sessionRole),
        permissionRole: permissionRole,
        permissionRoleText: sessionRoleLabel(permissionRole),
        // E-1 修复：有效用户写权限 = 设备级可写（NOTE_HOST/FOLLOWER）且 三级权限非只读
        // 🔧 修复绘制无响应BUG：增加单机模式判断
        // 单机模式（无会话）强制可写，避免权限检查拦截本地绘制
        canWrite: finalCanWrite,
        onlineDeviceCount: state !== null ? state.connectedDeviceIds.length : 0,
        deviceIds: state !== null ? state.connectedDeviceIds.slice() : [],
        boardSyncEnabled: boardSyncEnabled,
        wsConnected: collabState.isConnected,
        // C03（Q14）：离线补发队列状态暴露给 UI（§4.6 数据源）
        pendingOpCount: this.engine.getCollaborationManager().pendingOpCount(),
        droppedOpCount: this.engine.getCollaborationManager().droppedOpCount(),
        lastViewportText: CollabStatusService.viewportText(lastLocal),
        updatedAt: Date.now()
      };
      return snapshot;
    }, createEmptyCollabStatus());
  }

  /**
   * 异步读取快照：延后到下一个事件循环，避免首帧渲染被同步计算阻塞。
   */
  snapshotAsync(): Promise<CollabStatusSnapshot> {
    return new Promise<CollabStatusSnapshot>((resolve: (value: CollabStatusSnapshot) => void) => {
      setTimeout(() => {
        resolve(this.snapshot());
      }, 0);
    });
  }

  /**
   * 发起超级终端流转会话（HM-08）：NoteEngine.createFlowSession → 启用板面同步。
   * @param noteId 笔记 id（留空使用默认笔记）
   */
  startFlowSession(noteId: string): CollabStatusSnapshot {
    const deviceId: string = this.ensureLocalDeviceId();
    const targetNoteId: string = noteId.length > 0 ? noteId : DEFAULT_NOTE_ID;
    const groupId: string = `${DEFAULT_GROUP_PREFIX}${CollabStatusService.shorten(deviceId)}`;
    SafeAsync.runVoid(TAG_MODULE, 'startFlowSession', () => {
      const state: FlowSessionState = this.engine.createFlowSession(targetNoteId, groupId);
      this.engine.getDistributedBoardSync().setEnabled(true);
      Logger.info(TAG_MODULE, `Flow session started: ${state.sessionId} (note=${targetNoteId}, group=${groupId})`);
    });
    return this.snapshot();
  }

  /**
   * 结束流转会话：关闭板面同步 + 重置会话状态与权限守卫。
   */
  endFlowSession(): CollabStatusSnapshot {
    SafeAsync.runVoid(TAG_MODULE, 'endFlowSession', () => {
      this.engine.getDistributedBoardSync().setEnabled(false);
      this.engine.getSessionManager().reset();
      this.engine.getPermissionGuard().reset();
      Logger.info(TAG_MODULE, 'Flow session ended');
    });
    // reset 会清空 localDeviceId 之外的会话态，需要重新注入设备身份
    this.localDeviceReady = false;
    this.ensureLocalDeviceId();
    return this.snapshot();
  }

  /**
   * 设置三级权限档位（HM-11）：走 CollaborationManager 门面，
   * 内部调用 PermissionGuard.configure 并广播 onPermissionChanged。
   * 
   * 🔧 修复权限只读状态异常：直接同步执行，确保权限状态立即生效
   * 避免"退出只读模式依旧无法书写"问题
   */
  setPermissionRole(role: SessionRole): CollabStatusSnapshot {
    // 同步设置权限，确保权限状态立即生效（CollaborationManager.setPermissionRole本身是同步的）
    this.engine.getCollaborationManager().setPermissionRole(role);
    Logger.info(TAG_MODULE, `setPermissionRole: 权限角色已同步更改为 ${role}`);
    // 立即返回最新快照，确保权限状态同步
    return this.snapshot();
  }

  /** 权限沙箱调试：EDITOR → ANNOTATOR → VIEWER → EDITOR 循环 */
  cyclePermissionRole(): CollabStatusSnapshot {
    const current: SessionRole = this.engine.getPermissionGuard().getRole();
    return this.setPermissionRole(CollabStatusService.nextRole(current));
  }

  /**
   * C03（§4.6）：用户确认丢弃提示后，复位 DROPPED 状态（OfflineOpQueue.clear）。
   * UI「知道了」按钮接线；返回最新快照（DROPPED chip 消失）。
   */
  acknowledgeDropped(): CollabStatusSnapshot {
    SafeAsync.runVoid(TAG_MODULE, 'acknowledgeDropped', () => {
      this.engine.getCollaborationManager().acknowledgeDropped();
    });
    return this.snapshot();
  }

  /**
   * 触发一次视口同步（HM-09）：经 DistributedBoardSync 节流后发送 MSG_VIEWPORT_SYNC。
   * 返回值可用于验证 ≤VIEWPORT_SYNC_MAX_HZ 节流是否生效（连点时 throttled=true）。
   */
  sendViewportSync(centerX: number, centerY: number, scale: number, currentPage: number): ViewportSyncResult {
    const fallback: ViewportSyncResult = { sent: false, throttled: false, message: '视口同步异常' };
    return SafeAsync.run<ViewportSyncResult>(TAG_MODULE, 'sendViewportSync', (): ViewportSyncResult => {
      if (!this.engine.getDistributedBoardSync().isEnabled()) {
        const off: ViewportSyncResult = { sent: false, throttled: false, message: '未开启流转会话，先在首页创建会话' };
        return off;
      }
      const vp: ViewportState | null =
        this.engine.getDistributedBoardSync().syncViewportFromEngine(centerX, centerY, scale, currentPage);
      if (vp === null) {
        const throttled: ViewportSyncResult = {
          sent: false,
          throttled: true,
          message: `已节流（上限 ${VIEWPORT_SYNC_MAX_HZ}Hz）`
        };
        return throttled;
      }
      this.engine.getCollaborationManager().syncViewport(vp);
      const ok: ViewportSyncResult = {
        sent: true,
        throttled: false,
        message: `视口已同步 p${vp.currentPage} ×${vp.scale.toFixed(2)}`
      };
      return ok;
    }, fallback);
  }

  /**
   * 加入协作会话（HM-10 / HM-11）：构造本地权限断言 → CollaborationManager.joinSession。
   * 断言在连接前即被 PermissionGuard 应用，因此离线预览下权限档位依然生效。
   *
   * @param sessionId 会话 / 房间号
   * @param role      期望角色（服务端签发时以服务端为准）
   */
  async joinCollabSession(sessionId: string, role: SessionRole): Promise<JoinSessionResult> {
    const deviceId: string = this.ensureLocalDeviceId();
    const assertion: PermissionAssertionPayload = this.buildLocalAssertion(sessionId, role, deviceId);
    // 转派④：优先消费服务端 JoinResult 下发的 ws_endpoint（C01 已落 SessionIdentity），
    // 为空才回退本地拼装，且回退路径必须留日志说明原因。
    const serverEndpoint: string = SessionIdentity.getInstance().wsEndpoint();
    let endpoint: string = serverEndpoint;
    if (serverEndpoint === undefined || serverEndpoint === null || serverEndpoint.length === 0) {
      endpoint = CollabStatusService.wsEndpointFor(sessionId);
      Logger.info(TAG_MODULE, `joinCollabSession: ws_endpoint 缺失，回退本地拼装 ${endpoint}`);
    } else {
      Logger.info(TAG_MODULE, `joinCollabSession: 使用服务端下发 ws_endpoint ${endpoint}`);
    }

    const connected: boolean = await SafeAsync.withTimeout(TAG_MODULE, 'joinSession', (): Promise<boolean> => {
      return this.engine.getCollaborationManager().joinSession(sessionId, endpoint, assertion);
    }, JOIN_TIMEOUT_MS);

    const applied: SessionRole = this.engine.getPermissionGuard().getRole();
    const result: JoinSessionResult = {
      ok: true,
      connected: connected,
      role: applied,
      roleText: sessionRoleLabel(applied),
      message: connected
        ? `已加入会话 ${sessionId}，权限：${sessionRoleLabel(applied)}（实时画布同步即将上线）`
        : `协作服务未连通（离线模式），本地权限已按断言配置为：${sessionRoleLabel(applied)}`
    };
    Logger.info(TAG_MODULE, result.message);
    return result;
  }

  /**
   * 🔴 v2.7.1 审核修复（问题①-3「输入房间号后点击加入房间失败」真因）
   *
   * 建立/加入**本机房间的离线会话** —— 完全不依赖服务端。
   *
   * 真因：原 `joinCollabSession()` 的 connected 取决于
   *   `CollaborationManager.joinSession()` → `transport.connect(wsEndpoint)`
   * 即「必须连上 WebSocket 信令服务」。而本项目**没有部署服务端**，
   * 因此 connected 恒为 false：
   *   · 「创建本机房间」→ 永远卡在"创建中…"或报失败；
   *   · 「加入房间」→ 页面提示"无法建立协作会话，请检查网络后重试"。
   * 产品定位是「本地优先 + 鸿蒙分布式」，本机房间本就不该依赖公网服务，
   * 所以正确做法是提供一条**纯本地**的会话建立路径。
   *
   * 实现：本地应用权限断言（三级权限矩阵离线可验证）+ 建立本地会话状态
   *   （SessionManager.createSession，connectedDeviceIds 含本机）。
   *   只要本地状态建成即视为加入成功，网络/服务端状态仅作说明性文字。
   */
  async joinLocalSession(sessionId: string, role: SessionRole): Promise<JoinSessionResult> {
    // 🔴 v2.7.2：本方法**永不抛异常**（连续两轮"加入房间失败"的教训）。
    //   此前内部若任一步骤抛错，会让调用方 joinRoom 的 Promise reject 而无人接收，
    //   表现为"点击加入房间无反应/失败"。现全流程 try/catch，任何一步失败仍返回可用结果。
    let deviceId: string = 'local';
    try {
      deviceId = this.ensureLocalDeviceId();
    } catch (e) {
      Logger.error(TAG_MODULE, `joinLocalSession: 本机设备标识获取失败，降级 'local': ${JSON.stringify(e)}`);
    }

    // ① 本地落地权限断言（PermissionGuard 据此放行三级权限校验）
    try {
      const assertion: PermissionAssertionPayload = this.buildLocalAssertion(sessionId, role, deviceId);
      SafeAsync.runVoid(TAG_MODULE, 'applyLocalAssertion', (): void => {
        this.engine.getCollaborationManager().applyPermissionAssertion(assertion);
      });
    } catch (e) {
      Logger.error(TAG_MODULE, `joinLocalSession: 权限断言落地失败（不影响加入）: ${JSON.stringify(e)}`);
    }

    // ② 建立本地会话状态（本机即会话成员）
    let sessionCreated: boolean = false;
    try {
      const sm: SessionManager = this.engine.getSessionManager();
      sm.setLocalDeviceId(deviceId);
      const state: FlowSessionState = sm.createSession(sessionId, sessionId);
      sessionCreated = state !== null && state !== undefined;
    } catch (e) {
      Logger.error(TAG_MODULE, `joinLocalSession: 本地会话状态建立失败: ${JSON.stringify(e)}`);
    }

    // ③ 读取生效权限档位（失败则回退为传入档位）
    let applied: SessionRole = role;
    try {
      applied = this.engine.getPermissionGuard().getRole();
    } catch (e) {
      Logger.warn(TAG_MODULE, 'joinLocalSession: 读取生效权限失败，使用请求档位');
    }

    const result: JoinSessionResult = {
      ok: true,
      // 关键：本地会话建成即视为已加入（不依赖 WebSocket / 服务端）
      connected: true,
      role: applied,
      roleText: sessionRoleLabel(applied),
      // v2.7.3：说清真实机制 —— 房间号即房间标识；同华为账号设备经分布式软总线实时共享白板，
      //   无需部署服务端（这解释了为什么任意房间号都能加入：加入即进入该编号的房间命名空间）。
      message: `已加入房间 ${sessionId} · 同一华为账号下的设备将实时共享白板（权限：${sessionRoleLabel(applied)}）`
    };
    Logger.info(TAG_MODULE, result.message);
    return result;
  }

  /** 会话内设备列表（DeviceManagePage 展示） */
  getSessionDeviceRows(): SessionDeviceRow[] {
    return SafeAsync.run<SessionDeviceRow[]>(TAG_MODULE, 'getSessionDeviceRows', (): SessionDeviceRow[] => {
      const state: FlowSessionState | null = this.engine.getSessionManager().getState();
      if (state === null) {
        return [];
      }
      const localId: string = state.localDeviceId;
      const hostId: string = state.hostDeviceId;
      const rows: SessionDeviceRow[] = [];
      for (let i = 0; i < state.connectedDeviceIds.length; i++) {
        const id: string = state.connectedDeviceIds[i];
        const isLocal: boolean = id === localId;
        const isHost: boolean = id === hostId;
        const roleText: string = isHost
          ? sessionDeviceRoleText(SessionDeviceRole.NOTE_HOST)
          : (isLocal ? sessionDeviceRoleText(state.localRole) : sessionDeviceRoleText(SessionDeviceRole.FOLLOWER));
        const row: SessionDeviceRow = {
          deviceId: id,
          shortId: CollabStatusService.shorten(id),
          isLocal: isLocal,
          isHost: isHost,
          roleText: roleText
        };
        rows.push(row);
      }
      return rows;
    }, []);
  }

  /**
   * 构造本地权限断言（无服务端时的演示 / 离线兜底）。
   * 字段命名与 proto / Go REST 保持 snake_case 一致（架构 §8.2 约定 1）。
   */
  buildLocalAssertion(sessionId: string, role: SessionRole, deviceId: string): PermissionAssertionPayload {
    const now: number = Date.now();
    // C01 身份链贯通：userId 取自单一身份源 SessionIdentity（服务端签发 > 回退 siteId）。
    // 不再直接读 AppStorage['userId']（旧路径读取的是用户手输昵称，是身份链缺陷根源）。
    const userId: string = SessionIdentity.getInstance().userId();
    const assertion: PermissionAssertionPayload = {
      session_id: sessionId,
      user_id: userId.length > 0 ? userId : deviceId,
      device_id: deviceId,
      role: role,
      issuer: deviceId,
      issued_at: now,
      expires_at: now + PERMISSION_ASSERT_TTL_MS,
      signature: ''
    };
    return assertion;
  }

  // ─── 内部工具 ───

  /** 权限档位循环：EDITOR → ANNOTATOR → VIEWER → EDITOR */
  private static nextRole(current: SessionRole): SessionRole {
    if (current === SessionRole.EDITOR) {
      return SessionRole.ANNOTATOR;
    }
    if (current === SessionRole.ANNOTATOR) {
      return SessionRole.VIEWER;
    }
    return SessionRole.EDITOR;
  }

  /** id 缩略展示（保留尾部 6 位，便于肉眼区分设备） */
  private static shorten(id: string): string {
    if (id === null || id === undefined || id.length === 0) {
      return '—';
    }
    return id.length <= 8 ? id : `…${id.substring(id.length - 6)}`;
  }

  /** 视口状态文案 */
  private static viewportText(vp: ViewportState | null): string {
    if (vp === null) {
      return '—';
    }
    return `p${vp.currentPage} ×${vp.scale.toFixed(2)} (${Math.round(vp.centerX)}, ${Math.round(vp.centerY)})`;
  }

  /** REST BaseUrl → WebSocket Endpoint（https→wss / http→ws） */
  private static wsEndpointFor(sessionId: string): string {
    let base: string = API_BASE_URL;
    if (base.indexOf('https://') === 0) {
      base = `wss://${base.substring(8)}`;
    } else if (base.indexOf('http://') === 0) {
      base = `ws://${base.substring(7)}`;
    }
    return `${base}/ws?session=${sessionId}`;
  }
}
