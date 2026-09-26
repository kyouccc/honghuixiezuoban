/**
 * FlashcardStore.ets — 闪卡存储（v3.1 审核修复）
 *
 * v3.1 修复：
 *  - 之前每次 FlashcardPage 创建都 `new FlashcardStore()`，临时内存态，添加闪卡后
 *    关闭页面/重启 App 即丢失 → "无法添加闪卡"。
 *  - 现改为单例 + Preferences 持久化（独立于具体笔记，作为"闪卡库"全局共享）。
 *  - 持久化粒度：每次 add/update/remove/grade 后 300ms debounce 落盘。
 *
 * 设计：
 *  - 内存态即落盘态（HCFlashcard），无独立领域对象，避免双份映射；
 *  - 单例承载，不直接触盘——由 setCardsChanged 触发外部落盘；
 *  - 本类只做内存 CRUD + 排序 + 持久化缓存，供 FlashcardPage 使用。
 */

import { preferences } from '@kit.ArkData';
import { HCFlashcard } from '../types/NoteModel';
import { Logger } from '../../common/Logger';

const TAG_MODULE = 'FlashcardStore';
const PREF_NAME = 'flashcard_store';
const KEY_CARDS = 'cards';

export class FlashcardStore {
  private static instance: FlashcardStore | null = null;
  private cards: HCFlashcard[] = [];
  private loaded: boolean = false;
  private saveTimer: number = -1;
  /** v3.1：仅全局单例开启持久化；WhiteboardPage 的笔记级实例（随 NoteContent 落盘）不写全局库 */
  private persistable: boolean = false;

  // v3.1：构造函数保持 public —— WhiteboardPage 以笔记级实例使用（new FlashcardStore()，
  // 数据随 NoteContent.flashcards 落盘）；全局闪卡库入口用 getInstance()（Preferences 持久化）。
  constructor() {}

  /** v3.1：单例入口，跨页面共享同一份闪卡数据（开启 Preferences 持久化） */
  static getInstance(): FlashcardStore {
    if (FlashcardStore.instance === null) {
      const inst: FlashcardStore = new FlashcardStore();
      inst.persistable = true;
      FlashcardStore.instance = inst;
    }
    return FlashcardStore.instance;
  }

  /** 从 Preferences 异步加载（仅全局单例；笔记级实例数据由 replaceAll 注入，跳过） */
  async load(): Promise<void> {
    if (this.loaded || !this.persistable) {
      return;
    }
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      const dataStr = await pref.get(KEY_CARDS, '[]') as string;
      const parsed = JSON.parse(dataStr) as HCFlashcard[];
      this.cards = Array.isArray(parsed) ? parsed : [];
      this.loaded = true;
      Logger.info(TAG_MODULE, `load: 加载 ${this.cards.length} 张闪卡`);
    } catch (error) {
      Logger.error(TAG_MODULE, 'load 失败: ' + JSON.stringify(error));
      this.cards = [];
      this.loaded = true;
    }
  }

  /** 防抖持久化（300ms）—— add/update/remove/grade 后调用（仅全局单例生效） */
  private scheduleSave(): void {
    if (!this.persistable) {
      return;
    }
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveNow();
    }, 300) as number;
  }

  /** 立即同步落盘（页面退出/卸载前可调用；仅全局单例生效） */
  async saveNow(): Promise<void> {
    if (!this.persistable) {
      return;
    }
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, PREF_NAME);
      await pref.put(KEY_CARDS, JSON.stringify(this.cards));
      await pref.flush();
      Logger.info(TAG_MODULE, `saveNow: 已保存 ${this.cards.length} 张闪卡`);
    } catch (error) {
      Logger.error(TAG_MODULE, 'saveNow 失败: ' + JSON.stringify(error));
    }
  }

  /** 全部闪卡（副本，防外部篡改） */
  list(): HCFlashcard[] {
    return this.cards.slice();
  }

  /** 到期闪卡（dueAt <= now，按 dueAt 升序——最该复习的排前面） */
  dueCards(now: number): HCFlashcard[] {
    const result: HCFlashcard[] = [];
    for (let i = 0; i < this.cards.length; i++) {
      if (this.cards[i].dueAt > 0 && this.cards[i].dueAt <= now) {
        result.push(this.cards[i]);
      }
    }
    result.sort((a: HCFlashcard, b: HCFlashcard): number => a.dueAt - b.dueAt);
    return result;
  }

  /** 新建闪卡（box=0 新卡，默认 ease/interval） */
  add(question: string, answer: string): HCFlashcard {
    const card: HCFlashcard = {
      id: `card_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`,
      question: question !== undefined && question.length > 0 ? question : '未命名问题',
      answer: answer !== undefined ? answer : '',
      box: 0,
      ease: 2.5,
      interval: 0,
      dueAt: Date.now(),
      reps: 0,
      lapses: 0,
      createdAt: Date.now(),
    };
    this.cards.push(card);
    // v3.1 修复：立刻落盘，避免添加后页面丢失
    this.scheduleSave();
    return card;
  }

  /** 更新闪卡（问题/答案），返回新对象（不可变语义） */
  update(cardId: string, question: string, answer: string): HCFlashcard | null {
    for (let i = 0; i < this.cards.length; i++) {
      if (this.cards[i].id === cardId) {
        const updated: HCFlashcard = {
          id: this.cards[i].id,
          question: question !== undefined && question.length > 0 ? question : this.cards[i].question,
          answer: answer !== undefined ? answer : this.cards[i].answer,
          box: this.cards[i].box,
          ease: this.cards[i].ease,
          interval: this.cards[i].interval,
          dueAt: this.cards[i].dueAt,
          reps: this.cards[i].reps,
          lapses: this.cards[i].lapses,
          createdAt: this.cards[i].createdAt,
        };
        this.cards[i] = updated;
        this.scheduleSave();
        return updated;
      }
    }
    return null;
  }

  /** 删除闪卡 */
  remove(cardId: string): boolean {
    const next: HCFlashcard[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.cards.length; i++) {
      if (this.cards[i].id === cardId) {
        removed = true;
      } else {
        next.push(this.cards[i]);
      }
    }
    this.cards = next;
    if (removed) {
      this.scheduleSave();
    }
    return removed;
  }

  /** 整体替换（加载笔记 / 保存后同步） */
  replaceAll(cards: HCFlashcard[]): void {
    this.cards = cards !== undefined && cards !== null ? cards.slice() : [];
    this.scheduleSave();
  }

  /** 闪卡数量 */
  count(): number {
    return this.cards.length;
  }

  /** 按 id 查找 */
  find(cardId: string): HCFlashcard | null {
    for (let i = 0; i < this.cards.length; i++) {
      if (this.cards[i].id === cardId) {
        return this.cards[i];
      }
    }
    return null;
  }
}

/** v3.1：单例便捷方法（保持与旧 import 兼容） */
export const flashcardStore = FlashcardStore.getInstance();