/**
 * NoteIndexStore.ets — 笔记索引存储（v2.4 阶段一，T1-3）
 *
 * 定位（架构 §3.1 / U-2）：
 *  笔记列表页只需要 NoteMeta（标题 / 时间 / 笔画数 / 缩略图路径），
 *  若每次都去解析全部 `.hcnote`，100 篇笔记会导致列表首屏几百毫秒卡顿。
 *  因此单独维护一份**索引**：Preferences 库 `note_index`，键 `metas`，值为 NoteMeta[] 的 JSON 文本。
 *
 * 一致性策略（S-6「先内容后索引」）：
 *  NoteRepository 先把 `.hcnote` 落盘成功，再更新索引。
 *  于是最坏情况是「文件已存在但索引缺失」——可通过 NoteRepository.rebuildIndexFromDisk 补回；
 *  绝不会出现「索引有记录但文件不存在」这种点开就报错的糟糕体验。
 *
 * 并发策略：
 *  所有写操作串行化到 `writeChain` 这条 Promise 链上，
 *  避免「自动保存 + 手动重命名」并发 read-modify-write 造成索引条目丢失。
 *
 * ArkTS 严格模式：无 any/unknown、无对象展开、Promise 显式类型。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { SafeAsync } from '../common/utils/SafeAsync';
import { NoteMeta, NoteMetaRaw, cloneNoteMeta, HC_NOTE_SCHEMA_VERSION, HC_DEFAULT_PAPER } from './types/NoteModel';

const TAG_MODULE = 'NoteIndexStore';

/** Preferences 库名 */
const STORE_NAME: string = 'note_index';

/** 索引键名 */
const KEY_METAS: string = 'metas';

/** 索引条目上限（超出按 updatedAt 淘汰最旧的，防止 Preferences 单值过大） */
const MAX_INDEX_ENTRIES: number = 500;

/**
 * 索引存储抽象。
 * 抽成接口是为了阶段二切换到 RelationalStore（关系型数据库，支持全文检索）时，
 * NoteRepository 一行不用改（架构 §3.1 依赖倒置）。
 */
export interface INoteIndexStore {
  init(context: common.Context): Promise<boolean>;

  isReady(): boolean;

  /** 返回按 updatedAt 倒序排列的全部元信息副本 */
  listMetas(): Promise<NoteMeta[]>;

  getMeta(noteId: string): Promise<NoteMeta | null>;

  /** 新增或更新（按 id 匹配） */
  upsertMeta(meta: NoteMeta): Promise<boolean>;

  removeMeta(noteId: string): Promise<boolean>;

  /** 整表覆盖（磁盘重建索引时使用） */
  replaceAll(metas: NoteMeta[]): Promise<boolean>;

  clear(): Promise<boolean>;
}

/** 基于 @kit.ArkData Preferences 的默认实现 */
export class PrefsNoteIndexStore implements INoteIndexStore {
  private context: common.Context | null = null;
  private store: preferences.Preferences | null = null;
  private cache: NoteMeta[] = [];
  private loaded: boolean = false;
  /** 写操作串行链，保证 read-modify-write 原子 */
  private writeChain: Promise<void> = Promise.resolve();

