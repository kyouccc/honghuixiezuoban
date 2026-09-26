/**
 * CrashRecoveryService.ets - 崩溃恢复服务（F-04 崩溃兜底）
 *
 * ══════════════════════════════════════════════════════════════════════
 * v2.6.0 审核修复（问题③「我的：未保存内容无法恢复」）——三个真因全部修掉：
 *
 * 真因 A｜持久化介质错误
 *   原实现把整个 NoteContent 用 `preferences.put()` 存进 Preferences。
 *   Preferences 的 Value 有长度上限（远小于一篇真实笔记的 JSON），
 *   只要笔记有点内容，写入就抛错并被 catch 静默吞掉 —— 磁盘上留下的是
 *   更早的、很小的旧快照（审核员看到的正是 4 天前那张「1 笔触 / 2 图层」）。
 *   → 改为写入应用沙箱文件 `filesDir/recovery/latest.recovery.json`（无长度限制）。
 *
 * 真因 B｜恢复提示不区分「异常退出」与「正常退出」
 *   `initialize()` 只要 load 到数据就 setPendingRecovery，而
 *   `clearRecoveryData()` 在正常退出路径上**从未被调用**（WhiteboardPage 只调了
 *   `setCrashFlag(false)`）→ 每次冷启动都弹「检测到未保存的内容」，
 *   即使上次是正常退出。审核员连续看到同一张过期快照即源于此。
 *   → 引入 `hasPendingRecovery()`：必须有数据 **且** crashFlag 为 true；
 *     正常退出走 `markCleanExit()` 清数据 + 清标志。
 *
 * 真因 C｜恢复失败无兜底
 *   原 `recoverNote()` 走 `repository.saveNote()`，任一分支失败即返回 false，
 *   UI 只能提示「恢复失败，内容仍保留，请重试」，用户永远恢复不出来。
 *   → 改为两级恢复：①按原 noteId 回写；②失败则以**新笔记**导入（永不丢内容），
 *     并返回结构化结果供 UI 精确提示。
 * ══════════════════════════════════════════════════════════════════════
 */

import { fileIo } from '@kit.CoreFileKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { NoteEngine } from '../../engine/NoteEngine';
import { NoteContent, createNoteMeta, createEmptyNoteContent, createNoteId,
  HC_DEFAULT_PAPER } from '../../engine/types/NoteModel';
import { NoteSaveResult } from '../../engine/NoteRepository';
import { Logger } from '../Logger';

export interface CrashRecoveryData {
  noteId: string;
  title: string;
  content: NoteContent;
  timestamp: number;
  isEmergency: boolean;
}

/** v2.6.0：恢复结果结构化返回，便于 UI 给出准确提示 */
export interface RecoverOutcome {
  ok: boolean;
  /** 恢复后实际落到的 noteId（兜底导入时为新 id） */
  noteId: string;
  /** 恢复后实际标题 */
  title: string;
  /** 是否走了「另存为新笔记」兜底 */
  importedAsNew: boolean;
  /** 失败原因（ok=false 时有值） */
  errorMessage: string;
}

export class CrashRecoveryService {
  private static instance: CrashRecoveryService;
  private readonly TAG = 'CrashRecoveryService';

  // Preferences 只存「小标量」：崩溃标志
  private readonly PREF_NAME = 'crash_recovery';
  private readonly KEY_CRASH_FLAG = 'crash_flag';
  /** 兼容旧版本：历史遗留的大 JSON（会清理掉，避免反复误报） */
  private readonly KEY_RECOVERY_DATA_LEGACY = 'recovery_data';

  // 快照文件（无长度限制）
  private readonly RECOVERY_DIR = 'recovery';
  private readonly RECOVERY_FILE = 'recovery/latest.recovery.json';
  /** 单文件上限保护：超过 64MB 的快照不写入，避免极端情况下撑爆沙箱 */
  private readonly MAX_SNAPSHOT_CHARS = 64 * 1024 * 1024;

  private recoveryData: CrashRecoveryData | null = null;
  /** 上次是否异常退出（true 才允许提示恢复） */
  private crashFlag: boolean = false;
  /** 是否已 initialize（避免重复读盘） */
  private initialized: boolean = false;

  private recoveryCallbacks: Array<(data: CrashRecoveryData) => void> = [];

  private constructor() {}

