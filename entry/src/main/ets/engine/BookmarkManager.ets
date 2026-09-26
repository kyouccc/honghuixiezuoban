/**
 * BookmarkManager.ets — 书签三类（必背/易错/真题）锚点管理（NOTE-03，阶段2 P1 占位）
 *
 * ⚠️ 红线：阶段2 功能，本期（阶段1）【仅接口占位】，不实质实现书签栏 UI / minimap 跳转浮层。
 *   仅提供内存态书签增删查桩（board.json bookmarks[] 可落盘），三类类型严格限定（数据规范§五）。
 */

import { BookmarkData, BookmarkType } from './types/BoardModel';

export class BookmarkManager {
  private bookmarks: BookmarkData[] = [];

  /** 新增书签（type 必须为 BookmarkType 三类之一，非法降级为必背） */
  add(nodeId: string, type: string, x: number, y: number, zoom: number, label: string): BookmarkData {
    const validType: string = (type === BookmarkType.MUST_RECITE || type === BookmarkType.EASY_WRONG ||
      type === BookmarkType.REAL_QUESTION) ? type : BookmarkType.MUST_RECITE;
    const bm: BookmarkData = {
      id: `bm_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`,
      nodeId: nodeId,
      type: validType,
      x: x,
      y: y,
      zoom: zoom,
      label: label
    };
    this.bookmarks.push(bm);
    return bm;
  }

  /** 软删除书签（置标志位，阶段2 归档） */
  remove(id: string): void {
    for (let i = 0; i < this.bookmarks.length; i++) {
      if (this.bookmarks[i].id === id) {
        this.bookmarks.splice(i, 1);
        return;
      }
    }
  }

  /** 按类型筛选（三类：必背/易错/真题） */
  listByType(type: string): BookmarkData[] {
    const out: BookmarkData[] = [];
    for (let i = 0; i < this.bookmarks.length; i++) {
      if (this.bookmarks[i].type === type) {
        out.push(this.bookmarks[i]);
      }
    }
    return out;
  }

  /** 全部书签 */
  list(): BookmarkData[] {
    return this.bookmarks.slice();
  }

  /** 删除节点的全部书签 */
  removeByNode(nodeId: string): void {
    for (let i = this.bookmarks.length - 1; i >= 0; i--) {
      if (this.bookmarks[i].nodeId === nodeId) {
        this.bookmarks.splice(i, 1);
      }
    }
  }

  /** 某节点是否已书签 */
  hasBookmark(nodeId: string): boolean {
    for (let i = 0; i < this.bookmarks.length; i++) {
      if (this.bookmarks[i].nodeId === nodeId) {
        return true;
      }
    }
    return false;
  }

  /** 切换书签：已书签则取消，否则新增（type 限定三类） */
  toggle(nodeId: string, type: string, x: number, y: number, zoom: number, label: string): BookmarkData | null {
    for (let i = 0; i < this.bookmarks.length; i++) {
      if (this.bookmarks[i].nodeId === nodeId) {
        this.bookmarks.splice(i, 1);
        return null;
      }
    }
    return this.add(nodeId, type, x, y, zoom, label);
  }

  /** 反序列化重建 */
  hydrate(bookmarks: BookmarkData[]): void {
    this.bookmarks = bookmarks.slice();
  }
}
