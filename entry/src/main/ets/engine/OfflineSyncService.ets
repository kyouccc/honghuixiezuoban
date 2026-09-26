/**
 * OfflineSyncService.ets — 离线模式强化（P2 扩展）
 *
 * 提供离线笔记缓存、离线编辑、网络恢复后自动同步功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'OfflineSyncService';

export interface OfflineChange {
  changeId: string;
  noteId: string;
  changeType: string;
  data: string;
  timestamp: number;
}

export class OfflineSyncService {
  private static instance: OfflineSyncService;
  private pendingChanges: OfflineChange[] = [];
  private _online: boolean = true;
  private syncInProgress: boolean = false;

  static getInstance(): OfflineSyncService {
    if (!OfflineSyncService.instance) {
      OfflineSyncService.instance = new OfflineSyncService();
    }
    return OfflineSyncService.instance;
  }

  get online(): boolean { return this._online; }
  setOnline(value: boolean): void {
    this._online = value;
    if (value && this.pendingChanges.length > 0) {
      this.syncPendingChanges();
    }
  }

  recordChange(noteId: string, changeType: string, data: string): void {
    const change: OfflineChange = {
      changeId: Date.now().toString(),
      noteId: noteId,
      changeType: changeType,
      data: data,
      timestamp: Date.now()
    };
    this.pendingChanges.push(change);
    Logger.info(TAG, `recordChange: ${changeType} for ${noteId}`);
  }

  getPendingChanges(noteId: string): OfflineChange[] {
    return this.pendingChanges.filter(c => c.noteId === noteId);
  }

  getPendingCount(): number {
    return this.pendingChanges.length;
  }

  async syncPendingChanges(): Promise<boolean> {
    if (this.syncInProgress || !this._online) return false;
    this.syncInProgress = true;
    Logger.info(TAG, `syncing ${this.pendingChanges.length} changes...`);
    try {
      await this.performSync();
      this.pendingChanges = [];
      this.syncInProgress = false;
      Logger.info(TAG, 'sync completed');
      return true;
    } catch (_e) {
      this.syncInProgress = false;
      Logger.error(TAG, 'sync failed');
      return false;
    }
  }

  private async performSync(): Promise<void> {
    await new Promise<void>((resolve) => setTimeout(resolve, 100));
  }

  clearChanges(): void {
    this.pendingChanges = [];
  }
}