  static getInstance(): CrashRecoveryService {
    if (!CrashRecoveryService.instance) {
      CrashRecoveryService.instance = new CrashRecoveryService();
    }
    return CrashRecoveryService.instance;
  }

  // ────────────────────────── 路径 / 基础 IO ──────────────────────────

  private recoveryDirPath(): string {
    const ctx: common.Context = getContext(this) as common.Context;
    return `${ctx.filesDir}/${this.RECOVERY_DIR}`;
  }

  private recoveryFilePath(): string {
    const ctx: common.Context = getContext(this) as common.Context;
    return `${ctx.filesDir}/${this.RECOVERY_FILE}`;
  }

  private ensureDir(): boolean {
    try {
      const dir: string = this.recoveryDirPath();
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
      return true;
    } catch (error) {
      Logger.error(this.TAG, '创建恢复目录失败: ' + JSON.stringify(error));
      return false;
    }
  }

  private writeSnapshotFile(text: string): boolean {
    try {
      if (!this.ensureDir()) {
        return false;
      }
      const path: string = this.recoveryFilePath();
      // 先写临时文件再改名，避免写一半崩溃留下坏快照
      const tmp: string = `${path}.tmp`;
      const file: fileIo.File = fileIo.openSync(tmp,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, text);
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      fileIo.renameSync(tmp, path);
      return true;
    } catch (error) {
      Logger.error(this.TAG, '写入恢复快照失败: ' + JSON.stringify(error));
      return false;
    }
  }

