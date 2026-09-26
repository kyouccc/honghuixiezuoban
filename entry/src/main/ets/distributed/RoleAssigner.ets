import { Logger } from '../common/Logger';
import { DeviceRole, DiscoveredDeviceInfo } from './DeviceDiscovery';

const TAG_MODULE = 'RoleAssigner';

/**
 * 会话角色（v2.0 增量，S2T01 / HM-08）：
 * 超级终端流转语义 = 笔记主机 NoteHost + 跟随端 Follower + 展示端 Viewer。
 * 映射关系（架构 §1.2）：NoteHost=原 DRAW/HOST，Follower=可编辑跟随端（原 CONTROLLER），
 * Viewer=展示端只读（原 DISPLAY/VIEWER）。
 */
export enum NoteSessionRole {
  NOTE_HOST = 'NOTE_HOST',
  FOLLOWER = 'FOLLOWER',
  VIEWER = 'VIEWER',
}

/** 设备角色 → 会话角色映射（沿用 v1 HM-02 打分算法输出，映射为笔记会话语义） */
export function mapDeviceRoleToSessionRole(role: DeviceRole): NoteSessionRole {
  if (role === DeviceRole.DRAW || role === DeviceRole.HOST) {
    return NoteSessionRole.NOTE_HOST;
  }
  if (role === DeviceRole.CONTROLLER) {
    return NoteSessionRole.FOLLOWER;
  }
  return NoteSessionRole.VIEWER;
}

export class RoleAssigner {
  private static instance: RoleAssigner | null = null;
  private assignedRoles: Map<string, DeviceRole> = new Map();

  static getInstance(): RoleAssigner {
    if (!RoleAssigner.instance) {
      RoleAssigner.instance = new RoleAssigner();
    }
    return RoleAssigner.instance;
  }

  assignRole(device: DiscoveredDeviceInfo, existingRoles: Map<string, DeviceRole>): DeviceRole {
    const screenSize: number = device.screenSize;
    const hasTouch: boolean = device.hasTouch;
    const hasPenSupport: boolean = device.hasPenSupport;

    let controllerScore: number = 40;
    let drawScore: number = 0;
    let displayScore: number = 0;

    if (screenSize <= 7) {
      controllerScore += 27;
    } else if (screenSize <= 13) {
      drawScore += 27;
    } else {
      displayScore += 19;
    }

    if (hasTouch) {
      controllerScore += 8;
      drawScore += 10;
    }

    // v2.0 修复（E-5，PRD §4.2）：笔支持权重 10→15，
    // 保证 11 寸带笔平板 drawScore(52) > controllerScore(48)，成为 DRAW（NoteHost 可续写）
    if (hasPenSupport) {
      drawScore += 15;
    }

    const hasExistingDraw: boolean = this.roleExists(existingRoles, DeviceRole.DRAW);
    const hasExistingDisplay: boolean = this.roleExists(existingRoles, DeviceRole.DISPLAY);

    if (hasExistingDraw) {
      drawScore = 0;
    }
    if (hasExistingDisplay) {
      displayScore = 0;
    }

    let bestRole: DeviceRole = DeviceRole.VIEWER;
    if (screenSize > 13) {
      // v2.0 修复（E-5，PRD §4.2）：大屏设备优先作为展示端（Viewer 只读），
      // 不被 controller 基础分(40)覆盖——55 寸无笔展示端不再被判 FOLLOWER 可编辑
      bestRole = hasExistingDisplay ? DeviceRole.VIEWER : DeviceRole.DISPLAY;
    } else if (drawScore > controllerScore) {
      bestRole = DeviceRole.DRAW;
    } else if (displayScore > drawScore) {
      bestRole = DeviceRole.DISPLAY;
    } else if (controllerScore >= drawScore && controllerScore >= displayScore) {
      bestRole = DeviceRole.CONTROLLER;
    }

    device.role = bestRole;
    this.assignedRoles.set(device.deviceId, bestRole);
    Logger.info(TAG_MODULE, `Role assigned: ${device.deviceName} → ${bestRole}`);
    return bestRole;
  }

  overrideRole(deviceId: string, role: DeviceRole): void {
    this.assignedRoles.set(deviceId, role);
  }

  /**
   * v2.0（S2T01）：为流转设备分配笔记会话语义角色。
   * 复用 v1 assignRole 打分算法，再将 DeviceRole 映射为 NoteSessionRole。
   */
  assignSessionRole(device: DiscoveredDeviceInfo, existingRoles: Map<string, DeviceRole>): NoteSessionRole {
    const deviceRole: DeviceRole = this.assignRole(device, existingRoles);
    return mapDeviceRoleToSessionRole(deviceRole);
  }

  getAssignedRole(deviceId: string): DeviceRole | undefined {
    return this.assignedRoles.get(deviceId);
  }

  getAllRoles(): Map<string, DeviceRole> {
    const result: Map<string, DeviceRole> = new Map();
    this.assignedRoles.forEach((role: DeviceRole, key: string) => {
      result.set(key, role);
    });
    return result;
  }

  private roleExists(roles: Map<string, DeviceRole>, target: DeviceRole): boolean {
    const values: DeviceRole[] = [];
    roles.forEach((v: DeviceRole) => { values.push(v); });
    for (const v of values) {
      if (v === target) {
        return true;
      }
    }
    return false;
  }

  reset(): void {
    this.assignedRoles.clear();
  }
}