  async init(context: common.Context): Promise<boolean> {
    if (context === null || context === undefined) {
      Logger.error(TAG_MODULE, 'init 失败：context 为空');
      return false;
    }
    this.context = context;
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
      await this.reload();
      Logger.info(TAG_MODULE, `索引初始化完成，条目数=${this.cache.length}`);
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `索引初始化失败: ${SafeAsync.describe(error as Error)}`);
      this.store = null;
      this.loaded = false;
      return false;
    }
  }

  isReady(): boolean {
    return this.store !== null && this.loaded;
  }

  async listMetas(): Promise<NoteMeta[]> {
    await this.ensureLoaded();
    const copy: NoteMeta[] = [];
    for (let i = 0; i < this.cache.length; i++) {
      copy.push(cloneNoteMeta(this.cache[i]));
    }
    copy.sort((a: NoteMeta, b: NoteMeta): number => b.updatedAt - a.updatedAt);
    return copy;
  }

  async getMeta(noteId: string): Promise<NoteMeta | null> {
    await this.ensureLoaded();
    const idx: number = this.indexOf(noteId);
    return idx >= 0 ? cloneNoteMeta(this.cache[idx]) : null;
  }

  async upsertMeta(meta: NoteMeta): Promise<boolean> {
    if (meta === null || meta === undefined || meta.id.length === 0) {
      Logger.warn(TAG_MODULE, 'upsertMeta 忽略：meta 非法');
      return false;
    }
    return this.enqueue(async (): Promise<boolean> => {
      const idx: number = this.indexOf(meta.id);
      if (idx >= 0) {
        this.cache[idx] = cloneNoteMeta(meta);
      } else {
        this.cache.push(cloneNoteMeta(meta));
      }
      this.evictIfNeeded();
      return await this.flush();
    });
  }

  async removeMeta(noteId: string): Promise<boolean> {
    return this.enqueue(async (): Promise<boolean> => {
      const idx: number = this.indexOf(noteId);
      if (idx < 0) {
        return true;
      }
      this.cache.splice(idx, 1);
      return await this.flush();
    });
  }

  async replaceAll(metas: NoteMeta[]): Promise<boolean> {
    return this.enqueue(async (): Promise<boolean> => {
      const next: NoteMeta[] = [];
      for (let i = 0; i < metas.length; i++) {
        next.push(cloneNoteMeta(metas[i]));
      }
      this.cache = next;
      this.evictIfNeeded();
      return await this.flush();
    });
  }

  async clear(): Promise<boolean> {
    return this.enqueue(async (): Promise<boolean> => {
      this.cache = [];
      return await this.flush();
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // 内部实现
  // ═══════════════════════════════════════════════════════════════

  /**
   * 把动作挂到串行链尾部执行。
   * 说明：链上任一环节抛异常都会被吞掉并返回 false，链本身永不断裂。
   */
  private enqueue(action: () => Promise<boolean>): Promise<boolean> {
    const result: Promise<boolean> = new Promise<boolean>((resolve: (v: boolean) => void): void => {
      this.writeChain = this.writeChain.then(async (): Promise<void> => {
        try {
          await this.ensureLoaded();
          const ok: boolean = await action();
          resolve(ok);
        } catch (error) {
          Logger.error(TAG_MODULE, `索引写操作失败: ${SafeAsync.describe(error as Error)}`);
          resolve(false);
        }
      });
    });
    return result;
  }

  private async ensureLoaded(): Promise<void> {
    if (this.loaded) {
      return;
    }
    if (this.store === null && this.context !== null) {
      try {
        this.store = await preferences.getPreferences(this.context, STORE_NAME);
      } catch (error) {
        Logger.error(TAG_MODULE, `getPreferences 失败: ${SafeAsync.describe(error as Error)}`);
        return;
      }
    }
    await this.reload();
  }

  /** 从 Preferences 读取并解析索引；任何异常都降级为空索引，绝不抛出 */
  private async reload(): Promise<void> {
    if (this.store === null) {
      this.cache = [];
      this.loaded = false;
      return;
    }
    try {
      const text: string = await this.store.get(KEY_METAS, '') as string;
      this.cache = PrefsNoteIndexStore.parseMetas(text);
      this.loaded = true;
    } catch (error) {
      Logger.error(TAG_MODULE, `索引读取失败，降级为空索引: ${SafeAsync.describe(error as Error)}`);
      this.cache = [];
      this.loaded = true;
    }
  }

  /** 把内存索引写回 Preferences（含 flush 落盘） */
  private async flush(): Promise<boolean> {
    if (this.store === null) {
      Logger.warn(TAG_MODULE, 'flush 跳过：store 未初始化');
      return false;
    }
    try {
      const text: string = JSON.stringify(this.cache);
      await this.store.put(KEY_METAS, text);
      await this.store.flush();
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `索引写入失败: ${SafeAsync.describe(error as Error)}`);
      return false;
    }
  }

  private indexOf(noteId: string): number {
    for (let i = 0; i < this.cache.length; i++) {
      if (this.cache[i].id === noteId) {
        return i;
      }
    }
    return -1;
  }

  /** 超过上限时淘汰最旧的条目（只删索引，不删文件） */
  private evictIfNeeded(): void {
    if (this.cache.length <= MAX_INDEX_ENTRIES) {
      return;
    }
    this.cache.sort((a: NoteMeta, b: NoteMeta): number => b.updatedAt - a.updatedAt);
    const removed: number = this.cache.length - MAX_INDEX_ENTRIES;
    this.cache = this.cache.slice(0, MAX_INDEX_ENTRIES);
    Logger.warn(TAG_MODULE, `索引超过 ${MAX_INDEX_ENTRIES} 条，已淘汰最旧的 ${removed} 条（文件保留）`);
  }

  /** 宽松解析：单条脏数据只跳过该条，不影响整表 */
  private static parseMetas(text: string): NoteMeta[] {
    const result: NoteMeta[] = [];
    if (text === undefined || text === null || text.length === 0) {
      return result;
    }
    let rawList: NoteMetaRaw[];
    try {
      rawList = JSON.parse(text) as NoteMetaRaw[];
    } catch (error) {
      Logger.error(TAG_MODULE, `索引 JSON 非法，整表重置: ${SafeAsync.describe(error as Error)}`);
      return result;
    }
    if (rawList === undefined || rawList === null) {
      return result;
    }
    for (let i = 0; i < rawList.length; i++) {
      const raw: NoteMetaRaw = rawList[i];
      if (raw === undefined || raw === null) {
        continue;
      }
      const id: string = raw.id !== undefined ? raw.id : '';
      if (id.length === 0) {
        continue;
      }
      result.push({
        id: id,
        title: raw.title !== undefined ? raw.title : '未命名笔记',
        createdAt: raw.createdAt !== undefined ? raw.createdAt : 0,
        updatedAt: raw.updatedAt !== undefined ? raw.updatedAt : 0,
        paperTemplate: raw.paperTemplate !== undefined ? raw.paperTemplate : HC_DEFAULT_PAPER,
        strokeCount: raw.strokeCount !== undefined ? raw.strokeCount : 0,
        favorite: raw.favorite !== undefined ? raw.favorite : false,
        tags: raw.tags !== undefined ? raw.tags.slice() : [],
        thumbRef: raw.thumbRef !== undefined ? raw.thumbRef : `thumbs/${id}.txt`,
        schemaVersion: raw.schemaVersion !== undefined ? raw.schemaVersion : HC_NOTE_SCHEMA_VERSION,
        sizeBytes: raw.sizeBytes !== undefined ? raw.sizeBytes : 0,
        canvasWidth: raw.canvasWidth !== undefined ? raw.canvasWidth : 0,
        canvasHeight: raw.canvasHeight !== undefined ? raw.canvasHeight : 0,
      });
    }
    return result;
  }
}
