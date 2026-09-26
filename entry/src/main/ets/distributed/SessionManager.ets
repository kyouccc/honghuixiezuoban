/**
 * SessionManager.ets — 超级终端流转会话（v2.0 增量，S2T01 / HM-08）
 *
 * 职责：
 *  - 设备组身份（deviceGroupId，同账号信任域，Q-03 决策：参赛以设备组模拟账号体系）；
 *  - 笔记会话角色：NoteHost / Follower / Viewer（沿用 v1 RoleAssigner 打分算法，
 *    映射：NoteHost=原 DRAW/HOST、Follower=可编辑跟随端、Viewer=展示端只读）；
 *  - 流转流程：startFlow（主机发起）→ acceptFlow（目标端接受）→ transferHost（主机转移）；
 *  - 会话状态续传：resumeSession 恢复全量会话状态（CRDT op log 追赶 + 图层/底纸重建由上层完成）；
 *  - 断连自动合并：mergeAfterReconnect（沿用 v1 SV-09 双链路语义）。
 *
 * 纯逻辑模块：不依赖 @kit.*（QA 可在 Node 环境直接验证）。
 */

import { Logger } from '../common/Logger';
import { DeviceRole, DiscoveredDeviceInfo } from './DeviceDiscovery';
import { RoleAssigner, NoteSessionRole, mapDeviceRoleToSessionRole } from './RoleAssigner';
import { ViewportState } from './ViewportSyncManager';

const TAG_MODULE = 'SessionManager';

/** 会话内设备角色（与 NoteSessionRole 字符串对齐） */
export enum SessionDeviceRole {
  NOTE_HOST = 'NOTE_HOST',
  FOLLOWER = 'FOLLOWER',
  VIEWER = 'VIEWER',
}

/** 流转会话状态（可序列化，用于状态续传） */
export interface FlowSessionState {
  sessionId: string;
  deviceGroupId: string;
  noteId: string;
  hostDeviceId: string;
  localDeviceId: string;
  localRole: SessionDeviceRole;
  connectedDeviceIds: string[];
  lastViewport: ViewportState | null;
  createdAt: number;
  updatedAt: number;
}

/** 会话状态监听者 */
export interface SessionStateListener {
  onSessionStateChanged: (state: FlowSessionState) => void;
  onRoleChanged: (role: SessionDeviceRole) => void;
}

export class SessionManager {
  private static instance: SessionManager | null = null;
  private roleAssigner: RoleAssigner = RoleAssigner.getInstance();
  private state: FlowSessionState | null = null;
  private listeners: SessionStateListener[] = [];
  private localDeviceId: string = 'local';
  private deviceRoles: Map<string, DeviceRole> = new Map();

  static getInstance(): SessionManager {
    if (!SessionManager.instance) {
      SessionManager.instance = new SessionManager();
    }
    return SessionManager.instance;
  }

  setLocalDeviceId(deviceId: string): void {
    if (deviceId.length > 0) {
      this.localDeviceId = deviceId;
    }
  }

  getLocalDeviceId(): string {
    return this.localDeviceId;
  }

  /** 创建/恢复会话（noteId + deviceGroupId），本机默认为 NoteHost（同账号编辑态） */
  createSession(noteId: string, deviceGroupId: string): FlowSessionState {
    const now: number = Date.now();
    const state: FlowSessionState = {
      sessionId: `s_${now}_${Math.random().toString(36).substring(2, 8)}`,
      deviceGroupId: deviceGroupId,
      noteId: noteId,
      hostDeviceId: this.localDeviceId,
      localDeviceId: this.localDeviceId,
      localRole: SessionDeviceRole.NOTE_HOST,
      connectedDeviceIds: [this.localDeviceId],
      lastViewport: null,
      createdAt: now,
      updatedAt: now
    };
    this.state = state;
    this.notifyStateChanged(state);
    Logger.info(TAG_MODULE, `Session created: ${state.sessionId}, group=${deviceGroupId}, note=${noteId}`);
    return state;
  }

  /**
   * 一键流转（主机发起）：目标设备加入会话。
   * 目标端通过 acceptFlow 完成角色确认（沿用 RoleAssigner 打分）。
   */
  startFlow(targetDeviceId: string, noteId: string, deviceGroupId: string): boolean {
    if (targetDeviceId.length === 0 || targetDeviceId === this.localDeviceId) {
      Logger.warn(TAG_MODULE, `startFlow: invalid target ${targetDeviceId}`);
      return false;
    }
    let state: FlowSessionState | null = this.state;
    if (state === null || state.noteId !== noteId) {
      state = this.createSession(noteId, deviceGroupId);
    }
    if (state.connectedDeviceIds.indexOf(targetDeviceId) === -1) {
      state.connectedDeviceIds.push(targetDeviceId);
    }
    state.updatedAt = Date.now();
    this.notifyStateChanged(state);
    Logger.info(TAG_MODULE, `Flow started: ${this.localDeviceId} -> ${targetDeviceId} (${state.sessionId})`);
    return true;
  }

