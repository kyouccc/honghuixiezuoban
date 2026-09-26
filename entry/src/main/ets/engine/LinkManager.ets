/**
 * LinkManager.ets — 手写双链管理（NOTE-02，阶段2 P1 占位）
 *
 * ⚠️ 红线：阶段2 功能，本期（阶段1）【仅接口占位】，不实质实现建链 UI / 力导向 / 连线渲染。
 *   仅提供内存态数据结构的增删查桩，供阶段1 数据结构与序列化链路打通（board.json links[] 可落盘）。
 *
 * 软删除约定（数据规范§四）：删除只置 deleted=true，不物理删，无幽灵引用（两端节点保持独立可合并）。
 */

import { LinkData } from './types/BoardModel';

export class LinkManager {
  private links: LinkMapEntry[] = [];

  /**
   * 建链（占位：仅追加一条 links[] 记录）。
   * 阶段2 将由「圈选 / 拖拽」手势驱动，本期不接 UI。
   */
  addLink(from: string, to: string, label: string, lamport: number): LinkData {
    const link: LinkData = {
      id: `l_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`,
      from: from,
      to: to,
      label: label,
      lamport: lamport,
      deleted: false
    };
    this.links.push({ link: link });
    return link;
  }

  /** 软删除链（置 deleted=true，保留对象，无幽灵引用） */
  removeLink(id: string): void {
    for (let i = 0; i < this.links.length; i++) {
      if (this.links[i].link.id === id) {
        this.links[i].link.deleted = true;
        return;
      }
    }
  }

  /** 全部链接（含软删除；调用方按 deleted 过滤） */
  getLinks(): LinkData[] {
    const out: LinkData[] = [];
    for (let i = 0; i < this.links.length; i++) {
      out.push(this.links[i].link);
    }
    return out;
  }

  /** 取某节点的全部出/入链（占位：按 from/to 匹配） */
  linksOfNode(nodeId: string): LinkData[] {
    const out: LinkData[] = [];
    for (let i = 0; i < this.links.length; i++) {
      const l: LinkData = this.links[i].link;
      if (!l.deleted && (l.from === nodeId || l.to === nodeId)) {
        out.push(l);
      }
    }
    return out;
  }

  /** 出链（from === nodeId） */
  outgoingOf(nodeId: string): LinkData[] {
    const out: LinkData[] = [];
    for (let i = 0; i < this.links.length; i++) {
      const l: LinkData = this.links[i].link;
      if (!l.deleted && l.from === nodeId) {
        out.push(l);
      }
    }
    return out;
  }

  /** 入链（to === nodeId） */
  incomingOf(nodeId: string): LinkData[] {
    const out: LinkData[] = [];
    for (let i = 0; i < this.links.length; i++) {
      const l: LinkData = this.links[i].link;
      if (!l.deleted && l.to === nodeId) {
        out.push(l);
      }
    }
    return out;
  }

  /** 两节点间是否已存在活跃链 */
  existsBetween(a: string, b: string): boolean {
    for (let i = 0; i < this.links.length; i++) {
      const l: LinkData = this.links[i].link;
      if (!l.deleted && ((l.from === a && l.to === b) || (l.from === b && l.to === a))) {
        return true;
      }
    }
    return false;
  }

  /** 切换链：已存在则软删，否则新建（避免重复链） */
  toggleLink(fromId: string, toId: string, label: string, lamport: number): LinkData | null {
    for (let i = 0; i < this.links.length; i++) {
      const entry: LinkMapEntry = this.links[i];
      const l: LinkData = entry.link;
      if (!l.deleted && ((l.from === fromId && l.to === toId) || (l.from === toId && l.to === fromId))) {
        l.deleted = true;
        return null;
      }
    }
    return this.addLink(fromId, toId, label, lamport);
  }

  /** 节点删除时软删其全部关联链 */
  removeByNode(nodeId: string): void {
    for (let i = 0; i < this.links.length; i++) {
      const l: LinkData = this.links[i].link;
      if (!l.deleted && (l.from === nodeId || l.to === nodeId)) {
        l.deleted = true;
      }
    }
  }

  /** 用反序列化得到的 links 重建内存索引（落盘读取后调用） */
  hydrate(links: LinkData[]): void {
    this.links = [];
    for (let i = 0; i < links.length; i++) {
      this.links.push({ link: links[i] });
    }
  }
}

interface LinkMapEntry {
  link: LinkData;
}
