/**
 * RecycleBinService.ets — 回收站（P1 增强）
 *
 * 提供笔记删除后进入回收站、恢复、彻底删除、自动清理功能。
 */
import { Logger } from '../common/Logger';
import { fileIo } from '@kit.CoreFileKit';

const TAG = 'RecycleBinService';
const RECYCLE_DIR = 'recycle_bin';
const MAX_RECYCLE_DAYS = 30;

export interface RecycleBinItem {
  id: string;
  originalPath: string;
  deletedAt: number;
  size: number;
  noteTitle: string;
}

export class RecycleBinService {
  private static instance: RecycleBinService;
  private items: RecycleBinItem[] = [];
  private basePath: string = '';

  static getInstance(): RecycleBinService {
    if (!RecycleBinService.instance) {
      RecycleBinService.instance = new RecycleBinService();
    }
    return RecycleBinService.instance;
  }

  async init(context: Context): Promise<void> {
    this.basePath = context.filesDir + '/' + RECYCLE_DIR;
    await this.ensureDir();
    await this.loadIndex();
    this.startAutoCleanup();
  }

  private async ensureDir(): Promise<void> {
    try {
      await fileIo.mkdir(this.basePath);
    } catch (_e) {
      // 目录已存在，忽略
    }
  }

  getItems(): RecycleBinItem[] {
    return this.items;
  }

  async moveToRecycle(item: RecycleBinItem): Promise<void> {
    this.items.push(item);
    await this.saveIndex();
    Logger.info(TAG, `moved to recycle: ${item.noteTitle}`);
  }

  async restore(itemId: string): Promise<boolean> {
    const idx = this.items.findIndex(i => i.id === itemId);
    if (idx < 0) return false;
    this.items.splice(idx, 1);
    await this.saveIndex();
    Logger.info(TAG, `restored: ${itemId}`);
    return true;
  }

  async deletePermanently(itemId: string): Promise<boolean> {
    const idx = this.items.findIndex(i => i.id === itemId);
    if (idx < 0) return false;
    this.items.splice(idx, 1);
    await this.saveIndex();
    Logger.info(TAG, `permanently deleted: ${itemId}`);
    return true;
  }

  async emptyRecycle(): Promise<void> {
    this.items = [];
    await this.saveIndex();
    Logger.info(TAG, '回收站已清空');
  }

  private async loadIndex(): Promise<void> {
    try {
      const file = this.basePath + '/index.json';
      let fileExists: boolean = false;
      try {
        await fileIo.access(file);
        fileExists = true;
      } catch (_accessErr) {
        fileExists = false;
      }
      if (fileExists) {
        const content: string = await fileIo.readText(file);
        const parsed: object = JSON.parse(content);
        if (Array.isArray(parsed)) {
          this.items = parsed as RecycleBinItem[];
        }
      }
    } catch (_e) {
      this.items = [];
    }
  }

  private async saveIndex(): Promise<void> {
    const content = JSON.stringify(this.items);
    const file = this.basePath + '/index.json';
    const mode: number = fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
    const fd: fileIo.File = fileIo.openSync(file, mode);
    try {
      fileIo.writeSync(fd.fd, content);
      fileIo.fsyncSync(fd.fd);
    } finally {
      fileIo.closeSync(fd);
    }
  }

  private startAutoCleanup(): void {
    setInterval(() => {
      this.cleanupExpired();
    }, 86400000); // 每天检查一次
  }

  private cleanupExpired(): void {
    const now = Date.now();
    const before = this.items.length;
    this.items = this.items.filter(i => (now - i.deletedAt) < MAX_RECYCLE_DAYS * 86400000);
    if (this.items.length !== before) {
      Logger.info(TAG, `cleaned up ${before - this.items.length} expired items`);
      this.saveIndex();
    }
  }
}
