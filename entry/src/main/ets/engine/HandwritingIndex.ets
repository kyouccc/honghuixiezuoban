/**
 * HandwritingIndex.ets — 端侧手写全文检索索引（NOTE-04，阶段2 P1 占位）
 *
 * ⚠️ 红线：阶段2 功能，本期（阶段1）【仅接口占位】。
 *   PaddleOCR-lite 鸿蒙版（指令集要求隐私不下云）本期不落地，仅预留接口。
 *   占位实现：文本便签（text/sticky）可直接被关键词检索；手写节点检索待阶段2 接 OCR 后启用。
 *
 * 设计：纯接口 + 轻量内存倒排桩，保证阶段1 已落盘的 text/sticky 可被即时关键词命中，
 *       不引入任何第三方 OCR 依赖（架构 §6 红线圈定）。
 */

import { CanvasNode, TextPayload, StickyPayload } from './types/BoardModel';

export interface SearchHit {
  nodeId: string;
  /** 命中片段（高亮用） */
  snippet: string;
  /** 命中位置（画布逻辑坐标，供跳转） */
  x: number;
  y: number;
  /** 命中关键词数（相关性排序用） */
  matchCount: number;
}

export class HandwritingIndex {
  /** OCR 占位开关：阶段3/参赛版接 PaddleOCR-lite 鸿蒙版后启用；本期 stroke 节点不进关键词索引（隐私/离线约束） */
  private ocrEnabled: boolean = false;

  /** 全量重建（首次 / 加载时调用） */
  indexAll(nodes: CanvasNode[]): void {
    this.textNodes = [];
    for (let i = 0; i < nodes.length; i++) {
      this.upsertNode(nodes[i]);
    }
  }

  /** 增量更新单个节点（便签编辑/创建后即时刷新索引） */
  upsertNode(node: CanvasNode): void {
    if (node.deleted) {
      this.removeNode(node.id);
      return;
    }
    let text: string = '';
    if (node.type === 'text') {
      const pl = node.payload as TextPayload;
      text = pl.content;
    } else if (node.type === 'sticky') {
      const pl = node.payload as StickyPayload;
      text = pl.text;
    } else if (this.ocrEnabled && node.type === 'stroke') {
      // 阶段3：PaddleOCR-lite 端侧识别 stroke → text，此处占位
      return;
    } else {
      return;
    }
    if (text.length === 0) {
      this.removeNode(node.id);
      return;
    }
    for (let i = 0; i < this.textNodes.length; i++) {
      if (this.textNodes[i].id === node.id) {
        this.textNodes[i].text = text;
        this.textNodes[i].x = node.x;
        this.textNodes[i].y = node.y;
        return;
      }
    }
    this.textNodes.push({ id: node.id, text: text, x: node.x, y: node.y });
  }

  /** 移除节点索引（删除/软删后调用） */
  removeNode(id: string): void {
    for (let i = 0; i < this.textNodes.length; i++) {
      if (this.textNodes[i].id === id) {
        this.textNodes.splice(i, 1);
        return;
      }
    }
  }

  /**
   * 多关键词检索（阶段2 增强）：
   *  - 关键词按空格分割，OR 逻辑（命中任一即返回）
   *  - 大小写不敏感子串匹配
   *  - 按命中关键词数降序排列（相关性排序）
   *  - snippet 截取命中位置前后 10 字符上下文
   */
  search(keyword: string): SearchHit[] {
    const hits: SearchHit[] = [];
    if (keyword === undefined || keyword === null || keyword.length === 0) {
      return hits;
    }
    // 分词：按空格分割，过滤空串
    const kws: string[] = keyword.toLowerCase().split(/\s+/).filter((s: string) => s.length > 0);
    if (kws.length === 0) {
      return hits;
    }

    for (let i = 0; i < this.textNodes.length; i++) {
      const t: IndexedText = this.textNodes[i];
      const lower: string = t.text.toLowerCase();
      let matchCount: number = 0;
      let firstIdx: number = -1;
      let matchLen: number = 0;

      for (let k = 0; k < kws.length; k++) {
        const idx: number = lower.indexOf(kws[k]);
        if (idx >= 0) {
          matchCount++;
          if (firstIdx < 0 || idx < firstIdx) {
            firstIdx = idx;
            matchLen = kws[k].length;
          }
        }
      }

      if (matchCount > 0) {
        const start: number = Math.max(0, firstIdx - 10);
        const end: number = Math.min(t.text.length, firstIdx + matchLen + 10);
        hits.push({
          nodeId: t.id,
          snippet: (start > 0 ? '…' : '') + t.text.substring(start, end) + (end < t.text.length ? '…' : ''),
          x: t.x,
          y: t.y,
          matchCount: matchCount
        });
      }
    }

    // 按命中数降序排列
    hits.sort((a: SearchHit, b: SearchHit) => b.matchCount - a.matchCount);
    return hits;
  }

  private textNodes: IndexedText[] = [];
}

interface IndexedText {
  id: string;
  text: string;
  x: number;
  y: number;
}
