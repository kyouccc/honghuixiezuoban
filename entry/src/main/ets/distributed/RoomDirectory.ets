/**
 * RoomDirectory.ets — 账号级「房间目录」（v2.7.4 新增）
 *
 * ══════════════════════════════════════════════════════════════════════
 * 🔴 v2.7.4 审核修复（问题①前半句「输入任意房间号，都能够加入房间」）
 *
 * 问题本质：本产品是「本地优先 + 分布式」架构，没有中心服务器，
 *   因此原先**没有任何地方登记过"哪些房间存在"** → 输入任意 6 位数字都能"加入成功"，
 *   用户进了房间却看不到任何人、也共享不到白板，体验上就是"校验缺失"。
 *
 * 修法：建立**账号级房间目录** —— 一个所有同账号设备共享的分布式数据对象
 *   （固定 sessionId，因此同账号设备自动同步），房主创建房间时把房间号登记进去；
 *   其它设备加入房间前**先查目录**：
 *     · 目录中有该房间号 → 允许加入，并显示房主设备号
 *     · 目录中没有         → 明确提示「房间不存在或房主未在线」，**不置为已加入**
 *     · 目录本身不可用     → 无法校验，允许加入但如实告知（不谎报"已确认房间"）
 *
 * ⚠️ API 与 DistributedBoardSession 一致（本 SDK 实测签名）：
 *   create(context, source) 需 Context；属性直接读写；on('change') 只给字段名。
 * ⚠️ 权限：ohos.permission.DISTRIBUTED_DATASYNC
 * ══════════════════════════════════════════════════════════════════════
 */

import { distributedDataObject } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { SafeAsync } from '../common/utils/SafeAsync';

const TAG = 'RoomDirectory';

/** 账号级目录会话 id：固定值 → 同一华为账号下的设备自动同步同一份目录 */
const DIRECTORY_SESSION_ID: string = 'hc_room_directory_v1';

/** 房间登记条目 */
interface RoomEntry {
  code: string;
  hostDeviceId: string;
  hostName: string;
  createdAt: number;
}

/** 目录数据对象 */
interface DirectoryDO extends distributedDataObject.DataObject {
  rooms: string;
}

/** 房间查询结果 */
export interface RoomLookup {
  /** 是否至少有一条可用对端（能读到目录内容） */
  available: boolean;
  /** 目录中是否存在该房间 */
  exists: boolean;
  /** 房主显示名（exists 时有意义） */
  hostName: string;
  /** 房主设备号短标识 */
  hostShortId: string;
}

export class RoomDirectory {
  private static instance: RoomDirectory | null = null;

  private obj: DirectoryDO | null = null;
  private entries: RoomEntry[] = [];
  private opened: boolean = false;
  /** 是否从对端收到过目录内容（用于判断"目录可用"） */
  private syncedFromPeer: boolean = false;

  static getInstance(): RoomDirectory {
    if (RoomDirectory.instance === null) {
      RoomDirectory.instance = new RoomDirectory();
    }
    return RoomDirectory.instance;
  }

  /**
   * 打开账号级房间目录。
   * @returns 是否成功建立数据对象（false 表示无法校验，调用方应降级处理）
   */
  async open(context: common.Context): Promise<boolean> {
    if (this.opened) {
      return true;
    }
    if (context === null || context === undefined) {
      return false;
    }
    try {
      const created: distributedDataObject.DataObject = distributedDataObject.create(context, {
        rooms: JSON.stringify(this.prune([])),
      });
      this.obj = created as DirectoryDO;
      this.obj.on('change', (sessionId: string, fields: Array<string>): void => {
        SafeAsync.runVoid(TAG, 'onDirectoryChange', (): void => {
          this.parseRooms(true);
        });
      });
      this.obj.on('status', (sessionId: string, networkId: string, status: 'online' | 'offline'): void => {
        Logger.info(TAG, `目录对端 ${status}（${networkId}）`);
      });
      this.obj.setSessionId(DIRECTORY_SESSION_ID).catch((err: Error): void => {
        Logger.error(TAG, `setSessionId 失败: ${SafeAsync.describe(err)}`);
      });
      this.parseRooms(false);
      this.opened = true;
      Logger.info(TAG, '房间目录已打开');
      return true;
    } catch (e) {
      this.obj = null;
      this.opened = false;
      Logger.error(TAG, `打开房间目录失败: ${SafeAsync.describe(e as Error)}`);
      return false;
    }
  }

