/**
 * FolderMappingStore.ets — 文件夹映射存储适配器（ENG-04，阶段1 P0 净新增）
 *
 * 职责（架构 §2 / §3 / 数据规范§一）：
 *  单篇笔记 = 一个目录，用户可用文件管理器直接备份/迁移：
 *    Notes/<标题>/board.json + meta.json + resources/
 *  - board.json：画布全部节点/链接/书签（合规 BoardData，结构化 + 资源引用路径，二进制绝不内联）；
 *  - meta.json：元信息（标题/标签/收藏/创建时间），供笔记列表页快速读取，避免加载整个 board.json；
 *  - resources/：图片/PDF/截图等二进制外置目录。
 *
 * 设计：
 *  - 复用既有 `.hcnote` 的原子写安全语义：先写临时文件再 rename 提交（与 NoteRepository 一致）；
 *  - 旧 `.hcnote` 并行保留为工作副本，首次打开旧笔记时由 NoteRepository 触发 migrate 一次性转为本格式；
 *  - 所有新写入走 board.json（架构 §8-1 裁定：双格式共存迁移）。
 *
 * 依赖：@kit.CoreFileKit（fileIo）+ common/utils/SafeAsync（与 NoteRepository 同一安全原语）。
 *
 * ArkTS 严格模式：显式类型，无 any/unknown，无对象展开。
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { SafeAsync } from '../common/utils/SafeAsync';
import {
  BoardData,
  BookmarkData,
  CanvasNode,
  LinkData,
  TextPayload,
  BOARD_SCHEMA_VERSION
} from './types/BoardModel';

const TAG_MODULE = 'FolderMappingStore';

/** notes 根目录名（与 NoteRepository 的 notes 平级，便于沙箱内管理） */
const DIR_NOTES_FOLDERS: string = 'Notes';
/** 资源子目录名 */
const DIR_RESOURCES: string = 'resources';
/** 临时写槽后缀（原子提交用） */
const EXT_TMP: string = '.tmp';

/** 笔记元信息（meta.json，驱动列表页快速读取） */
export interface NoteFolderMeta {
  boardId: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  tags: string[];
  favorite: boolean;
  /** 封面缩略图相对路径（可选，如 resources/cover.png） */
  coverRef: string;
  schemaVersion: string;
  /** 笔记体积（字节，排障/容量预警） */
  sizeBytes: number;
}

export class FolderMappingStore {
  private context: common.Context | null = null;
  private notesFoldersDir: string = '';

  /** 初始化：绑定沙箱上下文 + 创建 Notes 根目录。幂等。 */
  init(context: common.Context): void {
    if (context === null || context === undefined) {
      Logger.error(TAG_MODULE, 'init 失败：context 为空');
      return;
    }
    this.context = context;
    const filesDir: string = context.filesDir;
    this.notesFoldersDir = `${filesDir}/${DIR_NOTES_FOLDERS}`;
    this.ensureDir(this.notesFoldersDir);
  }

  isReady(): boolean {
    return this.context !== null;
  }

  // ═══════════════════════════════════════════════════════════════
  // 路径工具
  // ═══════════════════════════════════════════════════════════════

  /** 笔记目录绝对路径：Notes/<slug> */
  folderPathForNote(title: string, boardId: string): string {
    if (this.notesFoldersDir.length === 0) {
      return '';
    }
    return `${this.notesFoldersDir}/${FolderMappingStore.slugify(title, boardId)}`;
  }

  /** 标题 → 合法目录名（非法字符转义 + 冲突追加序号由调用方处理） */
  static slugify(title: string, fallbackId: string): string {
    const raw: string = title !== undefined && title !== null && title.length > 0 ? title : '未命名笔记';
    let slug: string = '';
    for (let i = 0; i < raw.length; i++) {
      const ch: string = raw[i];
      // 文件系统非法字符：/ \ : * ? " < > | 以及空格折叠
      if (ch === '/' || ch === '\\' || ch === ':' || ch === '*' || ch === '?' ||
        ch === '"' || ch === '<' || ch === '>' || ch === '|') {
        slug += '_';
      } else {
        slug += ch;
      }
    }
    slug = slug.trim();
    if (slug.length === 0) {
      slug = 'note';
    }
    // 长度收敛，避免超长路径
    if (slug.length > 48) {
      slug = slug.substring(0, 48);
    }
    // 冲突兜底：追加 boardId 短串（保持确定、可去重）
    const shortId: string = fallbackId.length > 0 ? fallbackId.substring(fallbackId.length - 6) : 'anon';
    return `${slug}_${shortId}`;
  }