  /**
   * 目标端接受流转：沿用 RoleAssigner 打分算法分配会话角色。
   * 若本机被分配为 NoteHost（如平板具备笔支持），则成为新主机并触发主机转移语义。
   */
  acceptFlow(sessionId: string, deviceGroupId: string, noteId: string): FlowSessionState | null {
    const deviceRole: DeviceRole = this.pickDeviceRoleForLocal();
    const sessionRole: NoteSessionRole = mapDeviceRoleToSessionRole(deviceRole);
    const localRole: SessionDeviceRole = SessionManager.toSessionDeviceRole(sessionRole);
    const now: number = Date.now();
    const state: FlowSessionState = {
      sessionId: sessionId,
      deviceGroupId: deviceGroupId,
      noteId: noteId,
      hostDeviceId: localRole === SessionDeviceRole.NOTE_HOST ? this.localDeviceId : '',
      localDeviceId: this.localDeviceId,
      localRole: localRole,
      connectedDeviceIds: [this.localDeviceId],
      lastViewport: null,
      createdAt: now,
      updatedAt: now
    };
    this.state = state;
    this.notifyStateChanged(state);
    Logger.info(TAG_MODULE, `Flow accepted: ${sessionId}, role=${localRole}`);
    return state;
  }

  /** 主机转移：新主机由 Follower 提升，本机降为 Follower（展示端则 Viewer） */
  transferHost(newHostDeviceId: string): boolean {
    const state: FlowSessionState | null = this.state;
    if (state === null) {
      Logger.warn(TAG_MODULE, 'transferHost: no active session');
      return false;
    }
    if (newHostDeviceId === state.hostDeviceId) {
      return true;
    }
    state.hostDeviceId = newHostDeviceId;
    if (newHostDeviceId === this.localDeviceId) {
      state.localRole = SessionDeviceRole.NOTE_HOST;
    } else {
      state.localRole = SessionDeviceRole.FOLLOWER;
    }
    state.updatedAt = Date.now();
    this.notifyRoleChanged(state.localRole);
    this.notifyStateChanged(state);
    Logger.info(TAG_MODULE, `Host transferred: ${newHostDeviceId}, local role=${state.localRole}`);
    return true;
  }

  /**
   * 状态续传：主机下发笔记全量状态（CRDT op log 追赶 + 文档页引用 + 视口），
   * 本机恢复会话后"接着写"。snapshot 来自主机（序列化 FlowSessionState）。
   */
  resumeSession(sessionId: string, snapshot: FlowSessionState): boolean {
    if (snapshot.sessionId !== sessionId) {
      Logger.warn(TAG_MODULE, `resumeSession: session mismatch ${sessionId} vs ${snapshot.sessionId}`);
      return false;
    }
    const resumed: FlowSessionState = {
      sessionId: snapshot.sessionId,
      deviceGroupId: snapshot.deviceGroupId,
      noteId: snapshot.noteId,
      hostDeviceId: snapshot.hostDeviceId,
      localDeviceId: this.localDeviceId,
      localRole: snapshot.localRole,
      connectedDeviceIds: snapshot.connectedDeviceIds.slice(),
      lastViewport: snapshot.lastViewport,
      createdAt: snapshot.createdAt,
      updatedAt: Date.now()
    };
    if (resumed.connectedDeviceIds.indexOf(this.localDeviceId) === -1) {
      resumed.connectedDeviceIds.push(this.localDeviceId);
    }
    this.state = resumed;
    this.notifyStateChanged(resumed);
    Logger.info(TAG_MODULE, `Session resumed: ${sessionId}, role=${resumed.localRole}, devices=${resumed.connectedDeviceIds.length}`);
    return true;
  }

