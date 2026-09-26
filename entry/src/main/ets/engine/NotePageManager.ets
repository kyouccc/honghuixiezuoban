/**
 * NotePageManager.ets — 多页管理器（P0-3）
 *
 * 功能：
 *  1. 增删页面（addPage / deletePage / duplicatePage）；
 *  2. 页面排序（movePage / reorderPages）；
 *  3. 当前页切换（setCurrentPage / nextPage / prevPage）；
 *  4. 页面标题/底纸类型设置（setPageTitle / setPagePaper）；
 *  5. 页面缩略图缓存（getThumbnail / invalidateThumbnail）。
 *
 * 架构：纯逻辑单例，不依赖 UI。通过 onPageChanged 回调通知 UI 刷新。
 */

import { Logger } from '../common/Logger';

const TAG = 'NotePageManager';

/** 底纸类型 */
export enum PaperType {
  BLANK = 'blank',
  GRID = 'grid',
  LINED = 'lined',
  DOT = 'dot',
}

/** 单页定义 */
export interface NotePage {
  /** 页面唯一 ID */
  id: string;
  /** 页面标题（可空，显示时回退为「第 N 页」） */
  title: string;
  /** 底纸类型 */
  paper: PaperType;
  /** 创建时间戳 */
  createdAt: number;
  /** 最后修改时间戳 */
  updatedAt: number;
  /** 缩略图 base64（可空，异步生成） */
  thumbnail: string;
}

/** 页面变更事件 */
export enum PageChangeEvent {
  ADDED = 'added',
  DELETED = 'deleted',
  DUPLICATED = 'duplicated',
  MOVED = 'moved',
  CURRENT_CHANGED = 'current_changed',
  TITLE_CHANGED = 'title_changed',
  PAPER_CHANGED = 'paper_changed',
}

/** 变更通知回调 */
export type PageChangeCallback = (event: PageChangeEvent, pageId: string, pages: NotePage[]) => void;

/** NotePage 实现类 */
class NotePageImpl implements NotePage {
  id: string;
  title: string;
  paper: PaperType;
  createdAt: number;
  updatedAt: number;
  thumbnail: string;

  constructor(id: string, title: string, paper: PaperType,
    createdAt: number, updatedAt: number, thumbnail: string) {
    this.id = id;
    this.title = title;
    this.paper = paper;
    this.createdAt = createdAt;
    this.updatedAt = updatedAt;
    this.thumbnail = thumbnail;
  }
}

/** 复制页面 */
function copyPage(src: NotePage): NotePage {
  return new NotePageImpl(src.id, src.title, src.paper, src.createdAt, src.updatedAt, src.thumbnail);
}