  /** 关闭目录（离开协作相关页面时调用） */
  close(): void {
    if (this.obj !== null) {
      try {
        this.obj.off('change');
        this.obj.off('status');
        this.obj.setSessionId('').catch((): void => { /* 忽略 */ });
      } catch (e) {
        Logger.warn(TAG, '关闭房间目录时解绑失败');
      }
      this.obj = null;
    }
    this.opened = false;
    Logger.info(TAG, '房间目录已关闭');
  }

  /** 房主登记房间（其它同账号设备随即可见） */
  publishRoom(code: string, hostDeviceId: string, hostName: string): void {
    if (this.obj === null) {
      Logger.warn(TAG, '目录未打开，房间未登记（其它设备将无法校验该房间）');
      return;
    }
    const next: RoomEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].code !== code) {
        next.push(this.entries[i]);
      }
    }
    next.push({
      code: code,
      hostDeviceId: hostDeviceId,
      hostName: hostName.length > 0 ? hostName : '房主',
      createdAt: Date.now(),
    });
    this.entries = this.prune(next);
    this.writeEntries();
  }

  /** 撤销房间登记 */
  unpublishRoom(code: string): void {
    if (this.obj === null) {
      return;
    }
    const next: RoomEntry[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].code !== code) {
        next.push(this.entries[i]);
      }
    }
    this.entries = next;
    this.writeEntries();
  }

  /** 查询房间是否已登记 */
  lookup(code: string): RoomLookup {
    const available: boolean = this.obj !== null && this.syncedFromPeer;
    for (let i = 0; i < this.entries.length; i++) {
      const e: RoomEntry = this.entries[i];
      if (e.code === code) {
        return {
          available: true,
          exists: true,
          hostName: e.hostName,
          hostShortId: RoomDirectory.shorten(e.hostDeviceId),
        };
      }
    }
    return { available: available, exists: false, hostName: '', hostShortId: '' };
  }

  /** 已登记房间数（诊断用） */
  count(): number {
    return this.entries.length;
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  private writeEntries(): void {
    if (this.obj === null) {
      return;
    }
    try {
      this.obj.rooms = JSON.stringify(this.entries);
      Logger.info(TAG, `房间目录已更新（${this.entries.length} 个房间）`);
    } catch (e) {
      Logger.error(TAG, `写入房间目录失败: ${SafeAsync.describe(e as Error)}`);
    }
  }

  /** 解析目录内容；fromPeer=true 表示确实收到了对端推送 */
  private parseRooms(fromPeer: boolean): void {
    if (this.obj === null) {
      return;
    }
    const raw: string = `${this.obj.rooms}`;
    if (raw.length <= 2) {
      return;
    }
    let list: RoomEntry[] = [];
    try {
      list = JSON.parse(raw) as RoomEntry[];
    } catch (e) {
      Logger.warn(TAG, '目录 JSON 解析失败，已忽略');
      return;
    }
    if (list === null || list === undefined) {
      return;
    }
    this.entries = this.prune(list);
    // 变更事件 → 确实来自对端；初次解析时若目录非空，说明也已同步到对端数据
    if (fromPeer || this.entries.length > 0) {
      this.syncedFromPeer = true;
    }
    Logger.info(TAG, `目录已加载 ${this.entries.length} 个房间（fromPeer=${fromPeer}）`);
  }

  /** 清理过期登记（12 小时），避免目录无限膨胀 */
  private prune(list: RoomEntry[]): RoomEntry[] {
    const now: number = Date.now();
    const ttl: number = 12 * 60 * 60 * 1000;
    const out: RoomEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const e: RoomEntry = list[i];
      if (e === null || e === undefined || e.code === undefined) {
        continue;
      }
      if (now - e.createdAt <= ttl) {
        out.push(e);
      }
    }
    return out;
  }

  /** 设备号短标识 */
  private static shorten(id: string): string {
    if (id === null || id === undefined || id.length === 0) {
      return '—';
    }
    return id.length <= 6 ? id : id.substring(id.length - 6);
  }
}