  /**
   * 断连自动合并（HM-12，沿用 v1 SV-09 双链路）：合并远端会话设备列表，
   * 保留本地角色与主机；断连期间远端新增设备并入列表。
   */
  mergeAfterReconnect(remoteState: FlowSessionState): boolean {
    const local: FlowSessionState | null = this.state;
    if (local === null) {
      this.state = remoteState;
      this.notifyStateChanged(remoteState);
      return true;
    }
    for (let i = 0; i < remoteState.connectedDeviceIds.length; i++) {
      const deviceId: string = remoteState.connectedDeviceIds[i];
      if (local.connectedDeviceIds.indexOf(deviceId) === -1) {
        local.connectedDeviceIds.push(deviceId);
      }
    }
    if (remoteState.hostDeviceId.length > 0 && local.hostDeviceId !== remoteState.hostDeviceId) {
      local.hostDeviceId = remoteState.hostDeviceId;
    }
    local.updatedAt = Date.now();
    this.notifyStateChanged(local);
    Logger.info(TAG_MODULE, `Session merged after reconnect: ${local.connectedDeviceIds.length} devices`);
    return true;
  }

  /** 视口跟随：更新会话内最近视口（LWW 展示态，不进 CRDT） */
  syncViewport(vp: ViewportState): void {
    const state: FlowSessionState | null = this.state;
    if (state !== null) {
      state.lastViewport = vp;
      state.updatedAt = Date.now();
    }
  }

  /** 附加流转设备：沿用打分算法分配会话角色并记录设备角色 */
  attachDevice(device: DiscoveredDeviceInfo): NoteSessionRole {
    const sessionRole: NoteSessionRole = this.roleAssigner.assignSessionRole(device, this.deviceRoles);
    this.deviceRoles.set(device.deviceId, device.role);
    const state: FlowSessionState | null = this.state;
    if (state !== null && state.connectedDeviceIds.indexOf(device.deviceId) === -1) {
      state.connectedDeviceIds.push(device.deviceId);
      state.updatedAt = Date.now();
      this.notifyStateChanged(state);
    }
    Logger.info(TAG_MODULE, `Device attached: ${device.deviceName} -> sessionRole=${sessionRole}`);
    return sessionRole;
  }

  getState(): FlowSessionState | null {
    return this.state;
  }

  getLocalRole(): SessionDeviceRole {
    const state: FlowSessionState | null = this.state;
    return state !== null ? state.localRole : SessionDeviceRole.NOTE_HOST;
  }

  isNoteHost(): boolean {
    return this.getLocalRole() === SessionDeviceRole.NOTE_HOST;
  }

  /** 是否可写（NoteHost/Follower 可编辑，Viewer 只读） */
  canWrite(): boolean {
    const role: SessionDeviceRole = this.getLocalRole();
    const result = role === SessionDeviceRole.NOTE_HOST || role === SessionDeviceRole.FOLLOWER;
    
    // 🔍 诊断埋点：权限判断逻辑
    Logger.info(TAG_MODULE, `SessionManager.canWrite() 判断：localRole=${role}, state=${this.state ? 'exists' : 'null'}, result=${result}`);
    
    return result;
  }

  registerListener(listener: SessionStateListener): void {
    this.listeners.push(listener);
  }

  unregisterListener(listener: SessionStateListener): void {
    const index: number = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  reset(): void {
    this.state = null;
    this.listeners = [];
    this.deviceRoles.clear();
  }

  // ─── 内部 ───

  private pickDeviceRoleForLocal(): DeviceRole {
    // 流转目标端通常是平板/PC：默认按"具备笔支持"给 DRAW（→NoteHost），
    // 无笔的展示端由上层 attachDevice 按实际设备信息重新分配。
    const fallback: DiscoveredDeviceInfo = {
      deviceId: this.localDeviceId,
      deviceName: 'local',
      deviceType: 'tablet',
      networkId: '',
      screenSize: 11,
      hasTouch: true,
      hasPenSupport: true,
      role: DeviceRole.VIEWER,
      isOnline: true,
      bindTime: Date.now()
    };
    return this.roleAssigner.assignRole(fallback, this.deviceRoles);
  }

  private static toSessionDeviceRole(role: NoteSessionRole): SessionDeviceRole {
    if (role === NoteSessionRole.NOTE_HOST) {
      return SessionDeviceRole.NOTE_HOST;
    }
    if (role === NoteSessionRole.FOLLOWER) {
      return SessionDeviceRole.FOLLOWER;
    }
    return SessionDeviceRole.VIEWER;
  }

  private notifyStateChanged(state: FlowSessionState): void {
    for (const listener of this.listeners) {
      listener.onSessionStateChanged(state);
    }
  }

  private notifyRoleChanged(role: SessionDeviceRole): void {
    for (const listener of this.listeners) {
      listener.onRoleChanged(role);
    }
  }
}