  private boardJsonPath(dir: string): string {
    return `${dir}/board.json`;
  }

  private metaJsonPath(dir: string): string {
    return `${dir}/meta.json`;
  }

  private resourcesDir(dir: string): string {
    return `${dir}/${DIR_RESOURCES}`;
  }

  private ensureDir(dir: string): boolean {
    return SafeAsync.run<boolean>(TAG_MODULE, `ensureDir:${dir}`, (): boolean => {
      if (fileIo.accessSync(dir)) {
        return true;
      }
      fileIo.mkdirSync(dir);
      return true;
    }, false);
  }

  /** 轻量 checksum（FNV-1a 8 位十六进制，便于完整性校验，可选） */
  private static checksum(text: string): string {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      hash = (hash ^ code) >>> 0;
      hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0;
    }
    let hex: string = (hash >>> 0).toString(16);
    while (hex.length < 8) {
      hex = `0${hex}`;
    }
    return `fnv1a:${hex}`;
  }

  /** 原子写文本（覆盖式 + fsync + 临时槽 rename 提交） */
  private writeTextAtomic(path: string, text: string): boolean {
    const tmp: string = `${path}${EXT_TMP}`;
    const ok: boolean = SafeAsync.run<boolean>(TAG_MODULE, `writeText:${path}`, (): boolean => {
      const mode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
      const file: fileIo.File = fileIo.openSync(tmp, mode);
      try {
        fileIo.writeSync(file.fd, text);
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      fileIo.renameSync(tmp, path);
      return true;
    }, false);
    return ok;
  }

  // ═══════════════════════════════════════════════════════════════
  // 写入：board.json + meta.json
  // ═══════════════════════════════════════════════════════════════

  /** 写一整篇笔记目录（board.json + meta.json；resources 由 writeResource 单独落） */
  writeBoard(dir: string, board: BoardData): void {
    if (!this.ensureDir(dir)) {
      Logger.error(TAG_MODULE, `writeBoard 失败：目录创建失败 ${dir}`);
      return;
    }
    const text: string = JSON.stringify(board, null, 2);
    const ok: boolean = this.writeTextAtomic(this.boardJsonPath(dir), text);
    if (!ok) {
      Logger.error(TAG_MODULE, `writeBoard 失败：${dir}`);
      return;
    }
    const meta: NoteFolderMeta = FolderMappingStore.toMeta(board, text.length);
    const metaText: string = JSON.stringify(meta, null, 2);
    this.writeTextAtomic(this.metaJsonPath(dir), metaText);
    Logger.info(TAG_MODULE, `writeBoard 成功 ${dir}，nodes=${board.nodes.length}`);
  }

  /** board → meta（驱动列表页） */
  static toMeta(board: BoardData, sizeBytes: number): NoteFolderMeta {
    let title: string = '未命名笔记';
    let firstText: string = '';
    for (let i = 0; i < board.nodes.length; i++) {
      const n: CanvasNode = board.nodes[i];
      if (n.type === 'text') {
        const pl = n.payload as TextPayload;
        if (pl.content !== undefined && pl.content.length > 0) {
          firstText = pl.content;
          break;
        }
      }
    }
    const effectiveTitle: string = firstText.length > 0 ? firstText : title;
    return {
      boardId: board.boardId,
      title: effectiveTitle,
      createdAt: board.lamport > 0 ? Date.now() : Date.now(),
      updatedAt: Date.now(),
      tags: [],
      favorite: false,
      coverRef: '',
      schemaVersion: board.schemaVersion,
      sizeBytes: sizeBytes
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // 读取：board.json + meta.json
  // ═══════════════════════════════════════════════════════════════

  /** 读 board.json（解析失败返回空 BoardData，绝不抛异常） */
  readBoard(dir: string): BoardData {
    const path: string = this.boardJsonPath(dir);
    const text: string = SafeAsync.run<string>(TAG_MODULE, `readBoard:${path}`, (): string => {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const arr: ArrayBuffer = new ArrayBuffer(stat.size);
        const readLen: number = fileIo.readSync(file.fd, arr);
        if (readLen <= 0) {
          return '';
        }
        const bytes: Uint8Array = new Uint8Array(arr.slice(0, readLen));
        const decoder = new util.TextDecoder();
        return decoder.decodeToString(bytes);
      } finally {
        fileIo.closeSync(file);
      }
    }, '');
    if (text.length === 0) {
      return FolderMappingStore.emptyBoard('');
    }
    try {
      const parsed = JSON.parse(text) as BoardData;
      if (parsed === undefined || parsed === null || !Array.isArray(parsed.nodes)) {
        return FolderMappingStore.emptyBoard('');
      }
      return parsed;
    } catch (e) {
      Logger.error(TAG_MODULE, `readBoard 解析失败：${path}`);
      return FolderMappingStore.emptyBoard('');
    }
  }

  /** 从 meta.json 读列表元信息（不存在/失败返回 null） */
  readMeta(dir: string): NoteFolderMeta | null {
    const path: string = this.metaJsonPath(dir);
    const text: string = SafeAsync.run<string>(TAG_MODULE, `readMeta:${path}`, (): string => {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      if (stat.size <= 0) {
        return '';
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const arr: ArrayBuffer = new ArrayBuffer(stat.size);
        const readLen: number = fileIo.readSync(file.fd, arr);
        if (readLen <= 0) {
          return '';
        }
        const bytes: Uint8Array = new Uint8Array(arr.slice(0, readLen));
        const decoder = new util.TextDecoder();
        return decoder.decodeToString(bytes);
      } finally {
        fileIo.closeSync(file);
      }
    }, '');
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as NoteFolderMeta;
    } catch (e) {
      return null;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 资源（resources/）
  // ═══════════════════════════════════════════════════════════════

  /** 写一份资源二进制（相对路径如 resources/img_01.png 的 basename 落盘） */
  writeResource(dir: string, relPath: string, bytes: Uint8Array): boolean {
    const resDir: string = this.resourcesDir(dir);
    if (!this.ensureDir(resDir)) {
      return false;
    }
    const name: string = FolderMappingStore.basename(relPath);
    const full: string = `${resDir}/${name}`;
    return SafeAsync.run<boolean>(TAG_MODULE, `writeResource:${full}`, (): boolean => {
      const mode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
      const file: fileIo.File = fileIo.openSync(full, mode);
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    }, false);
  }

  /** 读资源二进制（不存在返回空 Uint8Array） */
  readResource(dir: string, relPath: string): Uint8Array {
    const name: string = FolderMappingStore.basename(relPath);
    const full: string = `${this.resourcesDir(dir)}/${name}`;
    return SafeAsync.run<Uint8Array>(TAG_MODULE, `readResource:${full}`, (): Uint8Array => {
      if (!fileIo.accessSync(full)) {
        return new Uint8Array(0);
      }
      const stat: fileIo.Stat = fileIo.statSync(full);
      if (stat.size <= 0) {
        return new Uint8Array(0);
      }
      const file: fileIo.File = fileIo.openSync(full, fileIo.OpenMode.READ_ONLY);
      try {
        const arr: ArrayBuffer = new ArrayBuffer(stat.size);
        const readLen: number = fileIo.readSync(file.fd, arr);
        if (readLen <= 0) {
          return new Uint8Array(0);
        }
        return new Uint8Array(arr.slice(0, readLen));
      } finally {
        fileIo.closeSync(file);
      }
    }, new Uint8Array(0));
  }

  private static basename(relPath: string): string {
    const idx: number = relPath.lastIndexOf('/');
    return idx >= 0 ? relPath.substring(idx + 1) : relPath;
  }

  /** 空 board（首次创建/读取失败兜底） */
  static emptyBoard(boardId: string): BoardData {
    const board: BoardData = {
      schemaVersion: BOARD_SCHEMA_VERSION,
      boardId: boardId.length > 0 ? boardId : `b_${Date.now()}`,
      lamport: 0,
      viewport: { x: 0, y: 0, zoom: 1 },
      nodes: [],
      links: [],
      bookmarks: []
    };
    return board;
  }

  /** 空 meta（兜底） */
  static emptyMeta(boardId: string): NoteFolderMeta {
    return {
      boardId: boardId,
      title: '未命名笔记',
      createdAt: Date.now(),
      updatedAt: Date.now(),
      tags: [],
      favorite: false,
      coverRef: '',
      schemaVersion: BOARD_SCHEMA_VERSION,
      sizeBytes: 0
    };
  }
}
