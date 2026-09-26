/**
 * TagManager.ets — 标签系统（P1）
 *
 * 功能：
 *  1. 笔记标签的增删改查；
 *  2. 按标签筛选笔记；
 *  3. 标签颜色与图标；
 *  4. 标签使用统计（热门标签）；
 *  5. 层级标签（父标签）。
 */

import { Logger } from '../common/Logger';

const TAG = 'TagManager';

/** 标签定义 */
export interface HCTag {
  id: string;
  name: string;
  /** 标签颜色（hex） */
  color: string;
  /** 父标签 ID（空=顶级标签） */
  parentId: string;
  /** 使用次数 */
  usageCount: number;
}

/** 笔记-标签关联 */
export interface NoteTagRelation {
  noteId: string;
  tagId: string;
}

/** HCTag 实现类 */
class HCTagImpl implements HCTag {
  id: string;
  name: string;
  color: string;
  parentId: string;
  usageCount: number;

  constructor(id: string, name: string, color: string, parentId: string, usageCount: number) {
    this.id = id;
    this.name = name;
    this.color = color;
    this.parentId = parentId;
    this.usageCount = usageCount;
  }
}

/** NoteTagRelation 实现类 */
class NoteTagRelationImpl implements NoteTagRelation {
  noteId: string;
  tagId: string;

  constructor(noteId: string, tagId: string) {
    this.noteId = noteId;
    this.tagId = tagId;
  }
}

/** 复制标签 */
function copyTag(src: HCTag): HCTag {
  return new HCTagImpl(src.id, src.name, src.color, src.parentId, src.usageCount);
}

/** 预置标签颜色 */
const TAG_COLORS: string[] = [
  '#E74C3C', '#E67E22', '#F39C12', '#27AE60',
  '#3498DB', '#9B59B6', '#34495E', '#7F8C8D',
];

function genId(): string {
  return `tag_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

export class TagManager {
  /** 标签列表 */
  private tags: HCTag[] = [];
  /** 笔记-标签关联 */
  private relations: NoteTagRelation[] = [];

  // ── 存储回调 ──
  public saveTags: (tags: HCTag[]) => void = () => {};
  public loadTags: () => HCTag[] = () => [];
  public saveRelations: (relations: NoteTagRelation[]) => void = () => {};
  public loadRelations: () => NoteTagRelation[] = () => [];

  initialize(): void {
    this.tags = this.loadTags();
    this.relations = this.loadRelations();
    if (this.tags.length === 0) {
      // 预置常用标签
      const presets = ['学习', '工作', '灵感', '待办', '重要'];
      for (let i = 0; i < presets.length; i++) {
        this.tags.push(new HCTagImpl(
          genId(), presets[i], TAG_COLORS[i % TAG_COLORS.length], '', 0
        ));
      }
      this.saveTags(this.tags);
    }
  }

  // ── 标签 CRUD ──

  /** 创建标签 */
  createTag(name: string, color: string = '', parentId: string = ''): HCTag {
    const tag: HCTag = new HCTagImpl(
      genId(), name, color || TAG_COLORS[this.tags.length % TAG_COLORS.length], parentId, 0
    );
    this.tags.push(tag);
    this.saveTags(this.tags);
    Logger.debug(TAG, `createTag: ${name}`);
    return tag;
  }

  /** 重命名标签 */
  renameTag(id: string, name: string): boolean {
    const tag = this.tags.find(t => t.id === id);
    if (!tag) return false;
    tag.name = name;
    this.saveTags(this.tags);
    return true;
  }

  /** 修改标签颜色 */
  setTagColor(id: string, color: string): boolean {
    const tag = this.tags.find(t => t.id === id);
    if (!tag) return false;
    tag.color = color;
    this.saveTags(this.tags);
    return true;
  }

  /** 删除标签（同时删除关联） */
  deleteTag(id: string): boolean {
    const idx = this.tags.findIndex(t => t.id === id);
    if (idx < 0) return false;
    this.tags.splice(idx, 1);
    // 删除子标签
    this.tags = this.tags.filter(t => t.parentId !== id);
    // 删除关联
    this.relations = this.relations.filter(r => r.tagId !== id);
    this.saveTags(this.tags);
    this.saveRelations(this.relations);
    return true;
  }

  /** 获取所有标签 */
  listTags(): HCTag[] {
    return this.tags.map(t => copyTag(t));
  }

  /** 获取子标签 */
  listChildTags(parentId: string): HCTag[] {
    return this.tags.filter(t => t.parentId === parentId).map(t => copyTag(t));
  }

  /** 获取热门标签（按使用次数排序） */
  listPopularTags(limit: number = 10): HCTag[] {
    return this.tags.slice()
      .sort((a: HCTag, b: HCTag): number => b.usageCount - a.usageCount)
      .slice(0, limit)
      .map(t => copyTag(t));
  }

  // ── 笔记-标签关联 ──

  /** 为笔记添加标签 */
  addTagToNote(noteId: string, tagId: string): void {
    if (this.relations.some(r => r.noteId === noteId && r.tagId === tagId)) return;
    this.relations.push(new NoteTagRelationImpl(noteId, tagId));
    const tag = this.tags.find(t => t.id === tagId);
    if (tag) tag.usageCount++;
    this.saveRelations(this.relations);
    this.saveTags(this.tags);
  }

  /** 移除笔记的标签 */
  removeTagFromNote(noteId: string, tagId: string): void {
    const idx = this.relations.findIndex(r => r.noteId === noteId && r.tagId === tagId);
    if (idx < 0) return;
    this.relations.splice(idx, 1);
    const tag = this.tags.find(t => t.id === tagId);
    if (tag && tag.usageCount > 0) tag.usageCount--;
    this.saveRelations(this.relations);
    this.saveTags(this.tags);
  }

  /** 获取笔记的所有标签 */
  getTagsForNote(noteId: string): HCTag[] {
    const tagIds = this.relations
      .filter(r => r.noteId === noteId)
      .map(r => r.tagId);
    return this.tags
      .filter(t => tagIds.includes(t.id))
      .map(t => copyTag(t));
  }

  /** 按标签筛选笔记 */
  getNotesByTag(tagId: string): string[] {
    return this.relations
      .filter(r => r.tagId === tagId)
      .map(r => r.noteId);
  }

  /** 按多个标签筛选（交集） */
  getNotesByTags(tagIds: string[]): string[] {
    if (tagIds.length === 0) return [];
    let result = this.getNotesByTag(tagIds[0]);
    for (let i = 1; i < tagIds.length; i++) {
      const next = new Set(this.getNotesByTag(tagIds[i]));
      result = result.filter(id => next.has(id));
    }
    return result;
  }

  /** 搜索标签 */
  searchTags(keyword: string): HCTag[] {
    const kw = keyword.toLowerCase();
    return this.tags
      .filter(t => t.name.toLowerCase().includes(kw))
      .map(t => copyTag(t));
  }
}
