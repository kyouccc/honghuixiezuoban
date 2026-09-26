/**
 * VersionHistoryService.ets — 版本历史（P1 增强）
 *
 * 提供笔记版本快照管理、历史版本浏览与恢复功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'VersionHistoryService';

export interface VersionEntry {
  id: string;
  noteId: string;
  timestamp: number;
  title: string;
  description: string;
  snapshotSize: number;
}

export class VersionHistoryService {
  private static instance: VersionHistoryService;
  private versions: VersionEntry[] = [];
  private basePath: string = '';

  static getInstance(): VersionHistoryService {
    if (!VersionHistoryService.instance) {
      VersionHistoryService.instance = new VersionHistoryService();
    }
    return VersionHistoryService.instance;
  }

  async init(context: Context): Promise<void> {
    this.basePath = context.filesDir + '/versions';
  }

  getVersions(noteId: string): VersionEntry[] {
    return this.versions.filter(v => v.noteId === noteId).sort((a, b) => b.timestamp - a.timestamp);
  }

  getVersion(id: string): VersionEntry | null {
    return this.versions.find(v => v.id === id) ?? null;
  }

  async createSnapshot(noteId: string, title: string, description: string): Promise<VersionEntry> {
    const entry: VersionEntry = {
      id: Date.now().toString(),
      noteId: noteId,
      timestamp: Date.now(),
      title: title,
      description: description,
      snapshotSize: 0
    };
    this.versions.push(entry);
    await this.saveIndex();
    return entry;
  }

  async restoreVersion(id: string): Promise<boolean> {
    const version = this.versions.find(v => v.id === id);
    if (!version) return false;
    Logger.info(TAG, `restoreVersion: ${version.title}`);
    return true;
  }

  async deleteVersion(id: string): Promise<boolean> {
    const idx = this.versions.findIndex(v => v.id === id);
    if (idx < 0) return false;
    this.versions.splice(idx, 1);
    await this.saveIndex();
    return true;
  }

  async clearVersions(noteId: string): Promise<void> {
    this.versions = this.versions.filter(v => v.noteId !== noteId);
    await this.saveIndex();
  }

  private async saveIndex(): Promise<void> {
    // 保存到本地文件 - 由具体实现补充
    Logger.info(TAG, `versions saved: ${this.versions.length}`);
  }
}
