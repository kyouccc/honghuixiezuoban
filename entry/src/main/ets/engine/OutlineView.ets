/**
 * OutlineView.ets — 大纲视图（P1）
 *
 * 功能：
 *  1. 从笔记文本/标题自动生成层级大纲；
 *  2. 支持手动编辑大纲条目；
 *  3. 大纲跳转（点击条目跳转到对应画布位置）；
 *  4. 拖拽调整层级与顺序；
 *  5. 大纲导出为纯文本/Markdown。
 */

import { Logger } from '../common/Logger';

const TAG = 'OutlineView';

/** 大纲条目 */
export interface OutlineItem {
  id: string;
  /** 层级（0=顶级，1=子级，...） */
  level: number;
  /** 文本内容 */
  text: string;
  /** 关联的画布元素 ID（用于跳转） */
  targetId: string;
  /** 是否折叠子项 */
  collapsed: boolean;
}

/** 大纲文本块（从文本框提取） */
export interface OutlineTextBlock {
  id: string;
  text: string;
  y: number;
}

/** 大纲生成规则 */
export interface OutlineRule {
  /** 标题正则（匹配则作为对应层级） */
  headingPatterns: RegExp[];
  /** 对应层级 */
  levels: number[];
}

/** OutlineItem 实现类 */
class OutlineItemImpl implements OutlineItem {
  id: string;
  level: number;
  text: string;
  targetId: string;
  collapsed: boolean;

  constructor(id: string, level: number, text: string, targetId: string, collapsed: boolean) {
    this.id = id;
    this.level = level;
    this.text = text;
    this.targetId = targetId;
    this.collapsed = collapsed;
  }
}

/** OutlineRule 实现类 */
class OutlineRuleImpl implements OutlineRule {
  headingPatterns: RegExp[];
  levels: number[];

  constructor(headingPatterns: RegExp[], levels: number[]) {
    this.headingPatterns = headingPatterns;
    this.levels = levels;
  }
}

/** 默认规则：# = 0级，## = 1级，### = 2级 */
const DEFAULT_RULE: OutlineRule = new OutlineRuleImpl(
  [
    /^#{1}\s/,
    /^#{2}\s/,
    /^#{3}\s/,
    /^\d+\.\s/,  // 有序列表
    /^[-*]\s/,    // 无序列表
  ],
  [0, 1, 2, 1, 1],
);