/** 简单 UUID 生成 */
function genId(): string {
  return `pg_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

export class NotePageManager {
  private pages: NotePage[] = [];
  private currentPageIndex: number = 0;
  private listeners: PageChangeCallback[] = [];

  // ── 初始化 ──

  /** 初始化：如果无页面则自动创建第一页 */
  initialize(): void {
    if (this.pages.length === 0) {
      this.addPage();
    }
    this.currentPageIndex = 0;
  }

  /** 从外部数据恢复页面列表 */
  restore(pages: NotePage[], currentIndex: number): void {
    this.pages = pages.map(p => copyPage(p));
    this.currentPageIndex = Math.max(0, Math.min(currentIndex, this.pages.length - 1));
    if (this.pages.length === 0) {
      this.addPage();
    }
  }

  /** 导出页面列表（用于持久化） */
  exportPages(): NotePage[] {
    return this.pages.map(p => copyPage(p));
  }

  // ── 查询 ──

  get pageCount(): number { return this.pages.length; }
  get currentIndex(): number { return this.currentPageIndex; }

  get currentPage(): NotePage | null {
    if (this.pages.length === 0) return null;
    return this.pages[this.currentPageIndex];
  }

  get currentPageId(): string {
    const p = this.currentPage;
    return p ? p.id : '';
  }

  getPage(index: number): NotePage | null {
    if (index < 0 || index >= this.pages.length) return null;
    return this.pages[index];
  }

  getPageById(id: string): NotePage | null {
    for (const p of this.pages) {
      if (p.id === id) return p;
    }
    return null;
  }

  indexOf(id: string): number {
    for (let i = 0; i < this.pages.length; i++) {
      if (this.pages[i].id === id) return i;
    }
    return -1;
  }

  list(): NotePage[] {
    return this.pages.map(p => copyPage(p));
  }

  // ── 页面操作 ──

  /** 新增页面（在末尾追加） */
  addPage(paper: PaperType = PaperType.BLANK, title: string = ''): NotePage {
    const page: NotePage = new NotePageImpl(
      genId(),
      title || `第 ${this.pages.length + 1} 页`,
      paper,
      Date.now(),
      Date.now(),
      ''
    );
    this.pages.push(page);
    this.notify(PageChangeEvent.ADDED, page.id);
    Logger.debug(TAG, `addPage: ${page.id}, total=${this.pages.length}`);
    return page;
  }

  /** 在指定位置插入页面 */
  insertPage(index: number, paper: PaperType = PaperType.BLANK): NotePage {
    const page: NotePage = new NotePageImpl(
      genId(),
      `第 ${index + 1} 页`,
      paper,
      Date.now(),
      Date.now(),
      ''
    );
    const insertAt = Math.max(0, Math.min(index, this.pages.length));
    this.pages.splice(insertAt, 0, page);
    if (this.currentPageIndex >= insertAt) {
      this.currentPageIndex++;
    }
    this.notify(PageChangeEvent.ADDED, page.id);
    return page;
  }

  /** 删除页面（至少保留 1 页） */
  deletePage(id: string): boolean {
    if (this.pages.length <= 1) {
      Logger.warn(TAG, 'deletePage: 至少保留 1 页');
      return false;
    }
    const idx = this.indexOf(id);
    if (idx < 0) return false;

    this.pages.splice(idx, 1);

    // 调整当前页索引
    if (this.currentPageIndex >= this.pages.length) {
      this.currentPageIndex = this.pages.length - 1;
    } else if (idx < this.currentPageIndex) {
      this.currentPageIndex--;
    }

    this.notify(PageChangeEvent.DELETED, id);
    Logger.debug(TAG, `deletePage: ${id}, remaining=${this.pages.length}`);
    return true;
  }

  /** 复制页面（在原页后插入副本） */
  duplicatePage(id: string): NotePage | null {
    const idx = this.indexOf(id);
    if (idx < 0) return null;

    const src = this.pages[idx];
    const copy: NotePage = new NotePageImpl(
      genId(),
      `${src.title} 副本`,
      src.paper,
      Date.now(),
      Date.now(),
      src.thumbnail
    );
    this.pages.splice(idx + 1, 0, copy);
    this.notify(PageChangeEvent.DUPLICATED, copy.id);
    return copy;
  }

  /** 移动页面（改变顺序） */
  movePage(id: string, toIndex: number): boolean {
    const fromIndex = this.indexOf(id);
    if (fromIndex < 0) return false;
    const target = Math.max(0, Math.min(toIndex, this.pages.length - 1));
    if (fromIndex === target) return false;

    const spliced: NotePage[] = this.pages.splice(fromIndex, 1);
    this.pages.splice(target, 0, spliced[0]);

    // 保持当前页指向同一页面
    this.currentPageIndex = this.indexOf(this.currentPageId);

    this.notify(PageChangeEvent.MOVED, id);
    return true;
  }

  /** 重新排序（传入有序 ID 数组） */
  reorderPages(orderedIds: string[]): boolean {
    if (orderedIds.length !== this.pages.length) return false;
    const map = new Map<string, NotePage>();
    for (const p of this.pages) map.set(p.id, p);
    const reordered: NotePage[] = [];
    for (const id of orderedIds) {
      const p = map.get(id);
      if (!p) return false;
      reordered.push(p);
    }
    this.pages = reordered;
    this.currentPageIndex = this.indexOf(this.currentPageId);
    this.notify(PageChangeEvent.MOVED, '');
    return true;
  }

  // ── 当前页切换 ──

  setCurrentPage(index: number): void {
    if (index < 0 || index >= this.pages.length) return;
    if (index === this.currentPageIndex) return;
    this.currentPageIndex = index;
    this.notify(PageChangeEvent.CURRENT_CHANGED, this.currentPageId);
  }

  setCurrentPageById(id: string): void {
    const idx = this.indexOf(id);
    if (idx >= 0) this.setCurrentPage(idx);
  }

  nextPage(): void {
    this.setCurrentPage(this.currentPageIndex + 1);
  }

  prevPage(): void {
    this.setCurrentPage(this.currentPageIndex - 1);
  }

  get hasNext(): boolean { return this.currentPageIndex < this.pages.length - 1; }
  get hasPrev(): boolean { return this.currentPageIndex > 0; }

  // ── 页面属性 ──

  setPageTitle(id: string, title: string): void {
    const p = this.getPageById(id);
    if (!p) return;
    p.title = title;
    p.updatedAt = Date.now();
    this.notify(PageChangeEvent.TITLE_CHANGED, id);
  }

  setPagePaper(id: string, paper: PaperType): void {
    const p = this.getPageById(id);
    if (!p) return;
    p.paper = paper;
    p.updatedAt = Date.now();
    this.notify(PageChangeEvent.PAPER_CHANGED, id);
  }

  // ── 缩略图 ──

  setThumbnail(id: string, base64: string): void {
    const p = this.getPageById(id);
    if (p) p.thumbnail = base64;
  }

  getThumbnail(id: string): string {
    const p = this.getPageById(id);
    return p ? p.thumbnail : '';
  }

  invalidateThumbnail(id: string): void {
    const p = this.getPageById(id);
    if (p) p.thumbnail = '';
  }

  // ── 事件监听 ──

  addListener(cb: PageChangeCallback): void {
    this.listeners.push(cb);
  }

  removeListener(cb: PageChangeCallback): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }

  private notify(event: PageChangeEvent, pageId: string): void {
    const snapshot = this.list();
    for (const cb of this.listeners) {
      cb(event, pageId, snapshot);
    }
  }
}
