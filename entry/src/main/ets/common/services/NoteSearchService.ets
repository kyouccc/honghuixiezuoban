/**
 * 笔记搜索服务
 * 提供笔记全文搜索功能，支持标题、标签、文本内容搜索
 */
import { NoteMeta } from '../../engine/types/NoteModel';
import { NoteContent } from '../../engine/types/NoteModel';
import { NoteEngine } from '../../engine/NoteEngine';
import { Logger } from '../Logger';

const TAG = 'NoteSearchService';
const DOMAIN = 0x0000;

/**
 * 搜索结果接口
 */
export interface SearchResult {
  noteId: string;
  noteMeta: NoteMeta;
  matches: SearchMatch[];
  relevanceScore: number;
}

/**
 * 搜索匹配项接口
 */
export interface SearchMatch {
  type: 'title' | 'tag' | 'text' | 'flashcard';
  content: string;
  position?: number; // 文本中的位置
  pageIndex?: number; // 页面索引（如果有）
  textIndex?: number; // 文本块索引（如果有）
}

/**
 * 笔记搜索服务类
 */
export class NoteSearchService {
  private noteEngine: NoteEngine;
  
  constructor(noteEngine: NoteEngine) {
    this.noteEngine = noteEngine;
  }
  
  /**
   * 搜索笔记
   * @param keyword 搜索关键词
   * @param notes 笔记元数据列表
   * @returns 搜索结果列表
   */
  async searchNotes(keyword: string, notes: NoteMeta[]): Promise<SearchResult[]> {
    const kw = keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return [];
    }
    
    const results: SearchResult[] = [];
    
    for (const noteMeta of notes) {
      const matches: SearchMatch[] = [];
      
      // 搜索标题
      if (noteMeta.title.toLowerCase().includes(kw)) {
        matches.push({
          type: 'title',
          content: noteMeta.title,
          position: noteMeta.title.toLowerCase().indexOf(kw)
        });
      }

      // 搜索标签
      const tags = noteMeta.tags || [];
      for (const tag of tags) {
        if (tag.toLowerCase().includes(kw)) {
          matches.push({
            type: 'tag',
            content: tag,
            position: tag.toLowerCase().indexOf(kw)
          });
        }
      }

      // 全文检索：正文文本 + 闪卡问题/答案（F-05）
      // 即便标题/标签已命中，仍继续检索正文，使同一篇结果可同时呈现「标题命中」与「正文命中」两类匹配，
      // 并为列表卡片提供高亮预览片段。读取失败（文件损坏 / 存储未初始化）安全降级为不命中，绝不抛异常。
      const content: NoteContent | null = await this.loadNoteContent(noteMeta.id);
      if (content !== null) {
        const contentMatches: SearchMatch[] = this.searchInNoteContent(content, kw);
        for (let ci = 0; ci < contentMatches.length; ci++) {
          matches.push(contentMatches[ci]);
        }
      }

      // 任一维度命中即纳入结果（标题 / 标签 / 正文 / 闪卡）
      if (matches.length > 0) {
        results.push({
          noteId: noteMeta.id,
          noteMeta,
          matches,
          relevanceScore: this.calculateRelevanceScore(matches, kw)
        });
      }
    }
    
    // 按相关性排序
    results.sort((a, b) => b.relevanceScore - a.relevanceScore);
    
    return results;
  }
  
  /**
   * 计算相关性分数
   * @param matches 匹配项列表
   * @param keyword 关键词
   * @returns 相关性分数
   */
  private calculateRelevanceScore(matches: SearchMatch[], keyword: string): number {
    let score = 0;
    
    for (const match of matches) {
      switch (match.type) {
        case 'title':
          // 标题匹配权重最高
          score += 100;
          // 标题开头匹配额外加分
          if (match.position === 0) {
            score += 50;
          }
          break;
        case 'tag':
          // 标签匹配权重较高
          score += 80;
          break;
        case 'text':
          // 文本内容匹配权重中等
          score += 60;
          break;
        case 'flashcard':
          // 闪卡内容匹配权重中等
          score += 60;
          break;
      }
      
      // 完全匹配额外加分
      if (match.content.toLowerCase() === keyword.toLowerCase()) {
        score += 30;
      }
    }
    
    return score;
  }
  
  /**
   * 在笔记内容中搜索
   * @param content 笔记内容
   * @param keyword 关键词
   * @returns 匹配项列表
   */
  private searchInNoteContent(content: NoteContent, keyword: string): SearchMatch[] {
    const matches: SearchMatch[] = [];
    const kw = keyword.toLowerCase();
    
    // 搜索文本块内容
    const texts = content.texts || [];
    for (let i = 0; i < texts.length; i++) {
      const text = texts[i];
      const textContent = text.text || '';
      if (textContent.toLowerCase().includes(kw)) {
        matches.push({
          type: 'text',
          content: textContent,
          position: textContent.toLowerCase().indexOf(kw),
          pageIndex: 0, // HCText接口中没有pageIndex属性，使用默认值0
          textIndex: i
        });
      }
    }
    
    // 搜索闪卡内容
    const flashcards = content.flashcards || [];
    for (let i = 0; i < flashcards.length; i++) {
      const flashcard = flashcards[i];
      
      // 搜索问题
      if (flashcard.question && flashcard.question.toLowerCase().includes(kw)) {
        matches.push({
          type: 'flashcard',
          content: flashcard.question,
          position: flashcard.question.toLowerCase().indexOf(kw),
          pageIndex: 0 // HCFlashcard接口中没有pageIndex属性，使用默认值0
        });
      }
      
      // 搜索答案
      if (flashcard.answer && flashcard.answer.toLowerCase().includes(kw)) {
        matches.push({
          type: 'flashcard',
          content: flashcard.answer,
          position: flashcard.answer.toLowerCase().indexOf(kw),
          pageIndex: 0 // HCFlashcard接口中没有pageIndex属性，使用默认值0
        });
      }
    }
    
    return matches;
  }
  
  /**
   * 加载笔记内容（异步）
   * @param noteId 笔记ID
   * @returns 笔记内容或null
   */
  private async loadNoteContent(noteId: string): Promise<NoteContent | null> {
    try {
      // 经 NoteEngine 门面读取笔记内容（铁律：服务层不直接依赖 NoteRepository 实现类）
      const repo = this.noteEngine.getNoteRepository();
      const loadResult = await repo.loadNote(noteId);
      if (!loadResult.ok) {
        return null;
      }
      return loadResult.content;
    } catch (error) {
      Logger.error(TAG, 'Failed to load note content for search: ' + noteId + ', error: ' + JSON.stringify(error));
      return null;
    }
  }
  
  /**
   * 获取搜索建议
   * @param keyword 部分关键词
   * @param notes 笔记列表
   * @returns 建议列表
   */
  getSearchSuggestions(keyword: string, notes: NoteMeta[]): string[] {
    const kw = keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return [];
    }
    
    const suggestions = new Set<string>();
    
    for (const noteMeta of notes) {
      // 标题建议
      if (noteMeta.title.toLowerCase().includes(kw)) {
        suggestions.add(noteMeta.title);
      }
      
      // 标签建议
      const tags = noteMeta.tags || [];
      for (const tag of tags) {
        if (tag.toLowerCase().includes(kw)) {
          suggestions.add(tag);
        }
      }
    }
    
    return Array.from(suggestions).slice(0, 5); // 最多返回5条建议
  }
}