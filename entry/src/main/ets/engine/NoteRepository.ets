/**
 * NoteRepository.ets — 笔记仓储（v2.5 阶段二，T1-3 + T2-1b 数据安全与失败态）
 *
 * ⚠️ 本文件是整个阶段一**风险最高**的模块：项目此前从未真正使用过 `@kit.CoreFileKit`。
 *    因此实现顺序刻意保守——先打通「最小写读闭环」（writeTextSync / readTextSync / selfTest），
 *    再在其上叠加原子写、回退、索引联动等功能。任何一层出问题都能单独定位。
 *
 * 目录布局（context.filesDir 沙箱内）：
 *   files/
 *     notes/{id}.hcnote         正本
 *     notes/{id}.tmp0 / .tmp1   未提交草稿双槽（T2-1b：ping-pong 交替写，见「四·补」）
 *     notes/{id}.hcnote.bak     上一次成功保存的备份
 *     thumbs/{id}.txt           缩略图 dataURL 文本
 *
 * 原子写序列（S-6「先内容后索引」）：
 *   1. 全量写「非最佳草稿槽」（含 fsync，双槽 ping-pong，d1 §4.1）
 *   2. 若正本存在 → copy 正本到 `.bak`
 *   3. rename 草稿槽 → 正本（提交成功清两槽 = 闸 A，d1 §4.5）
 *   4. 更新 Preferences 索引
 *   任一步失败都不会破坏正本；最坏是「文件已更新、索引没跟上」，
 *   可由 rebuildIndexFromDisk 补齐，绝不出现「列表有、点开无」。
 *
 * 四级读取回退（S-5 / d1 §3.1，loadNote 永不抛异常）：
 *   `.hcnote` → `.bak` → 未提交草稿（L3，校验+checksum 双过才准入，不加闸 B）→ 空笔记 + errorMessage
 *   L1 命中时并行检测「校验通过且比正文新」的草稿（闸 B），仅提示不自动替换正文。
 *
 * 提交失败处置（D-1 修复，d1 §2）：
 *   ④ 提交失败 → **保留草稿槽不删除**（用户最新编辑的唯一完整副本），按四级回退与 UI 提示处理；
 *   ② 写槽失败 → **立即删除坏槽**（双槽下删已知坏的，好副本在隔壁，d1 §4.2）。
 *
 * ArkTS 严格模式：无 any/unknown、无对象展开、显式类型。
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { SafeAsync, DetailedResult, FsFailureKind, classifyFsError } from '../common/utils/SafeAsync';
import { INoteIndexStore, PrefsNoteIndexStore } from './NoteIndexStore';
import { NoteDeserializeResult, NoteSerializer } from './NoteSerializer';
import {
  HC_DEFAULT_BACKGROUND,
  HC_DEFAULT_PAPER,
  NoteContent,
  NoteLoadResult,
  NoteMeta,
  HCStroke,
  createEmptyNoteContent,
  createNoteId,
  createNoteMeta,
  normalizeNoteTitle,
} from './types/NoteModel';
import { FolderMappingStore, NoteFolderMeta } from './FolderMappingStore';
import { BoardData, CanvasNode, Point3 } from './types/BoardModel';

const TAG_MODULE = 'NoteRepository';

/** 笔记目录名 */
const DIR_NOTES: string = 'notes';

/** 缩略图目录名 */
const DIR_THUMBS: string = 'thumbs';

/** 资产目录名（文档源 / 批注缩略图等二进制或文本资产，落 notes/assets/{hash}） */
const DIR_ASSETS: string = 'assets';

/** 正本扩展名 */
const EXT_NOTE: string = '.hcnote';

/**
 * 中间态扩展名（T2-1b D-1：单槽 .hcnote.tmp → 双槽 ping-pong .tmp0 / .tmp1）。
 * 命名沿用「{noteId}<后缀>」约定（d1 §4.0 路径事实修订）。
 */
const EXT_TMP_SLOT0: string = '.tmp0';
const EXT_TMP_SLOT1: string = '.tmp1';

/** 旧版单槽中间态扩展名（T2-1b P1 迁移清理用；D-1 修复前可能残留「写后 rename 前被 kill」的完好草稿） */
const EXT_TMP_LEGACY: string = '.hcnote.tmp';

/** 备份扩展名 */
const EXT_BAK: string = '.hcnote.bak';

/** 单篇笔记体积软上限（1.5MB），超出记 warn 但不阻断保存 */
const SIZE_WARN_BYTES: number = 1500 * 1024;

/** 保存结果 */
export interface NoteSaveResult {
  ok: boolean;
  /** 保存后的最新元信息（updatedAt / sizeBytes / strokeCount 已刷新） */
  meta: NoteMeta;
  /** 实际落盘字节数 */
  sizeBytes: number;
  errorMessage: string;
  /**
   * 失败分类（T2-1b C-1 / d1 §10.2.5）：'no_space' | 'no_permission' | 'unknown'。
   * null = 成功。任何非 null 值都代表失败，UI 必须照常报错（绝不因分类失败而静默）。
   */
  failureKind: FsFailureKind | null;
}

/** 写原语结果（T2-1b C-1 / d1 §10.2.6）：携带系统错误码供 classifyFsError 分类 */
interface WriteResult {
  ok: boolean;
  /** BusinessError.code / errno；成功或非 BusinessError 时为 undefined */
  code: number | undefined;
}

/** 草稿读取结果 */
interface DraftReadResult {
  text: string;
  mtime: number;
}

/** 草稿槽信息 */
interface DraftSlotInfo {
  path: string;
  text: string;
  mtime: number;
}

/** 恢复结果 */
export interface RecoverResult {
  ok: boolean;
  errorMessage: string;
}

export class NoteRepository {
  private context: common.Context | null = null;
  private indexStore: INoteIndexStore;
  private notesDir: string = '';
  private thumbsDir: string = '';
  /** 资产目录绝对路径（notes/assets） */
  private _assetsDir: string = '';
  private ready: boolean = false;
  /** ENG-04：文件夹映射存储适配器（board.json + meta.json + resources/） */
  private folderStore: FolderMappingStore = new FolderMappingStore();
  /** 保存串行链：避免自动保存与手动保存并发写同一文件 */
  private saveChain: Promise<void> = Promise.resolve();
  /**
   * 瞬态「草稿待恢复」集合（T2-1b D-1 / d1 §3.4.2）：存有「校验通过且比正文新」的
   * tmp 槽的 noteId。由 scanPendingTmpNotes / rebuildIndexFromDisk 填充，重启自愈，不写 Preferences。
   */
  private pendingTmpNotes: Set<string> = new Set<string>();

  constructor(indexStore?: INoteIndexStore) {
    this.indexStore = indexStore !== undefined && indexStore !== null ? indexStore : new PrefsNoteIndexStore();
  }

  // ═══════════════════════════════════════════════════════════════
  // 一、初始化
  // ═══════════════════════════════════════════════════════════════

  /**
   * 初始化沙箱目录 + 索引。幂等，可重复调用。
   * 由 EntryAbility.onCreate 通过 NoteEngine.initStorage 触发。
   */
  async init(context: common.Context): Promise<boolean> {
    if (context === null || context === undefined) {
      Logger.error(TAG_MODULE, 'init 失败：context 为空');
      return false;
    }
    if (this.ready && this.context === context) {
      return true;
    }
    this.context = context;
    const filesDir: string = context.filesDir;
    if (filesDir === undefined || filesDir === null || filesDir.length === 0) {
      Logger.error(TAG_MODULE, 'init 失败：filesDir 为空');
      return false;
    }
    this.notesDir = `${filesDir}/${DIR_NOTES}`;
    this.thumbsDir = `${filesDir}/${DIR_THUMBS}`;
    this._assetsDir = `${this.notesDir}/${DIR_ASSETS}`;

    // ENG-04：初始化文件夹映射存储（Notes/<标题>/board.json + meta.json + resources/）
    this.folderStore.init(context);

    const dirOk: boolean = this.ensureDir(this.notesDir) && this.ensureDir(this.thumbsDir) && this.ensureDir(this._assetsDir);
    if (!dirOk) {
      Logger.error(TAG_MODULE, 'init 失败：目录创建失败');
      return false;
    }

    const indexOk: boolean = await this.indexStore.init(context);
    if (!indexOk) {
      Logger.warn(TAG_MODULE, '索引初始化失败，将退化为「每次扫盘」模式');
    }

    this.ready = true;
    Logger.info(TAG_MODULE, `仓储就绪 notesDir=${this.notesDir}`);

    // T2-1b（d1 §3.4.2）：重启自愈——无论索引空否都扫描一遍「校验通过且比正文新」的草稿槽，
    // 填充瞬态 pendingTmpNotes（不写 Preferences）。先于 rebuildIndexFromDisk 执行，避免其内部重复扫描。
    // T2-1b P1：先迁移旧单槽 .hcnote.tmp 孤儿（迁移后 scan 才能识别新 .tmp0）
    this.migrateLegacyTmpSlots();
    this.scanPendingTmpNotes();

    // 索引为空但磁盘有文件 → 自动补建（如卸载重装保留沙箱、或索引损坏）
    const metas: NoteMeta[] = await this.indexStore.listMetas();
    if (metas.length === 0) {
      const rebuilt: number = await this.rebuildIndexFromDisk();
      if (rebuilt > 0) {
        Logger.info(TAG_MODULE, `索引为空，已从磁盘补建 ${rebuilt} 条`);
      }
    }
    // F-04 任务 B+：启动期清理孤儿文档资产目录（filesDir/docs/* 中未被任何笔记引用者）
    await this.cleanupOrphanDocAssets();
    return true;
  }