function genId(): string {
  return `ol_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

/** 复制 OutlineItem */
function copyItem(src: OutlineItem): OutlineItem {
  return new OutlineItemImpl(src.id, src.level, src.text, src.targetId, src.collapsed);
}

export class OutlineView {
  /** 大纲条目 */
  private items: OutlineItem[] = [];

  // ── 查询 ──

  get count(): number { return this.items.length; }
  list(): OutlineItem[] { return this.items.map(i => copyItem(i)); }

  /** 获取可见条目（考虑折叠） */
  listVisible(): OutlineItem[] {
    const result: OutlineItem[] = [];
    let skipLevel = -1;
    for (const item of this.items) {
      if (skipLevel >= 0 && item.level > skipLevel) continue;
      skipLevel = -1;
      result.push(copyItem(item));
      if (item.collapsed) skipLevel = item.level;
    }
    return result;
  }

  // ── 从文本生成大纲 ──

  /**
   * 从多行文本自动生成大纲。
   * @param lines 文本行数组
   * @param rule 生成规则（默认 Markdown 风格）
   */
  generateFromText(lines: string[], rule: OutlineRule = DEFAULT_RULE): void {
    this.items = [];
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) continue;

      let level = -1;
      for (let j = 0; j < rule.headingPatterns.length; j++) {
        if (rule.headingPatterns[j].test(line)) {
          level = rule.levels[j];
          break;
        }
      }

      if (level < 0) {
        // 普通文本作为上一条的子项或顶级
        level = this.items.length > 0 ? Math.min(this.items[this.items.length - 1].level + 1, 3) : 0;
      }

      // 清理标记符号
      let text = line.replace(/^#+\s*/, '').replace(/^\d+\.\s*/, '').replace(/^[-*]\s*/, '');

      this.items.push(new OutlineItemImpl(genId(), level, text, '', false));
    }
    Logger.debug(TAG, `generateFromText: ${this.items.length} 条目`);
  }

  /** 从文本框列表生成（关联 targetId） */
  generateFromTextBlocks(blocks: OutlineTextBlock[]): void {
    this.items = [];
    // 按 y 坐标排序（复制后排序，不修改原数组）
    const sorted: OutlineTextBlock[] = blocks.slice().sort((a: OutlineTextBlock, b: OutlineTextBlock): number => a.y - b.y);
    for (const block of sorted) {
      const lines = block.text.split('\n');
      for (const line of lines) {
        if (line.trim().length === 0) continue;
        let level = 0;
        let text = line;
        if (/^#{1}\s/.test(line)) { level = 0; text = line.replace(/^#{1}\s/, ''); }
        else if (/^#{2}\s/.test(line)) { level = 1; text = line.replace(/^#{2}\s/, ''); }
        else if (/^#{3}\s/.test(line)) { level = 2; text = line.replace(/^#{3}\s/, ''); }
        else { level = 1; }

        this.items.push(new OutlineItemImpl(genId(), level, text.trim(), block.id, false));
      }
    }
  }

  // ── 手动编辑 ──

  /** 添加条目 */
  addItem(text: string, level: number = 0, targetId: string = ''): OutlineItem {
    const item: OutlineItem = new OutlineItemImpl(genId(), level, text, targetId, false);
    this.items.push(item);
    return item;
  }

  /** 更新条目文本 */
  updateText(id: string, text: string): boolean {
    const item = this.items.find(i => i.id === id);
    if (!item) return false;
    item.text = text;
    return true;
  }

  /** 更新层级 */
  updateLevel(id: string, level: number): boolean {
    const item = this.items.find(i => i.id === id);
    if (!item) return false;
    item.level = Math.max(0, Math.min(5, level));
    return true;
  }

  /** 缩进（增加层级） */
  indent(id: string): boolean {
    const item = this.items.find(i => i.id === id);
    if (!item) return false;
    if (item.level >= 5) return false;
    item.level++;
    return true;
  }

  /** 反缩进（减少层级） */
  outdent(id: string): boolean {
    const item = this.items.find(i => i.id === id);
    if (!item) return false;
    if (item.level <= 0) return false;
    item.level--;
    return true;
  }

  /** 删除条目 */
  removeItem(id: string): boolean {
    const idx = this.items.findIndex(i => i.id === id);
    if (idx < 0) return false;
    this.items.splice(idx, 1);
    return true;
  }

  /** 移动条目 */
  moveItem(id: string, toIndex: number): boolean {
    const fromIndex = this.items.findIndex(i => i.id === id);
    if (fromIndex < 0) return false;
    const target = Math.max(0, Math.min(toIndex, this.items.length - 1));
    if (fromIndex === target) return false;
    const spliced: OutlineItem[] = this.items.splice(fromIndex, 1);
    this.items.splice(target, 0, spliced[0]);
    return true;
  }

  /** 折叠/展开 */
  toggleCollapse(id: string): void {
    const item = this.items.find(i => i.id === id);
    if (item) item.collapsed = !item.collapsed;
  }

  // ── 跳转 ──

  /** 获取条目关联的画布元素 ID */
  getTargetId(id: string): string {
    const item = this.items.find(i => i.id === id);
    return item ? item.targetId : '';
  }

  // ── 导出 ──

  /** 导出为 Markdown */
  toMarkdown(): string {
    const lines: string[] = [];
    for (const item of this.items) {
      const prefix = '#'.repeat(Math.min(item.level + 1, 6));
      lines.push(`${prefix} ${item.text}`);
    }
    return lines.join('\n');
  }

  /** 导出为纯文本（带缩进） */
  toPlainText(): string {
    const lines: string[] = [];
    for (const item of this.items) {
      const indent = '  '.repeat(item.level);
      lines.push(`${indent}${item.text}`);
    }
    return lines.join('\n');
  }
}
