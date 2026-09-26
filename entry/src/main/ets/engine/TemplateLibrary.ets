/**
 * TemplateLibrary.ets — 模板库（P1）
 *
 * 功能：
 *  1. 预置模板（空白/网格/横线/康奈尔/会议纪要/待办清单/思维导图）；
 *  2. 用户自定义模板保存/加载；
 *  3. 从模板创建新笔记（instantiateFromTemplate）；
 *  4. 模板分类与搜索。
 */

import { PaperType } from './NotePageManager';
import { Logger } from '../common/Logger';

const TAG = 'TemplateLibrary';

/** 模板分类 */
export enum TemplateCategory {
  BASIC = '基础',
  STUDY = '学习',
  WORK = '工作',
  CREATIVE = '创意',
  CUSTOM = '自定义',
}

/** 模板定义 */
export interface NoteTemplate {
  id: string;
  name: string;
  category: TemplateCategory;
  /** 底纸类型 */
  paper: PaperType;
  /** 模板描述 */
  description: string;
  /** 预置文本内容（行数组） */
  presetTexts: string[];
  /** 预置标签 */
  presetTags: string[];
  /** 缩略图（base64 或资源名） */
  thumbnail: string;
  /** 是否内置（不可删除） */
  builtin: boolean;
}

/** NoteTemplate 实现类 */
class NoteTemplateImpl implements NoteTemplate {
  id: string;
  name: string;
  category: TemplateCategory;
  paper: PaperType;
  description: string;
  presetTexts: string[];
  presetTags: string[];
  thumbnail: string;
  builtin: boolean;

  constructor(
    id: string, name: string, category: TemplateCategory, paper: PaperType,
    description: string, presetTexts: string[], presetTags: string[],
    thumbnail: string, builtin: boolean
  ) {
    this.id = id;
    this.name = name;
    this.category = category;
    this.paper = paper;
    this.description = description;
    this.presetTexts = presetTexts;
    this.presetTags = presetTags;
    this.thumbnail = thumbnail;
    this.builtin = builtin;
  }
}

/** 模板实例化结果 */
export interface TemplateInstance {
  paper: PaperType;
  texts: string[];
  tags: string[];
}

/** 复制模板 */
function copyTemplate(src: NoteTemplate): NoteTemplate {
  return new NoteTemplateImpl(
    src.id, src.name, src.category, src.paper,
    src.description, src.presetTexts.slice(), src.presetTags.slice(),
    src.thumbnail, src.builtin
  );
}

/** 内置模板 */
const BUILTIN_TEMPLATES: NoteTemplate[] = [
  new NoteTemplateImpl('tpl_blank', '空白页', TemplateCategory.BASIC, PaperType.BLANK,
    '纯白画布，自由创作', [], [], 'tpl_blank', true),
  new NoteTemplateImpl('tpl_grid', '方格本', TemplateCategory.BASIC, PaperType.GRID,
    '5mm 方格底纸，适合绘图与公式', [], [], 'tpl_grid', true),
  new NoteTemplateImpl('tpl_lined', '横线本', TemplateCategory.BASIC, PaperType.LINED,
    '横线底纸，适合书写', [], [], 'tpl_lined', true),
  new NoteTemplateImpl('tpl_cornell', '康奈尔笔记', TemplateCategory.STUDY, PaperType.LINED,
    '线索栏 + 笔记区 + 总结区', ['线索：', '笔记：', '总结：'], ['学习', '笔记'], 'tpl_cornell', true),
  new NoteTemplateImpl('tpl_meeting', '会议纪要', TemplateCategory.WORK, PaperType.LINED,
    '会议日期/参会人/议题/决议', ['日期：', '参会人：', '议题：', '决议：', '待办：'], ['工作', '会议'], 'tpl_meeting', true),
  new NoteTemplateImpl('tpl_todo', '待办清单', TemplateCategory.WORK, PaperType.BLANK,
    '勾选式待办列表', ['☐ ', '☐ ', '☐ ', '☐ ', '☐ '], ['工作', '待办'], 'tpl_todo', true),
  new NoteTemplateImpl('tpl_mindmap', '思维导图', TemplateCategory.CREATIVE, PaperType.DOT,
    '点阵底纸，中心主题发散', ['中心主题'], ['创意', '导图'], 'tpl_mindmap', true),
  new NoteTemplateImpl('tpl_daily', '日记', TemplateCategory.CREATIVE, PaperType.LINED,
    '每日心情与记录', ['今日心情：', '今日记录：'], ['日记'], 'tpl_daily', true),
];

export class TemplateLibrary {
  /** 内置 + 自定义模板 */
  private templates: NoteTemplate[] = [];
  /** 自定义模板存储回调 */
  public saveCustom: (templates: NoteTemplate[]) => void = () => {};
  public loadCustom: () => NoteTemplate[] = () => [];

  initialize(): void {
    this.templates = BUILTIN_TEMPLATES.map(t => copyTemplate(t));
    const custom = this.loadCustom();
    for (const c of custom) {
      this.templates.push(c);
    }
    Logger.debug(TAG, `initialize: ${this.templates.length} 个模板`);
  }

  /** 获取所有模板 */
  list(): NoteTemplate[] {
    return this.templates.map(t => copyTemplate(t));
  }

  /** 按分类获取 */
  listByCategory(category: TemplateCategory): NoteTemplate[] {
    return this.templates.filter(t => t.category === category).map(t => copyTemplate(t));
  }

  /** 搜索模板 */
  search(keyword: string): NoteTemplate[] {
    const kw = keyword.toLowerCase();
    return this.templates.filter(t =>
      t.name.toLowerCase().includes(kw) ||
      t.description.toLowerCase().includes(kw) ||
      t.presetTags.some(tag => tag.toLowerCase().includes(kw))
    ).map(t => copyTemplate(t));
  }

  /** 获取单个模板 */
  getTemplate(id: string): NoteTemplate | null {
    const t = this.templates.find(t => t.id === id);
    return t ? copyTemplate(t) : null;
  }

  /** 保存自定义模板 */
  saveTemplate(template: NoteTemplate): void {
    if (template.builtin) {
      Logger.warn(TAG, 'saveTemplate: 内置模板不可覆盖');
      return;
    }
    const idx = this.templates.findIndex(t => t.id === template.id);
    if (idx >= 0) {
      this.templates[idx] = copyTemplate(template);
    } else {
      this.templates.push(copyTemplate(template));
    }
    this.persistCustom();
  }

  /** 删除自定义模板 */
  deleteTemplate(id: string): boolean {
    const idx = this.templates.findIndex(t => t.id === id);
    if (idx < 0) return false;
    if (this.templates[idx].builtin) {
      Logger.warn(TAG, 'deleteTemplate: 内置模板不可删除');
      return false;
    }
    this.templates.splice(idx, 1);
    this.persistCustom();
    return true;
  }

  /** 从模板创建新笔记的初始内容 */
  instantiateFromTemplate(templateId: string): TemplateInstance | null {
    const tpl = this.getTemplate(templateId);
    if (!tpl) return null;
    return {
      paper: tpl.paper,
      texts: tpl.presetTexts.slice(),
      tags: tpl.presetTags.slice(),
    } as TemplateInstance;
  }

  /** 持久化自定义模板 */
  private persistCustom(): void {
    const custom = this.templates.filter(t => !t.builtin);
    this.saveCustom(custom);
  }
}