  isReady(): boolean {
    return this.ready;
  }

  getNotesDir(): string {
    return this.notesDir;
  }

  getThumbsDir(): string {
    return this.thumbsDir;
  }

  // ═══════════════════════════════════════════════════════════════
  // 二、最小写读闭环（T1-3 的第一块基石，也是 A1-1 的底层保证）
  // ═══════════════════════════════════════════════════════════════

  /** 目录存在性保障（不存在则创建），永不抛异常 */
  private ensureDir(dir: string): boolean {
    return SafeAsync.run<boolean>(TAG_MODULE, 'ensureDir', (): boolean => {
      if (fileIo.accessSync(dir)) {
        return true;
      }
      fileIo.mkdirSync(dir);
      return true;
    }, false);
  }

  /** 文件是否存在 */
  private exists(path: string): boolean {
    return SafeAsync.run<boolean>(TAG_MODULE, 'exists', (): boolean => fileIo.accessSync(path), false);
  }

  /**
   * 同步写文本（覆盖式）。
   * 写完立即 fsync，确保断电 / 强杀场景下数据真正落盘（A1-2 的前提）。
   * T2-1b C-1：返回 WriteResult（含 code），供保存链做失败分类。
   */
  private writeTextSync(path: string, text: string): WriteResult {
    const r: DetailedResult<WriteResult> = SafeAsync.runDetailed<WriteResult>(TAG_MODULE, `writeText:${path}`, (): WriteResult => {
      const mode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
      const file: fileIo.File = fileIo.openSync(path, mode);
      try {
        fileIo.writeSync(file.fd, text);
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      return { ok: true, code: undefined };
    }, { ok: false, code: undefined });
    return r.value;   // runDetailed 返回 {value,error} 包装，解包 .value（P0 修复）
  }

  /** 同步读文本，失败或不存在返回空串 */
  private readTextSync(path: string): string {
    return SafeAsync.run<string>(TAG_MODULE, `readText:${path}`, (): string => {
      if (!fileIo.accessSync(path)) {
        return '';
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      const size: number = stat.size;
      if (size <= 0) {
        return '';
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const arrayBuffer: ArrayBuffer = new ArrayBuffer(size);
        const readLen: number = fileIo.readSync(file.fd, arrayBuffer);
        if (readLen <= 0) {
          return '';
        }
        const bytes: Uint8Array = new Uint8Array(arrayBuffer.slice(0, readLen));
        // ArkTS 无全局 TextDecoder，沿用项目既有写法（network/SignalCodec.ets）
        const decoder: util.TextDecoder = new util.TextDecoder();
        return decoder.decodeToString(bytes);
      } finally {
        fileIo.closeSync(file);
      }
    }, '');
  }

  // ─── S2-Cc / T2-5c：二进制写读基础原语（纯追加，不触碰原子写协议/双槽/闸）───

  /** 同步写字节（覆盖式，CRDT 快照 / 资产二进制用）。失败返回 false */
  private writeBytesSync(path: string, bytes: Uint8Array): boolean {
    const r: DetailedResult<boolean> = SafeAsync.runDetailed<boolean>(TAG_MODULE, `writeBytes:${path}`, (): boolean => {
      const mode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC;
      const file: fileIo.File = fileIo.openSync(path, mode);
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    }, false);
    return r.value;
  }

  /** 同步读字节；不存在或失败返回空 Uint8Array（绝不抛异常） */
  private readBytesSync(path: string): Uint8Array {
    return SafeAsync.run<Uint8Array>(TAG_MODULE, `readBytes:${path}`, (): Uint8Array => {
      if (!fileIo.accessSync(path)) {
        return new Uint8Array(0);
      }
      const stat: fileIo.Stat = fileIo.statSync(path);
      const size: number = stat.size;
      if (size <= 0) {
        return new Uint8Array(0);
      }
      const file: fileIo.File = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      try {
        const arrayBuffer: ArrayBuffer = new ArrayBuffer(size);
        const readLen: number = fileIo.readSync(file.fd, arrayBuffer);
        if (readLen <= 0) {
          return new Uint8Array(0);
        }
        return new Uint8Array(arrayBuffer.slice(0, readLen));
      } finally {
        fileIo.closeSync(file);
      }
    }, new Uint8Array(0));
  }

  /** 追加文本到文件（oplog append-only；不存在则创建）。失败返回 false */
  private appendTextSync(path: string, text: string): boolean {
    const r: DetailedResult<boolean> = SafeAsync.runDetailed<boolean>(TAG_MODULE, `append:${path}`, (): boolean => {
      const mode: number = fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND;
      const file: fileIo.File = fileIo.openSync(path, mode);
      try {
        fileIo.writeSync(file.fd, text);
        fileIo.fsyncSync(file.fd);
      } finally {
        fileIo.closeSync(file);
      }
      return true;
    }, false);
    return r.value;
  }

  /** 删除文件（不存在视为成功） */
  private removeSync(path: string): boolean {
    return SafeAsync.run<boolean>(TAG_MODULE, `remove:${path}`, (): boolean => {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
      return true;
    }, false);
  }

  /** 复制文件（T2-1b C-1：返回 WriteResult 供失败分类） */
  private copySync(src: string, dest: string): WriteResult {
    const r: DetailedResult<WriteResult> = SafeAsync.runDetailed<WriteResult>(TAG_MODULE, `copy:${src}`, (): WriteResult => {
      fileIo.copyFileSync(src, dest);
      return { ok: true, code: undefined };
    }, { ok: false, code: undefined });
    return r.value;   // runDetailed 返回 {value,error} 包装，解包 .value（P0 修复）
  }

  /**
   * 重命名（覆盖式）。
   * POSIX rename 对同目录已存在的目标是原子覆盖；
   * 若底层实现拒绝覆盖（EXDEV / EACCES / EROFS / ENOSPC 等），退化为「先复制后删源」。
   * T2-1b C-1（d1 §10.2.6）：返回 WriteResult（含 code）供 doSave 失败分类。
   */
  private renameSync(src: string, dest: string): WriteResult {
    const r: DetailedResult<WriteResult> = SafeAsync.runDetailed<WriteResult>(TAG_MODULE, 'rename', (): WriteResult => {
      fileIo.renameSync(src, dest);
      return { ok: true, code: undefined };
    }, { ok: false, code: undefined });
    const direct: WriteResult = r.value;   // runDetailed 返回 {value,error} 包装，解包 .value（P0 修复）
    if (direct.ok) {
      return { ok: true, code: undefined };
    }
    // E-1 修复：rename 覆盖失败可能因 ENOSPC / EACCES / EROFS / EXDEV 等持久性原因，
    // 而非「目标已存在」。若先删正本再改名，失败时会把用户正本删没、新内容又没落位 → 数据丢失。
    // 改用「先复制后删源」：copyFileSync 本身是覆盖写，失败时 dest 保持原样（旧的有效正本），
    // 仅在复制成功后才清理中间态 src，任何一步失败 dest 都保有有效内容。
    //
    // E-2 防御：非原子「复制覆盖」中途若再遇 ENOSPC 截断，dest 会被写坏且**不可回滚**。
    // 因此仅在「dest 不存在（新建，无旧内容可损）」或「.bak 已存在（旧内容可回滚）」
    // 时才执行非原子覆盖写；否则拒绝执行，保留原 dest（旧的有效正本），令本次保存失败
    // 而非用坏文件覆盖用户数据（与 t2-repository.mjs V2「[E-2 判定]」一致）。
    const bakPath: string = `${dest}.bak`;
    const safeToOverwrite: boolean = !this.exists(dest) || this.exists(bakPath);
    if (!safeToOverwrite) {
      Logger.warn(TAG_MODULE, 'rename 覆盖失败且 .bak 缺失，拒绝非原子覆盖写以保全正本');
      return { ok: false, code: direct.code };
    }
    Logger.warn(TAG_MODULE, 'rename 覆盖失败，退化为「先复制后删源」');
    const fb: DetailedResult<WriteResult> = SafeAsync.runDetailed<WriteResult>(TAG_MODULE, 'renameFallback', (): WriteResult => {
      fileIo.copyFileSync(src, dest);   // 覆盖式复制；失败则 dest 保持原内容不变
      fileIo.unlinkSync(src);           // 仅在复制成功后清理中间态
      return { ok: true, code: undefined };  // 数据已借 copyFileSync 安全落位正本，向上报提交成功
    }, { ok: false, code: direct.code });
    return fb.value;   // runDetailed 返回 {value,error} 包装，解包 .value（P0 修复）
  }

  /** 文件字节数（失败返回 0） */
  private sizeOf(path: string): number {
    return SafeAsync.run<number>(TAG_MODULE, 'sizeOf', (): number => {
      if (!fileIo.accessSync(path)) {
        return 0;
      }
      return fileIo.statSync(path).size;
    }, 0);
  }

  /**
   * 最小写读闭环自检（T1-3 验收项 A1-1 的冒烟测试）。
   * 在 tests/S1NoteTest 与 NoteEngine.initStorage 之后均可调用。
   * @returns 空串表示通过；否则返回失败原因
   */
  async selfTest(): Promise<string> {
    if (!this.ready) {
      return '仓储未初始化';
    }
    const probe: string = `${this.notesDir}/.probe_${Date.now()}.txt`;
    const payload: string = '鸿绘 fileIo probe ✓';
    if (!this.writeTextSync(probe, payload).ok) {
      return '写入探针文件失败';
    }
    const readBack: string = this.readTextSync(probe);
    this.removeSync(probe);
    if (readBack !== payload) {
      return `读回内容不一致（期望 ${payload.length} 字符，实际 ${readBack.length} 字符）`;
    }
    Logger.info(TAG_MODULE, 'fileIo 最小写读闭环自检通过');
    return '';
  }

  // ═══════════════════════════════════════════════════════════════
  // 三、路径工具
  // ═══════════════════════════════════════════════════════════════

  private notePath(noteId: string): string {
    return `${this.notesDir}/${noteId}${EXT_NOTE}`;
  }

  /** 草稿槽 0（d1 §4.0：{noteId}.tmp0） */
  private tmpSlot0Path(noteId: string): string {
    return `${this.notesDir}/${noteId}${EXT_TMP_SLOT0}`;
  }

  /** 草稿槽 1（d1 §4.0：{noteId}.tmp1） */
  private tmpSlot1Path(noteId: string): string {
    return `${this.notesDir}/${noteId}${EXT_TMP_SLOT1}`;
  }

  /** 两草稿槽路径 */
  private tmpSlotPaths(noteId: string): string[] {
    return [this.tmpSlot0Path(noteId), this.tmpSlot1Path(noteId)];
  }

  private bakPath(noteId: string): string {
    return `${this.notesDir}/${noteId}${EXT_BAK}`;
  }

  private thumbPath(noteId: string): string {
    return `${this.thumbsDir}/${noteId}.txt`;
  }

  /** 文件 mtime（毫秒）；不存在或读取失败返回 0（闸 B 比较用） */
  private mtimeOf(path: string): number {
    return SafeAsync.run<number>(TAG_MODULE, 'mtimeOf', (): number => {
      if (!fileIo.accessSync(path)) {
        return 0;
      }
      return fileIo.statSync(path).mtime;
    }, 0);
  }

  // ═══════════════════════════════════════════════════════════════
  // 四、列表 / 新建 / 删除 / 重命名
  // ═══════════════════════════════════════════════════════════════

  /** 笔记列表（按 updatedAt 倒序） */
  async listNotes(): Promise<NoteMeta[]> {
    if (!this.ready) {
      Logger.warn(TAG_MODULE, 'listNotes：仓储未就绪，返回空列表');
      return [];
    }
    return await this.indexStore.listMetas();
  }

  /**
   * 新建笔记：立刻落一个空文件 + 写索引。
   * 这样「列表里出现的每一条，点开一定打得开」（S-6 的直接收益）。
   */
  async createNote(title: string, paperTemplate: string): Promise<NoteMeta> {
    const id: string = createNoteId();
    const template: string = NoteSerializer.normalizePaperTemplate(paperTemplate);
    const meta: NoteMeta = createNoteMeta(id, title, template);
    if (!this.ready) {
      Logger.warn(TAG_MODULE, 'createNote：仓储未就绪，仅返回内存 meta');
      return meta;
    }
    const content: NoteContent = createEmptyNoteContent(id, meta.title, template);
    content.meta = meta;
    const result: NoteSaveResult = await this.saveNote(content, false);
    if (!result.ok) {
      Logger.error(TAG_MODULE, `createNote 落盘失败: ${result.errorMessage}`);
    }
    return result.ok ? result.meta : meta;
  }

  /** 删除笔记：正本 + 双槽 tmp + bak + 缩略图 + 索引 + pendingTmpNotes 内存态（d1 §7）
   *  S2-Cc / T2-5c 追加：oplog / crdt.json / crdt.json.tmp / 资产 .part 瞬态（t25 §4.1 清理清单纯追加） */
  async deleteNote(noteId: string): Promise<boolean> {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    // F-04 任务 B+：删笔记时一并清理其文档资产目录 filesDir/docs/{docId}（避免孤儿目录）
    this.removeNoteDocAssets(noteId);
    this.removeSync(this.notePath(noteId));
    this.removeBothTmpSlots(noteId);
    this.removeSync(this.bakPath(noteId));
    this.removeSync(this.thumbPath(noteId));
    // S2-Cc：CRDT 辅助文件清理（纯追加，不触碰 d1 已锁条文）
    this.removeSync(this.opLogPath(noteId));
    this.removeSync(this.crdtPath(noteId));
    this.removeSync(`${this.crdtPath(noteId)}.tmp`);
    this.pendingTmpNotes.delete(noteId);
    const ok: boolean = await this.indexStore.removeMeta(noteId);
    Logger.info(TAG_MODULE, `删除笔记 ${noteId} ${ok ? '成功' : '（索引未同步）'}`);
    return ok;
  }

  // ─── F-04 任务 B+：文档源资产（filesDir/docs/{docId}/source.pdf）清理 ───

  /** 文档资产根目录（filesDir/docs，与 notes/thumbs 平级） */
  private docAssetsRoot(): string {
    if (this.context === null || this.context === undefined) {
      return '';
    }
    const filesDir: string = this.context.filesDir;
    if (filesDir === undefined || filesDir === null || filesDir.length === 0) {
      return '';
    }
    return `${filesDir}/docs`;
  }

  /** 删除单个文档资产目录（递归）；不存在或失败均静默忽略 */
  private removeDocAssetDir(docId: string): void {
    if (docId.length === 0) {
      return;
    }
    const dir: string = `${this.docAssetsRoot()}/${docId}`;
    SafeAsync.runVoid(TAG_MODULE, 'removeDocAssetDir', (): void => {
      if (fileIo.accessSync(dir)) {
        // @ohos.file.fs 的 rmdirSync 只接 1 个参数，本身即递归删除
        fileIo.rmdirSync(dir);
      }
    });
  }

  /** 解析某篇笔记的文档列表，逐个删除其资产目录（删笔记时调用） */
  private removeNoteDocAssets(noteId: string): void {
    if (!this.ready || noteId.length === 0) {
      return;
    }
    const text: string = this.readTextSync(this.notePath(noteId));
    if (text.length === 0) {
      return;
    }
    const parsed = NoteSerializer.deserialize(text, noteId);
    if (!parsed.ok) {
      return;
    }
    const docs = parsed.content.docs;
    for (let i = 0; i < docs.length; i++) {
      this.removeDocAssetDir(docs[i].docId);
    }
  }

  /**
   * 启动期孤儿清理：扫描 filesDir/docs/*，删除未被任何笔记引用的目录。
   * 兜底处理「笔记 .hcnote 已删但资产目录残留」「某文档从笔记移除却未删目录」等异常路径。
   */
  private async cleanupOrphanDocAssets(): Promise<void> {
    if (!this.ready) {
      return;
    }
    const root: string = this.docAssetsRoot();
    if (root.length === 0 || !fileIo.accessSync(root)) {
      return;
    }
    // 1) 收集所有笔记引用到的 docId
    const referenced: Set<string> = new Set<string>();
    const metas: NoteMeta[] = await this.indexStore.listMetas();
    for (let i = 0; i < metas.length; i++) {
      const text: string = this.readTextSync(this.notePath(metas[i].id));
      if (text.length === 0) {
        continue;
      }
      const parsed = NoteSerializer.deserialize(text, metas[i].id);
      if (!parsed.ok) {
        continue;
      }
      const docs = parsed.content.docs;
      for (let j = 0; j < docs.length; j++) {
        if (docs[j].docId.length > 0) {
          referenced.add(docs[j].docId);
        }
      }
    }
    // 2) 删除未被引用的孤儿目录
    const entries: string[] = SafeAsync.run<string[]>(TAG_MODULE, 'listDocAssets',
      (): string[] => fileIo.listFileSync(root), []);
    for (let k = 0; k < entries.length; k++) {
      if (!referenced.has(entries[k])) {
        this.removeDocAssetDir(entries[k]);
      }
    }
    Logger.info(TAG_MODULE, `孤儿文档资产清理完成：保留 ${referenced.size} 个，扫描 ${entries.length} 个目录`);
  }

  // ═══════════════════════════════════════════════════════════════
  // 四·补、未提交草稿双槽管理（T2-1b D-1：四级回退 L3 + 闸 A/B）
  //
  // ⚠️ 本段为**独立新增**，与 doSave 第②/④步、loadNote L3、deleteNote 配套；
  //    两档口径必须分开实现、禁止共用一套条件（d1 §4.1）：
  //    抢救档（L3/recoverTmp）= 仅校验通过 + mtime 最新，**不加闸 B**；
  //    提示档（hasPendingTmp）= 校验通过 + mtime > main.mtime（闸 B）。
  // ═══════════════════════════════════════════════════════════════

  /** 读取 + 校验单个草稿槽（抢救档判定：deserialize.ok && checksumMatched） */
  private readValidDraft(slotPath: string, noteId: string): DraftReadResult | null {
    const text: string = this.readTextSync(slotPath);
    if (text.length === 0) {
      return null;
    }
    const parsed: NoteDeserializeResult = NoteSerializer.deserialize(text, noteId);
    if (!parsed.ok || !parsed.checksumMatched) {
      return null;
    }
    const result: DraftReadResult = { text: text, mtime: this.mtimeOf(slotPath) };
    return result;
  }

  /** 最佳草稿槽（抢救档：校验通过 + mtime 最新）；无有效草稿返回 null */
  private bestDraftSlot(noteId: string): DraftSlotInfo | null {
    let best: DraftSlotInfo | null = null;
    const slots: string[] = this.tmpSlotPaths(noteId);
    for (let i = 0; i < slots.length; i++) {
      const draft: DraftReadResult | null = this.readValidDraft(slots[i], noteId);
      if (draft !== null && (best === null || draft.mtime > best.mtime)) {
        const slotInfo: DraftSlotInfo = { path: slots[i], text: draft.text, mtime: draft.mtime };
        best = slotInfo;
      }
    }
    return best;
  }

  /**
   * 写选槽（d1 §4.1）：选择「当前非最佳草稿槽」写入。
   * 两槽均无有效草稿 → 写 mtime 较旧 / 缺失者（默认 tmp0 优先）；
   * 一槽有效 → 写另一槽（核心不变量：写入目标 ≠ 当前最佳草稿槽）。
   */
  private selectWriteSlot(noteId: string): string {
    const slot0: string = this.tmpSlot0Path(noteId);
    const slot1: string = this.tmpSlot1Path(noteId);
    const best: DraftSlotInfo | null = this.bestDraftSlot(noteId);
    if (best === null) {
      const m0: number = this.mtimeOf(slot0);
      const m1: number = this.mtimeOf(slot1);
      return m0 <= m1 ? slot0 : slot1;
    }
    return best.path === slot0 ? slot1 : slot0;
  }

  /** 清两槽（闸 A / discardTmp 同构）：不论校验是否通过，一律 removeSync */
  private removeBothTmpSlots(noteId: string): void {
    const slots: string[] = this.tmpSlotPaths(noteId);
    for (let i = 0; i < slots.length; i++) {
      this.removeSync(slots[i]);
    }
  }

  /**
   * v2.6.0 审核修复（问题⑤「筛选笔记无响应」）：
   *   列表索引（NoteMeta）没有闪卡/导图计数，导致「闪卡 / 导图」两个筛选页签
   *   在数据模型层面无从过滤，只能退化成"展示全部" → 用户点击后毫无变化。
   *   这里提供一个**只读**的轻量探测：直接扫正本 JSON 文本，
   *   判断 flashcards / mindmaps 是否为非空数组（序列化恒为 `"flashcards":[]`）。
   *   不解析 JSON、不写盘、不改 schema，避免触碰「幂等三原则」。
   * @returns 位标志：1 = 含闪卡，2 = 含思维导图，0 = 均无
   */
  peekContentFlags(noteId: string): number {
    if (!this.ready || noteId.length === 0) {
      return 0;
    }
    const text: string = this.readTextSync(this.notePath(noteId));
    if (text.length === 0) {
      return 0;
    }
    let flags: number = 0;
    if (text.indexOf('"flashcards":[') >= 0 && text.indexOf('"flashcards":[]') < 0) {
      flags |= 1;
    }
    // 🔧 v2.7.0：导图判定必须"含子节点"。
    //   历史实现无条件写入 [默认导图]（仅一个「中心主题」根节点），
    //   导致每篇笔记都被判为"含导图"，「导图」筛选退化成"全部"。
    //   序列化后根节点形如 "parentId":""，子节点形如 "parentId":"n_xxx"，
    //   故只要存在「parentId 后不是引号」的节点即视为真实导图。
    if (text.indexOf('"mindmaps":[') >= 0 && text.indexOf('"mindmaps":[]') < 0
        && NoteRepository.hasNestedMindNode(text)) {
      flags |= 2;
    }
    return flags;
  }

  /** 判断 mindmaps 段中是否存在带非空 parentId 的节点（即真实建过导图） */
  private static hasNestedMindNode(text: string): boolean {
    const KEY: string = '"parentId":"';
    let from: number = 0;
    while (true) {
      const at: number = text.indexOf(KEY, from);
      if (at < 0) {
        return false;
      }
      const valueStart: number = at + KEY.length;
      if (valueStart < text.length && text.charAt(valueStart) !== '"') {
        return true;   // parentId 非空 → 存在子节点
      }
      from = valueStart;
    }
  }

  /**
   * 是否存在「校验通过且比正文新」的未提交草稿（提示档，d1 §4.3 / §4.5 闸 B）。
   * hasPendingTmp = 存在任一槽满足 (deserialize.ok && checksumMatched && 该槽 mtime > main.mtime)。
   * 提交成功会刷新 main.mtime（rename 落位），故残留旧槽 mtime 更旧 → 不亮（闸 B 兜底闸 A 清理失败）。
   */
  hasPendingTmp(noteId: string): boolean {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    const mainMtime: number = this.mtimeOf(this.notePath(noteId));
    const slots: string[] = this.tmpSlotPaths(noteId);
    for (let i = 0; i < slots.length; i++) {
      const draft: DraftReadResult | null = this.readValidDraft(slots[i], noteId);
      if (draft !== null && draft.mtime > mainMtime) {
        return true;
      }
    }
    return false;
  }

  /** 最佳草稿槽 mtime（提示条时间锚点）；无有效草稿返回 0 */
  tmpDraftMtime(noteId: string): number {
    if (!this.ready || noteId.length === 0) {
      return 0;
    }
    const best: DraftSlotInfo | null = this.bestDraftSlot(noteId);
    return best !== null ? best.mtime : 0;
  }

  /**
   * 读取最佳草稿内容（只读不消费；C-8「查看草稿」用，不写盘、不 rename）。
   * 无有效草稿（校验不过 / 不存在）返回 null。
   */
  readDraftContent(noteId: string): NoteContent | null {
    if (!this.ready || noteId.length === 0) {
      return null;
    }
    const best: DraftSlotInfo | null = this.bestDraftSlot(noteId);
    if (best === null) {
      return null;
    }
    const parsed: NoteDeserializeResult = NoteSerializer.deserialize(best.text, noteId);
    if (!parsed.ok || !parsed.checksumMatched) {
      return null;
    }
    return parsed.content;
  }

  /**
   * 恢复草稿：最佳草稿槽 → 正本（d1 §3.4.3 三道闸）。
   * 闸一 先校验：只取 deserialize.ok && checksumMatched 的槽（bestDraftSlot 完成）；
   * 闸二 先备份：rename 前 main → bak（复用第③步备份逻辑）；
   * 闸三 失败降级：rename 失败（持久故障 ENOSPC 等）时草稿保留在磁盘，返回失败信息，
   *      UI 引导用户导出留存（草稿内容已由 loadNote L3 / 草稿预览载入内存只读，不依赖本地写权限）。
   */
  async recoverTmp(noteId: string): Promise<RecoverResult> {
    if (!this.ready || noteId.length === 0) {
      const result1: RecoverResult = { ok: false, errorMessage: '存储未就绪' };
      return result1;
    }
    const best: DraftSlotInfo | null = this.bestDraftSlot(noteId);
    if (best === null) {
      const result2: RecoverResult = { ok: false, errorMessage: '未找到可恢复的草稿' };
      return result2;
    }
    const main: string = this.notePath(noteId);
    // 闸二：先备份（main 存在才需要）
    if (this.exists(main)) {
      if (!this.copySync(main, this.bakPath(noteId)).ok) {
        Logger.warn(TAG_MODULE, `recoverTmp 备份失败，仍继续恢复（${noteId}）`);
      }
    }
    // 闸一已在 bestDraftSlot 完成（只取校验通过槽）；闸三：失败时草稿仍在磁盘
    const renamed: WriteResult = this.renameSync(best.path, main);
    if (!renamed.ok) {
      Logger.error(TAG_MODULE, `recoverTmp 恢复失败（${noteId}），草稿保留在磁盘: ${renamed.code}`);
      const result3: RecoverResult = { ok: false, errorMessage: '恢复失败，草稿仍保留在磁盘；建议先导出图片留存当前内容' };
      return result3;
    }
    // 恢复成功：草稿被消费，清两槽 + 内存态
    this.removeBothTmpSlots(noteId);
    this.pendingTmpNotes.delete(noteId);
    Logger.info(TAG_MODULE, `recoverTmp 成功 ${noteId}`);
    const result4: RecoverResult = { ok: true, errorMessage: '' };
    return result4;
  }

  /** 丢弃草稿（d1 §3.4.3）：无条件清两槽（不论校验是否通过）+ 清内存态 */
  discardTmp(noteId: string): boolean {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    this.removeBothTmpSlots(noteId);
    this.pendingTmpNotes.delete(noteId);
    return true;
  }

  /** 扫描全部正本，填充 pendingTmpNotes（闸 B：每个候选槽须校验 + 比正文新）。重启自愈，不写 Preferences。 */
  private scanPendingTmpNotes(): void {
    const next: Set<string> = new Set<string>();
    const files: string[] = SafeAsync.run<string[]>(TAG_MODULE, 'listFile',
      (): string[] => fileIo.listFileSync(this.notesDir), []);
    for (let i = 0; i < files.length; i++) {
      const name: string = files[i];
      if (!NoteRepository.endsWith(name, EXT_NOTE)) {
        continue;
      }
      const noteId: string = name.substring(0, name.length - EXT_NOTE.length);
      if (noteId.length === 0) {
        continue;
      }
      if (this.hasPendingTmp(noteId)) {
        next.add(noteId);
      }
    }
    this.pendingTmpNotes = next;
  }

  /**
   * 孤儿单槽 tmp 迁移清理（T2-1b P1）：旧版本（D-1 修复前）残留的 {id}.hcnote.tmp 单槽文件
   * 不再被双槽识别，升级后永久残留。逐文件判定：
   *  (a) deserialize.ok && checksumMatched && mtime > main.mtime → rename 为 {id}.tmp0，
   *      提升为可识别草稿（继承闸 B 判定与草稿横幅，不丢「写后 rename 前被 kill」的完好草稿）；
   *  (b) 校验失败 或 mtime ≤ main.mtime（陈旧/半截）→ 删除。
   * 只认旧单槽形态（{id}.hcnote.tmp），endsWith 不匹配 .tmp0/.tmp1，不误伤双槽文件。
   * 天然自终止：迁移后旧文件不存在（rename 消费或删除），无需 flag。
   */
  private migrateLegacyTmpSlots(): void {
    const files: string[] = SafeAsync.run<string[]>(TAG_MODULE, 'listFile',
      (): string[] => fileIo.listFileSync(this.notesDir), []);
    for (let i = 0; i < files.length; i++) {
      const name: string = files[i];
      if (!NoteRepository.endsWith(name, EXT_TMP_LEGACY)) {
        continue;
      }
      const legacyPath: string = `${this.notesDir}/${name}`;
      const noteId: string = name.substring(0, name.length - EXT_TMP_LEGACY.length);
      if (noteId.length === 0) {
        this.removeSync(legacyPath);
        continue;
      }
      const text: string = this.readTextSync(legacyPath);
      const parsed: NoteDeserializeResult = NoteSerializer.deserialize(text, noteId);
      const mainMtime: number = this.mtimeOf(this.notePath(noteId));
      const legacyMtime: number = this.mtimeOf(legacyPath);
      if (parsed.ok && parsed.checksumMatched && legacyMtime > mainMtime) {
        // (a) 提升为可识别草稿：目标槽 .tmp0（被占则 .tmp1；两槽都占 → 双槽已接管语义，删最老候选）
        let target: string = this.tmpSlot0Path(noteId);
        if (this.exists(target) && this.exists(this.tmpSlot1Path(noteId))) {
          Logger.warn(TAG_MODULE, `旧单槽 tmp 双槽已占满，按过期删除（${legacyPath}）`);
          this.removeSync(legacyPath);
          continue;
        }
        if (this.exists(target)) {
          target = this.tmpSlot1Path(noteId);
        }
        const renamed: WriteResult = this.renameSync(legacyPath, target);
        if (renamed.ok) {
          Logger.info(TAG_MODULE, `旧单槽 tmp 迁移成功：${name} → 双槽（${noteId}）`);
        } else {
          // 迁移失败（持久故障）不删原文件，下次启动再试（防丢数据优先于自终止）
          Logger.warn(TAG_MODULE, `旧单槽 tmp 迁移失败，保留原文件（${legacyPath}）`);
        }
      } else {
        // (b) 校验失败或陈旧/半截 → 删除
        Logger.warn(TAG_MODULE, `旧单槽 tmp 校验失败或已过期，删除（${legacyPath}）`);
        this.removeSync(legacyPath);
      }
    }
  }

  /** 重命名：读取正本 → 改 title → 原子写回 → 更新索引 */
  async renameNote(noteId: string, newTitle: string): Promise<boolean> {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    const loaded: NoteLoadResult = await this.loadNote(noteId);
    const title: string = normalizeNoteTitle(newTitle, loaded.content.meta.title);
    if (title === loaded.content.meta.title) {
      return true;
    }
    loaded.content.meta.title = title;
    const result: NoteSaveResult = await this.saveNote(loaded.content, true);
    return result.ok;
  }

  // ═══════════════════════════════════════════════════════════════
  // 五、读取（三级回退，永不抛异常）
  // ═══════════════════════════════════════════════════════════════

  async loadNote(noteId: string): Promise<NoteLoadResult> {
    const fallback: NoteContent = createEmptyNoteContent(noteId, '未命名笔记', HC_DEFAULT_PAPER);
    if (!this.ready) {
      const result: NoteLoadResult = {
        ok: false, content: fallback, recoveredFromBak: false, recoveredFromTmp: false,
        hasUncommittedTmp: false, loadWarning: '', errorMessage: '存储未初始化'
      };
      return result;
    }
    if (noteId === undefined || noteId === null || noteId.length === 0) {
      const result: NoteLoadResult = {
        ok: false, content: fallback, recoveredFromBak: false, recoveredFromTmp: false,
        hasUncommittedTmp: false, loadWarning: '', errorMessage: '笔记 id 为空'
      };
      return result;
    }

    // 一级：正本
    const mainText: string = this.readTextSync(this.notePath(noteId));
    if (mainText.length > 0) {
      const parsed: NoteDeserializeResult = NoteSerializer.deserialize(mainText, noteId);
      if (parsed.ok) {
        if (!parsed.checksumMatched) {
          Logger.warn(TAG_MODULE, `${noteId} checksum 不一致，内容按可用处理`);
        }
        // T2-1b（d1 §3.4.1）：正本完好时并行检测「校验通过且比正文新」的未提交草稿（闸 B），只提示不替换
        const hasUncommitted: boolean = this.hasPendingTmp(noteId);
        if (hasUncommitted) {
          Logger.warn(TAG_MODULE, `${noteId} 存在更新的未提交草稿，仅提示不自动替换正文`);
        }
        const result1: NoteLoadResult = {
          ok: true, content: parsed.content, recoveredFromBak: false, recoveredFromTmp: false,
          hasUncommittedTmp: hasUncommitted, loadWarning: parsed.loadWarning, errorMessage: ''
        };
        return result1;
      }
      Logger.error(TAG_MODULE, `${noteId} 正本解析失败（${parsed.errorMessage}），尝试备份`);
    }

    // 二级：备份
    const bakText: string = this.readTextSync(this.bakPath(noteId));
    if (bakText.length > 0) {
      const parsedBak: NoteDeserializeResult = NoteSerializer.deserialize(bakText, noteId);
      if (parsedBak.ok) {
        Logger.warn(TAG_MODULE, `${noteId} 已从备份恢复`);
        const result2: NoteLoadResult = {
          ok: true,
          content: parsedBak.content,
          recoveredFromBak: true,
          recoveredFromTmp: false,
          hasUncommittedTmp: false,
          loadWarning: parsedBak.loadWarning,
          errorMessage: '主文件损坏，已从备份恢复',
        };
        return result2;
      }
      Logger.error(TAG_MODULE, `${noteId} 备份同样不可用（${parsedBak.errorMessage}）`);
    }

    // 三级：未提交草稿（T2-1b D-1 / d1 §3.1 L3）。抢救档：仅取 deserialize.ok && checksumMatched 的槽，
    // 多个有效取 mtime 最新；**不加闸 B**——main 已不可用时 mtime 无意义，强加会把唯一草稿挡在门外。
    const bestDraft: DraftSlotInfo | null = this.bestDraftSlot(noteId);
    // 校验不过的坏槽立即删（A-D1-2：半截 tmp → L3 判失败 → removeSync → L4）
    const slots: string[] = this.tmpSlotPaths(noteId);
    for (let i = 0; i < slots.length; i++) {
      const draft: DraftReadResult | null = this.readValidDraft(slots[i], noteId);
      if (draft === null && this.exists(slots[i])) {
        Logger.warn(TAG_MODULE, `${noteId} 草稿槽 ${slots[i]} 校验失败，删除坏槽`);
        this.removeSync(slots[i]);
      }
    }
    if (bestDraft !== null) {
      const parsedDraft: NoteDeserializeResult = NoteSerializer.deserialize(bestDraft.text, noteId);
      if (parsedDraft.ok && parsedDraft.checksumMatched) {
        Logger.warn(TAG_MODULE, `${noteId} 已从未提交草稿恢复（L3）`);
        const result3: NoteLoadResult = {
          ok: true,
          content: parsedDraft.content,
          recoveredFromBak: false,
          recoveredFromTmp: true,
          hasUncommittedTmp: false,
          loadWarning: parsedDraft.loadWarning,
          errorMessage: '主文件与备份均不可用，已从未提交草稿恢复',
        };
        return result3;
      }
    }

    // 四级：空笔记兜底——绝不把异常抛给 UI（S-5）
    const indexMeta: NoteMeta | null = await this.indexStore.getMeta(noteId);
    if (indexMeta !== null) {
      fallback.meta = indexMeta;
      fallback.paper.template = NoteSerializer.normalizePaperTemplate(indexMeta.paperTemplate);
      fallback.paper.backgroundColor = HC_DEFAULT_BACKGROUND;
    }
    const missing: boolean = !this.exists(this.notePath(noteId));
    const message: string = missing ? '笔记文件不存在，已新建空白内容' : '笔记文件损坏，已加载空白内容';
    Logger.error(TAG_MODULE, `${noteId} ${message}`);
    const result4: NoteLoadResult = {
      ok: false, content: fallback, recoveredFromBak: false, recoveredFromTmp: false,
      hasUncommittedTmp: false, loadWarning: '', errorMessage: message
    };
    return result4;
  }

  // ═══════════════════════════════════════════════════════════════
  // 六、保存（原子写 + 索引联动）
  // ═══════════════════════════════════════════════════════════════

  /**
   * 保存笔记。
   *
   * @param content        内存态内容（坐标会被量化回写）
   * @param bumpUpdatedAt  是否刷新 updatedAt。
   *        ⚠️ 无实质变更的重复保存必须传 false，否则 A1-7「二次保存字节一致」不成立。
   */
  async saveNote(content: NoteContent, bumpUpdatedAt: boolean): Promise<NoteSaveResult> {
    return this.enqueueSave((): Promise<NoteSaveResult> => this.doSave(content, bumpUpdatedAt));
  }

  /** 把保存动作挂到串行链尾，避免并发写同一文件 */
  private enqueueSave(action: () => Promise<NoteSaveResult>): Promise<NoteSaveResult> {
    return new Promise<NoteSaveResult>((resolve: (v: NoteSaveResult) => void): void => {
      this.saveChain = this.saveChain.then(async (): Promise<void> => {
        try {
          resolve(await action());
        } catch (error) {
          const message: string = SafeAsync.describe(error as Error);
          Logger.error(TAG_MODULE, `保存链异常: ${message}`);
          resolve({
            ok: false,
            meta: createNoteMeta(createNoteId(), '未命名笔记', HC_DEFAULT_PAPER),
            sizeBytes: 0,
            errorMessage: message,
            failureKind: 'unknown',
          });
        }
      });
    });
  }

  private async doSave(content: NoteContent, bumpUpdatedAt: boolean): Promise<NoteSaveResult> {
    if (!this.ready) {
      return {
        ok: false, meta: content.meta, sizeBytes: 0, errorMessage: '存储未初始化', failureKind: 'unknown'
      };
    }
    const noteId: string = content.meta.id;
    if (noteId.length === 0) {
      return {
        ok: false, meta: content.meta, sizeBytes: 0, errorMessage: '笔记 id 为空', failureKind: 'unknown'
      };
    }
    if (bumpUpdatedAt) {
      content.meta.updatedAt = Date.now();
    }
    if (content.meta.createdAt <= 0) {
      content.meta.createdAt = content.meta.updatedAt > 0 ? content.meta.updatedAt : Date.now();
    }

    // ① 序列化（此处完成 2 位量化 + 回写内存）
    const text: string = SafeAsync.run<string>(TAG_MODULE, 'serialize',
      (): string => NoteSerializer.serialize(content), '');
    if (text.length === 0) {
      return {
        ok: false, meta: content.meta, sizeBytes: 0, errorMessage: '序列化失败', failureKind: 'unknown'
      };
    }

    const main: string = this.notePath(noteId);
    const bak: string = this.bakPath(noteId);
    // T2-1b 双槽（d1 §4.1）：写入目标恒非当前最佳草稿槽 → 任何一次写入（含失败）都不销毁另一槽的完好草稿
    const writeSlot: string = this.selectWriteSlot(noteId);

    // ② 写中间态（非最佳草稿槽）
    const writeRes: WriteResult = this.writeTextSync(writeSlot, text);
    if (!writeRes.ok) {
      // d1 §4.2：坏槽立即删——该槽已知是坏的（写一半失败），删它零成本（好副本在隔壁）、
      // 留着只会让 hasPendingTmp() 误报「有未提交草稿」骗用户。
      this.removeSync(writeSlot);
      return {
        ok: false, meta: content.meta, sizeBytes: 0, errorMessage: '写入临时文件失败',
        failureKind: classifyFsError(writeRes.code)
      };
    }

    // ③ 正本存在则先备份（备份失败只告警，不阻断）。
    // 说明：E-1 根因「第④步删除正本」已由 renameSync 回退（copyFileSync，永不删除 dest）消除；
    // 此处保持「告警+继续」与 t2-repository.mjs「备份失败仍提交保存（不阻断）」一致——
    // 因为只要第④步走**原子 rename** 成功，dest 即被完整替换，.bak 缺失不影响安全性。
    // 真正的风险仅在「rename 失败被迫走非原子 copyFileSync」时：该路径已由 renameSync 内部的
    // 「.bak 缺失则拒绝覆盖写」守卫拦截（见 E-2 防御），故备份缺失不再导致数据丢失。
    if (this.exists(main)) {
      if (!this.copySync(main, bak).ok) {
        Logger.warn(TAG_MODULE, `${noteId} 备份失败，仍继续提交本次保存`);
      }
    }

    // ④ 提交：草稿槽 → 正本
    const renameRes: WriteResult = this.renameSync(writeSlot, main);
    if (!renameRes.ok) {
      // D-1 修复（d1 §2 Q1）：提交失败**保留 tmp 不删除**——该槽是用户最新编辑的唯一完整副本，
      // 按 S-5 四级回退与 UI 草稿提示处理；删除它只会斩断回退路径、无任何收益。
      return {
        ok: false, meta: content.meta, sizeBytes: 0, errorMessage: '提交临时文件失败',
        failureKind: classifyFsError(renameRes.code)
      };
    }

    // 闸 A（d1 §4.5）：提交成功 = 正文已含全部内容，任何残留草稿均已过期、一律作废；
    // 成功路径须 removeSync 两槽——被 rename 消费的（已不存在）+ 显式清理的另一槽。
    this.removeBothTmpSlots(noteId);

    // ⑤ 实际体积以磁盘为准（中文标题下字符数≠字节数）
    const bytes: number = this.sizeOf(main);
    content.meta.sizeBytes = bytes > 0 ? bytes : text.length;
    if (content.meta.sizeBytes > SIZE_WARN_BYTES) {
      Logger.warn(TAG_MODULE, `${noteId} 体积 ${content.meta.sizeBytes}B 超过软上限，建议拆分`);
    }

    // ⑥ 最后更新索引（S-6：内容先于索引）
    const indexOk: boolean = await this.indexStore.upsertMeta(content.meta);
    if (!indexOk) {
      Logger.warn(TAG_MODULE, `${noteId} 内容已落盘但索引更新失败，下次启动会自动补建`);
    }

    Logger.info(TAG_MODULE, `保存成功 ${noteId} strokes=${content.meta.strokeCount} bytes=${content.meta.sizeBytes}`);
    return { ok: true, meta: content.meta, sizeBytes: content.meta.sizeBytes, errorMessage: '', failureKind: null };
  }

  // ═══════════════════════════════════════════════════════════════
  // 七、缩略图（独立文本文件，避免撑大 `.hcnote`）
  // ═══════════════════════════════════════════════════════════════

  /** 保存缩略图 dataURL；空串视为清除 */
  async saveThumb(noteId: string, dataUrl: string): Promise<boolean> {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    if (dataUrl === undefined || dataUrl === null || dataUrl.length === 0) {
      return this.removeSync(this.thumbPath(noteId));
    }
    return this.writeTextSync(this.thumbPath(noteId), dataUrl).ok;
  }

  /** 读取缩略图 dataURL；不存在返回空串（列表页据此显示占位图） */
  async loadThumb(noteId: string): Promise<string> {
    if (!this.ready || noteId.length === 0) {
      return '';
    }
    return this.readTextSync(this.thumbPath(noteId));
  }

  // ═══════════════════════════════════════════════════
  // 七·补、资产存储（T2-1 文档批注页）
  //
  // ⚠️ 本段为**独立新增方法**，与 doSave / renameSync / 备份回退逻辑**零耦合**：
  //    仅复用既有 writeTextSync / readTextSync / ensureDir 基础原语，
  //    不触碰原子写序列、三级回退与 .bak 机制（E-1 / E-2 验收不被污染）。
  //    资产统一落 notes/assets/{hash}，与笔记正本 / 缩略图目录平级。
  // ═══════════════════════════════════════════════════

  /** 资产目录绝对路径（notes/assets）；未初始化时返回空串 */
  assetsDir(): string {
    return this._assetsDir;
  }

  /**
   * 写入一份资产（以 hash 为文件名，落 notes/assets/{hash}）。
   * @param hash    资产标识（建议内容哈希，调用方负责生成与去重）
   * @param content 资产文本（文档源片段 / 批注缩略图 dataURL 等）
   * @returns 是否写入成功
   */
  saveAsset(hash: string, content: string): boolean {
    if (!this.ready || hash.length === 0) {
      Logger.warn(TAG_MODULE, 'saveAsset：仓储未就绪或 hash 为空，跳过');
      return false;
    }
    const path: string = `${this._assetsDir}/${hash}`;
    return this.writeTextSync(path, content).ok;
  }

  /**
   * 读取一份资产（notes/assets/{hash}）。
   * @param hash 资产标识
   * @returns 资产文本；不存在或失败返回空串（绝不抛异常）
   */
  readAsset(hash: string): string {
    if (!this.ready || hash.length === 0) {
      return '';
    }
    const path: string = `${this.assetsDir}/${hash}`;
    return this.readTextSync(path);
  }

  /** 资产是否存在 */
  assetExists(hash: string): boolean {
    if (!this.ready || hash.length === 0) {
      return false;
    }
    return this.exists(`${this._assetsDir}/${hash}`);
  }

  // ─── S2-Cc / T2-5c：资产二进制 + oplog/快照（纯追加，冻结区零触碰）───

  /**
   * 写入二进制资产（t25 §2.3：分片收齐 + FNV-1a 复核后 rename 到 assets/{hash}）。
   * @returns 是否写入成功
   */
  saveAssetBytes(hash: string, bytes: Uint8Array): boolean {
    if (!this.ready || hash.length === 0 || bytes === undefined || bytes === null || bytes.length === 0) {
      return false;
    }
    return this.writeBytesSync(`${this._assetsDir}/${hash}`, bytes);
  }

  /** 读取二进制资产；不存在或失败返回空 Uint8Array（绝不抛异常） */
  readAssetBytes(hash: string): Uint8Array {
    if (!this.ready || hash.length === 0) {
      return new Uint8Array(0);
    }
    return this.readBytesSync(`${this._assetsDir}/${hash}`);
  }

  /** oplog 文件路径（t25 §3.1：{noteId}.oplog.jsonl） */
  private opLogPath(noteId: string): string {
    return `${this.notesDir}/${noteId}.oplog.jsonl`;
  }

  /** CRDT 快照文件路径（{noteId}.crdt.json） */
  private crdtPath(noteId: string): string {
    return `${this.notesDir}/${noteId}.crdt.json`;
  }

  /**
   * 追加一条 op 到 oplog（append-only + fsync；t25 §3.1）。
   * 失败返回 false——调用方（enqueueSave 链）只 warn 不阻断 .hcnote 提交（t25 §4.3：oplog 失败不触发闸 A）。
   */
  appendOpLog(noteId: string, opLine: string): boolean {
    if (!this.ready || noteId.length === 0 || opLine === undefined || opLine.length === 0) {
      return false;
    }
    return this.appendTextSync(this.opLogPath(noteId), opLine);
  }

  /** 读取 oplog 全文（逐行 JSONL；不存在返回空串） */
  readOpLog(noteId: string): string {
    if (!this.ready || noteId.length === 0) {
      return '';
    }
    return this.readTextSync(this.opLogPath(noteId));
  }

  /**
   * 打 CRDT 快照：写 {noteId}.crdt.json（轻量原子写：tmp → rename，不走双槽/闸 A/B）
   * 并截断 oplog（保留快照后新 op = 空，因调用方先写快照再清）。
   * @returns 是否成功
   */
  compactCrdtSnapshot(noteId: string, snapshotJson: string): boolean {
    if (!this.ready || noteId.length === 0 || snapshotJson.length === 0) {
      return false;
    }
    const finalPath: string = this.crdtPath(noteId);
    const tmpPath: string = `${finalPath}.tmp`;
    if (!this.writeTextSync(tmpPath, snapshotJson).ok) {
      return false;
    }
    const renamed: WriteResult = this.renameSync(tmpPath, finalPath);
    if (!renamed.ok) {
      return false;
    }
    // 快照成功后截断 oplog（覆盖为空）
    this.writeTextSync(this.opLogPath(noteId), '').ok;
    return true;
  }

  /** oplog 是否存在（快照阈值判断用） */
  opLogExists(noteId: string): boolean {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    return this.exists(this.opLogPath(noteId));
  }

  /** oplog 体积（字节；不存在返回 0，快照阈值判断用） */
  opLogSize(noteId: string): number {
    if (!this.ready || noteId.length === 0) {
      return 0;
    }
    return this.sizeOf(this.opLogPath(noteId));
  }

  // ═══════════════════════════════════════════════════════════════
  // 八、索引重建（磁盘为准）
  // ═══════════════════════════════════════════════════════════════

  /**
   * 扫描 notes 目录，把每个 `.hcnote` 的 meta 段读出来重建索引。
   * 触发时机：① 首次启动索引为空；② 用户在设置里点「修复笔记列表」。
   * @returns 重建的条目数
   */
  async rebuildIndexFromDisk(): Promise<number> {
    if (!this.ready) {
      return 0;
    }
    const files: string[] = SafeAsync.run<string[]>(TAG_MODULE, 'listFile',
      (): string[] => fileIo.listFileSync(this.notesDir), []);
    const metas: NoteMeta[] = [];
    for (let i = 0; i < files.length; i++) {
      const name: string = files[i];
      // 只认正本，跳过 .tmp / .bak / 探针文件
      if (!NoteRepository.endsWith(name, EXT_NOTE)) {
        continue;
      }
      const noteId: string = name.substring(0, name.length - EXT_NOTE.length);
      if (noteId.length === 0) {
        continue;
      }
      const text: string = this.readTextSync(`${this.notesDir}/${name}`);
      if (text.length === 0) {
        continue;
      }
      const parsed: NoteDeserializeResult = NoteSerializer.deserialize(text, noteId);
      if (!parsed.ok) {
        Logger.warn(TAG_MODULE, `重建索引跳过损坏文件 ${name}`);
        continue;
      }
      const meta: NoteMeta = parsed.content.meta;
      meta.sizeBytes = this.sizeOf(`${this.notesDir}/${name}`);
      metas.push(meta);
    }
    if (metas.length === 0) {
      return 0;
    }
    const ok: boolean = await this.indexStore.replaceAll(metas);
    // T2-1b（d1 §7）：索引重建时同步刷新 pendingTmpNotes（每个候选槽校验 + 比正文新，闸 B）
    // T2-1b P1：先迁移旧单槽 .hcnote.tmp 孤儿，再扫描双槽
    this.migrateLegacyTmpSlots();
    this.scanPendingTmpNotes();
    Logger.info(TAG_MODULE, `索引重建 ${ok ? '成功' : '失败'}，共 ${metas.length} 条`);
    return ok ? metas.length : 0;
  }

  /** ArkTS 下 String.endsWith 可用，但为规避不同 SDK 差异，这里自实现 */
  private static endsWith(text: string, suffix: string): boolean {
    if (text.length < suffix.length) {
      return false;
    }
    return text.substring(text.length - suffix.length) === suffix;
  }

  // ═══════════════════════════════════════════════════════════════
  // ENG-04：文件夹映射导出 / 导入（board.json + meta.json + resources/）
  //   所有新写入走 board.json；旧 .hcnote 经 loadNote 读取后由 saveBoardJson 一并落盘（双格式共存）。
  // ═══════════════════════════════════════════════════════════════

  /** 笔记目录绝对路径（Notes/<slug>）；未就绪返回空串 */
  noteFolderPath(noteId: string, title: string): string {
    if (!this.ready) {
      return '';
    }
    return this.folderStore.folderPathForNote(title, noteId);
  }

  /** 写合规 board.json（委托 FolderMappingStore；原子提交） */
  saveBoardJson(board: BoardData, dirAbsPath: string): void {
    if (!this.ready) {
      Logger.warn(TAG_MODULE, 'saveBoardJson：仓储未就绪');
      return;
    }
    this.folderStore.writeBoard(dirAbsPath, board);
  }

  /** 读合规 board.json（解析失败返回空 BoardData） */
  loadBoardJson(dirAbsPath: string): BoardData {
    if (!this.ready) {
      Logger.warn(TAG_MODULE, 'loadBoardJson：仓储未就绪');
      return FolderMappingStore.emptyBoard('');
    }
    return this.folderStore.readBoard(dirAbsPath);
  }

  /** 导出整篇笔记到文件夹（board.json + meta.json；resources 由调用方逐资源 writeResource） */
  async exportToFolder(noteId: string, dirAbsPath: string): Promise<boolean> {
    if (!this.ready || noteId.length === 0) {
      return false;
    }
    const loaded: NoteLoadResult = await this.loadNote(noteId);
    if (!loaded.ok) {
      Logger.warn(TAG_MODULE, `exportToFolder：读取笔记失败 ${noteId}`);
      return false;
    }
    // 旧 .hcnote 内容 → 合规 BoardData（双格式共存迁移：首次导出即落地 board.json）
    const board: BoardData = this.contentToBoard(loaded.content);
    this.folderStore.writeBoard(dirAbsPath, board);
    Logger.info(TAG_MODULE, `exportToFolder 成功 ${noteId} → ${dirAbsPath}`);
    return true;
  }

  /** 从文件夹导入合规笔记，返回列表元信息（驱动笔记列表） */
  async importFromFolder(dirAbsPath: string): Promise<NoteMeta> {
    const board: BoardData = this.folderStore.readBoard(dirAbsPath);
    const meta: NoteFolderMeta | null = this.folderStore.readMeta(dirAbsPath);
    const id: string = board.boardId.length > 0 ? board.boardId : createNoteId();
    const title: string = meta !== null ? meta.title : (board.nodes.length > 0 ? '导入的笔记' : '未命名笔记');
    const noteMeta: NoteMeta = createNoteMeta(id, title, HC_DEFAULT_PAPER);
    noteMeta.updatedAt = meta !== null ? meta.updatedAt : Date.now();
    noteMeta.createdAt = meta !== null ? meta.createdAt : Date.now();
    noteMeta.sizeBytes = meta !== null ? meta.sizeBytes : 0;
    // 同步写回旧 .hcnote 工作副本（双格式共存），保证索引链路完整
    const content = createEmptyNoteContent(id, title, HC_DEFAULT_PAPER);
    content.meta = noteMeta;
    await this.saveNote(content, false);
    Logger.info(TAG_MODULE, `importFromFolder 成功 ${dirAbsPath} → ${id}`);
    return noteMeta;
  }

  /**
   * 旧 .hcnote 内容 → 合规 BoardData（迁移桥接）。
   * 既有 NoteContent 的 strokes 为 HCStroke（points 平铺），此处转合规 {x,y,p} 控制点序列。
   * 阶段2 之前仅做笔画与图片的合规投影；文本/双链/书签在阶段2 模型落地后补全。
   */
  private contentToBoard(content: NoteContent): BoardData {
    const board: BoardData = FolderMappingStore.emptyBoard(content.meta.id);
    board.lamport = content.meta.updatedAt > 0 ? 1 : 0;
    board.viewport = { x: 0, y: 0, zoom: 1 };
    const strokes = content.strokes !== undefined ? content.strokes : [];
    for (let i = 0; i < strokes.length; i++) {
      const s = strokes[i];
      const node = this.hcStrokeToNode(s);
      if (node !== null) {
        board.nodes.push(node);
      }
    }
    const images = content.images !== undefined ? content.images : [];
    for (let i = 0; i < images.length; i++) {
      const img = images[i];
      board.nodes.push({
        id: img.id.length > 0 ? img.id : `img_${i}`,
        type: 'image',
        lamport: 0,
        deleted: false,
        resources: img.uri.length > 0 ? `resources/${img.id}` : '',
        x: img.x,
        y: img.y,
        w: img.width,
        h: img.height,
        z: i,
        payload: { src: img.uri, rotation: img.rotation }
      });
    }
    return board;
  }

  /** 单笔 HCStroke → 合规 stroke 节点（压感 0–1 → 0–255，控制点拟合） */
  private hcStrokeToNode(s: HCStroke): CanvasNode | null {
    const flat: number[] = s.points !== undefined ? s.points : [];
    if (flat.length < 4) {
      return null;
    }
    const pairCount: number = Math.floor(flat.length / 2);
    const raw: Point3Like[] = [];
    for (let k = 0; k < pairCount; k++) {
      const rawP: number = s.pressure !== undefined && s.pressure.length > k ? s.pressure[k] : 0.5;
      raw.push({ x: flat[k * 2], y: flat[k * 2 + 1], p: rawP });
    }
    // 延迟导入避免顶层循环依赖：直接本地量化
    const pts: Point3[] = [];
    for (let k = 0; k < raw.length; k++) {
      const rp: number = raw[k].p < 0 ? 0 : raw[k].p > 1 ? 1 : raw[k].p;
      pts.push({ x: raw[k].x, y: raw[k].y, p: Math.round(rp * 255) });
    }
    let minX: number = pts[0].x;
    let minY: number = pts[0].y;
    let maxX: number = pts[0].x;
    let maxY: number = pts[0].y;
    for (let k = 1; k < pts.length; k++) {
      if (pts[k].x < minX) {
        minX = pts[k].x;
      }
      if (pts[k].y < minY) {
        minY = pts[k].y;
      }
      if (pts[k].x > maxX) {
        maxX = pts[k].x;
      }
      if (pts[k].y > maxY) {
        maxY = pts[k].y;
      }
    }
    return {
      id: s.id.length > 0 ? s.id : `stroke_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`,
      type: 'stroke',
      lamport: 0,
      deleted: false,
      resources: '',
      x: minX,
      y: minY,
      w: maxX - minX,
      h: maxY - minY,
      z: 0,
      payload: { tool: s.tool, color: s.color, width: s.width, points: pts }
    };
  }
}

/** 内部轻量点结构（避免与 BoardModel Point3 循环导入语义混淆） */
interface Point3Like {
  x: number;
  y: number;
  p: number;
}