  private readSnapshotFile(): string {
    try {
      const path: string = this.recoveryFilePath();
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const buffer: ArrayBuffer = new ArrayBuffer(stat.size);
        const len: number = fileIo.readSync(file.fd, buffer);
        if (len <= 0) {
          return '';
        }
        const decoder = new util.TextDecoder('utf-8');
        return decoder.decodeToString(new Uint8Array(buffer, 0, len));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (error) {
      Logger.error(this.TAG, '读取恢复快照失败: ' + JSON.stringify(error));
      return '';
    }
  }

  private removeSnapshotFile(): void {
    try {
      const path: string = this.recoveryFilePath();
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      const tmp: string = `${path}.tmp`;
      if (fileIo.accessSync(tmp)) {
        fileIo.unlinkSync(tmp);
      }
    } catch (error) {
      Logger.error(this.TAG, '删除恢复快照失败: ' + JSON.stringify(error));
    }
  }

  // ────────────────────────── 生命周期 ──────────────────────────

  /**
   * 初始化：读取上次快照 + 崩溃标志。
   * v2.6.0：**只有 crashFlag=true 才认为「有待恢复内容」**，
   *   正常退出后不再反复弹窗（真因 B）。
   */
  async initialize(): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      this.crashFlag = await this.getCrashFlag();
      await this.loadRecoveryData();

      // 清掉旧版本遗留的大 JSON（Preferences 里那份永远读不完整的脏数据）
      await this.purgeLegacyPrefData();

      if (this.crashFlag && this.recoveryData) {
        Logger.info(this.TAG, '检测到上次异常退出，存在可恢复内容');
        this.notifyRecoveryCallbacks();
      } else if (!this.crashFlag && this.recoveryData) {
        // 正常退出却残留快照 → 顺手清掉，避免下次误报
        Logger.info(this.TAG, '上次为正常退出，清理残留快照');
        await this.clearRecoveryData();
      }
      this.initialized = true;
    } catch (error) {
      Logger.error(this.TAG, '初始化失败: ' + JSON.stringify(error));
      this.initialized = true;
    }
  }

  /** 设置崩溃标志（进入编辑器时 true / 正常退出时 false） */
  async setCrashFlag(flag: boolean): Promise<void> {
    this.crashFlag = flag;
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, this.PREF_NAME);
      await pref.put(this.KEY_CRASH_FLAG, flag);
      await pref.flush();
    } catch (error) {
      Logger.error(this.TAG, '设置崩溃标志失败: ' + JSON.stringify(error));
    }
  }

  private async getCrashFlag(): Promise<boolean> {
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, this.PREF_NAME);
      return await pref.get(this.KEY_CRASH_FLAG, false) as boolean;
    } catch (error) {
      Logger.error(this.TAG, '获取崩溃标志失败: ' + JSON.stringify(error));
      return false;
    }
  }

  /** 清理旧版本写入 Preferences 的大 JSON（Key 保留会浪费空间且毫无用处） */
  private async purgeLegacyPrefData(): Promise<void> {
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, this.PREF_NAME);
      await pref.delete(this.KEY_RECOVERY_DATA_LEGACY);
      await pref.flush();
    } catch (error) {
      Logger.warn(this.TAG, '清理历史恢复数据失败（不阻断）: ' + JSON.stringify(error));
    }
  }

  /**
   * 正常退出：清快照 + 清标志。
   * v2.6.0：WhiteboardPage.aboutToDisappear 必须调用它，否则下次冷启动会误报。
   */
  async markCleanExit(): Promise<void> {
    await this.clearRecoveryData();
  }

  // ────────────────────────── 快照读写 ──────────────────────────

  /** 保存恢复快照（v2.6.0：写文件，不再受 Preferences Value 上限约束） */
  async saveRecoveryData(data: CrashRecoveryData): Promise<void> {
    try {
      this.recoveryData = data;
      // v2.6.0：只有在「编辑会话进行中」（crashFlag=true）才允许落盘。
      //   否则 WhiteboardPage 离页时 `triggerEmergencySave()`（异步，先发起）与
      //   `markCleanExit()`（后执行删除）会竞态，把已判定为"正常退出"的快照又写回磁盘，
      //   下次冷启动便误报"检测到未保存的内容"。
      if (!this.crashFlag) {
        Logger.info(this.TAG, '非编辑会话中，跳过恢复快照落盘（仅保留内存态）');
        return;
      }
      const text: string = JSON.stringify(data);
      if (text.length > this.MAX_SNAPSHOT_CHARS) {
        Logger.warn(this.TAG, `快照过大(${text.length})，跳过落盘，仅保留内存态`);
        return;
      }
      const ok: boolean = this.writeSnapshotFile(text);
      if (ok) {
        Logger.info(this.TAG, `保存恢复快照成功: noteId=${data.noteId}, ${text.length} 字符`);
      } else {
        Logger.error(this.TAG, '保存恢复快照失败（内存态仍可用）');
      }
    } catch (error) {
      Logger.error(this.TAG, '保存恢复数据失败: ' + JSON.stringify(error));
    }
  }

  private async loadRecoveryData(): Promise<void> {
    try {
      const text: string = this.readSnapshotFile();
      if (text.length === 0) {
        this.recoveryData = null;
        return;
      }
      const parsed = JSON.parse(text) as CrashRecoveryData;
      if (parsed !== undefined && parsed !== null && parsed.content !== undefined && parsed.content !== null) {
        this.recoveryData = parsed;
        Logger.info(this.TAG, `加载恢复快照成功: noteId=${parsed.noteId}`);
      } else {
        this.recoveryData = null;
      }
    } catch (error) {
      Logger.error(this.TAG, '加载恢复数据失败: ' + JSON.stringify(error));
      this.recoveryData = null;
    }
  }

  /** 清除恢复数据（快照文件 + 崩溃标志 + 内存态） */
  async clearRecoveryData(): Promise<void> {
    try {
      this.recoveryData = null;
      this.crashFlag = false;
      this.removeSnapshotFile();
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, this.PREF_NAME);
      await pref.delete(this.KEY_CRASH_FLAG);
      await pref.delete(this.KEY_RECOVERY_DATA_LEGACY);
      await pref.flush();
      Logger.info(this.TAG, '清除恢复数据成功');
    } catch (error) {
      Logger.error(this.TAG, '清除恢复数据失败: ' + JSON.stringify(error));
    }
  }

  // ────────────────────────── 查询 ──────────────────────────

  getRecoveryData(): CrashRecoveryData | null {
    return this.recoveryData;
  }

  /** 是否存在「待恢复」的未保存内容（必须同时满足：有快照 + 上次异常退出） */
  hasPendingRecovery(): boolean {
    return this.recoveryData !== null && this.crashFlag;
  }

  /**
   * 兼容旧调用点：原语义是「有快照」。
   * v2.6.0 起统一收敛到 hasPendingRecovery()，避免正常退出被误报。
   */
  hasRecoveryData(): boolean {
    return this.hasPendingRecovery();
  }

  // ────────────────────────── 恢复 ──────────────────────────

  /**
   * 恢复笔记（v2.6.0：两级兜底，绝不因保存分支失败而让用户丢内容）。
   * ① 按原 noteId 回写（复用正式保存链路，含备份 / 校验 / 索引更新）；
   * ② ①失败 → 以**新笔记**导入（新 id + 标题加「（已恢复）」后缀）；
   * ③ 仍失败 → 返回结构化失败原因（快照文件仍保留，用户可重试）。
   */
  async recoverNote(): Promise<RecoverOutcome> {
    const data: CrashRecoveryData | null = this.recoveryData;
    if (data === null || data.content === undefined || data.content === null) {
      return { ok: false, noteId: '', title: '', importedAsNew: false, errorMessage: '没有可恢复的内容' };
    }

    const engine: NoteEngine = NoteEngine.getInstance();
    if (!engine.isStorageReady()) {
      return { ok: false, noteId: data.noteId, title: data.title,
        importedAsNew: false, errorMessage: '本地存储尚未就绪，请稍后重试' };
    }
    const repository = engine.getNoteRepository();

    // ① 原 id 回写
    try {
      const first: NoteSaveResult = await repository.saveNote(data.content, true);
      if (first.ok) {
        await this.clearRecoveryData();
        Logger.info(this.TAG, `恢复成功（原笔记）: ${data.noteId}`);
        return { ok: true, noteId: data.noteId, title: data.title, importedAsNew: false, errorMessage: '' };
      }
      Logger.warn(this.TAG, `按原 id 恢复失败(${first.errorMessage})，转兜底导入`);
    } catch (error) {
      Logger.warn(this.TAG, '按原 id 恢复异常，转兜底导入: ' + JSON.stringify(error));
    }

    // ② 兜底：作为新笔记导入
    try {
      const newId: string = createNoteId();
      const rawTitle: string = data.title.length > 0 ? data.title : '未命名笔记';
      const newTitle: string = rawTitle.length > 50 ? `${rawTitle.substring(0, 50)}（已恢复）` : `${rawTitle}（已恢复）`;
      const meta = createNoteMeta(newId, newTitle, HC_DEFAULT_PAPER);
      const content: NoteContent = createEmptyNoteContent(newId, newTitle, HC_DEFAULT_PAPER);
      // 保留原笔记的笔迹/图层/纸张，仅换 meta（id/title）
      content.meta = meta;
      content.paper = data.content.paper;
      content.viewport = data.content.viewport;
      content.layers = data.content.layers;
      content.strokes = data.content.strokes;
      content.images = data.content.images;
      content.texts = data.content.texts;
      content.docs = data.content.docs;
      content.annotations = data.content.annotations;
      content.flashcards = data.content.flashcards;
      content.mindmaps = data.content.mindmaps;
      content.nodes = data.content.nodes;
      content.links = data.content.links;
      content.bookmarks = data.content.bookmarks;
      content.canvasWidth = data.content.canvasWidth;
      content.canvasHeight = data.content.canvasHeight;

      const second: NoteSaveResult = await repository.saveNote(content, true);
      if (second.ok) {
        await this.clearRecoveryData();
        Logger.info(this.TAG, `恢复成功（兜底另存为新笔记）: ${newId}`);
        return { ok: true, noteId: newId, title: newTitle, importedAsNew: true, errorMessage: '' };
      }
      Logger.error(this.TAG, `兜底导入失败: ${second.errorMessage}`);
      return { ok: false, noteId: data.noteId, title: data.title, importedAsNew: false,
        errorMessage: second.errorMessage.length > 0 ? second.errorMessage : '保存失败' };
    } catch (error) {
      Logger.error(this.TAG, '兜底导入异常: ' + JSON.stringify(error));
      return { ok: false, noteId: data.noteId, title: data.title, importedAsNew: false,
        errorMessage: '恢复异常，快照已保留，可重试' };
    }
  }

  // ────────────────────────── 回调 ──────────────────────────

  addRecoveryCallback(callback: (data: CrashRecoveryData) => void): void {
    this.recoveryCallbacks.push(callback);
  }

  removeRecoveryCallback(callback: (data: CrashRecoveryData) => void): void {
    const index = this.recoveryCallbacks.indexOf(callback);
    if (index !== -1) {
      this.recoveryCallbacks.splice(index, 1);
    }
  }

  private notifyRecoveryCallbacks(): void {
    if (this.recoveryData !== null) {
      const data: CrashRecoveryData = this.recoveryData;
      this.recoveryCallbacks.forEach(callback => {
        callback(data);
      });
    }
  }
}

// 导出单例便捷方法
export const crashRecoveryService = CrashRecoveryService.getInstance();
