/**
 * FlashcardEntryPage.ets — 闪卡独立入口页（v2.7.2 支持「笔记内添加闪卡」）
 *
 * ══════════════════════════════════════════════════════════════════════
 * v2.7.2 审核修复（问题①-1「笔记-闪卡/导图，点击扩展工具无法添加」，连续两轮未过）
 *
 * 背景：v2.7.0/v2.7.1 把 `FlashcardPage` 作为**自定义组件嵌入白板 Stack**
 *   （v2.7.1 还补了显式 100%×100% 容器包裹），真机审核仍判「无法添加」——
 *   说明「把整页组件嵌进画布 Stack」这条路径在本工程里不可靠。
 *
 * 修法：改为**导航到本独立页**。这是一条**已被审核历轮验证可正常渲染**的路径
 *   （「我的 → 闪卡复习」一直能正常打开并操作）。
 *   为保持「在笔记内添加闪卡」的语义，本页支持路由参数 `noteId`：
 *     · 传了 noteId → 读写该笔记的 content.flashcards（随笔记原子落盘，
 *       因此笔记列表的「闪卡」筛选能命中该笔记）
 *     · 未传 noteId → 使用全局闪卡库（「我的 → 闪卡复习」原有行为，完全不变）
 * ══════════════════════════════════════════════════════════════════════
 */

import { router } from '@kit.ArkUI';
import { FlashcardPage } from './FlashcardPage';
import { FlashcardStore } from '../engine/memory/FlashcardStore';
import { NoteEngine } from '../engine/NoteEngine';
import { NoteRepository, NoteSaveResult } from '../engine/NoteRepository';
import { NoteContent, HCFlashcard, NoteLoadResult } from '../engine/types/NoteModel';
import { SafeAsync } from '../common/utils/SafeAsync';
import { Logger } from '../common/Logger';

const TAG: string = 'FlashcardEntryPage';

/** 路由参数契约 */
interface FlashcardRouteParams {
  noteId?: string;
  title?: string;
}

@Entry
@Component
struct FlashcardEntryPage {
  // v3.1：使用单例 store（与 FlashcardPage 内部一致）
  private store: FlashcardStore = FlashcardStore.getInstance();
  /** v2.7.2：承载闪卡的笔记 id（空 = 全局闪卡库模式） */
  private noteId: string = '';
  private saveTimer: number = -1;

  aboutToAppear(): void {
    this.readRouteParams();
    if (this.noteId.length > 0) {
      this.loadFromNote();
    }
  }

  aboutToDisappear(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    if (this.noteId.length > 0) {
      this.saveToNote();
    }
  }

  private readRouteParams(): void {
    SafeAsync.runVoid(TAG, 'readRouteParams', (): void => {
      const params: FlashcardRouteParams = router.getParams() as FlashcardRouteParams;
      if (params !== null && params !== undefined) {
        const id: string = params.noteId !== undefined && params.noteId !== null ? params.noteId : '';
        this.noteId = id;
      }
    });
  }

  /** 把笔记内的闪卡载入 store（笔记模式） */
  private loadFromNote(): void {
    const id: string = this.noteId;
    SafeAsync.runAsyncVoid(TAG, 'loadFromNote', async (): Promise<void> => {
      const repo: NoteRepository = NoteEngine.getInstance().getNoteRepository();
      const loaded: NoteLoadResult = await repo.loadNote(id);
      if (!loaded.ok) {
        Logger.warn(TAG, '笔记载入失败，闪卡按空处理');
        return;
      }
      const cards: HCFlashcard[] = loaded.content.flashcards !== undefined && loaded.content.flashcards !== null
        ? loaded.content.flashcards : [];
      this.store.replaceAll(cards);
      Logger.info(TAG, `已载入笔记闪卡 ${cards.length} 张 (noteId=${id})`);
    });
  }

  /** 把 store 写回笔记（笔记模式） */
  private saveToNote(): void {
    const id: string = this.noteId;
    if (id.length === 0) {
      return;
    }
    const cards: HCFlashcard[] = this.store.list();
    SafeAsync.runAsyncVoid(TAG, 'saveToNote', async (): Promise<void> => {
      const repo: NoteRepository = NoteEngine.getInstance().getNoteRepository();
      const loaded: NoteLoadResult = await repo.loadNote(id);
      if (!loaded.ok) {
        Logger.warn(TAG, '闪卡回写失败：笔记不可读');
        return;
      }
      const content: NoteContent = loaded.content;
      content.flashcards = cards;
      const result: NoteSaveResult = await repo.saveNote(content, true);
      Logger.info(TAG, result.ok ? `闪卡已保存 ${cards.length} 张` : `闪卡保存失败: ${result.errorMessage}`);
    });
  }

  build() {
    Column() {
      FlashcardPage({
        store: this.store,
        onChanged: (): void => {
          // 笔记模式：改动防抖回写笔记
          if (this.noteId.length === 0) {
            return;
          }
          if (this.saveTimer !== -1) {
            clearTimeout(this.saveTimer);
          }
          this.saveTimer = setTimeout((): void => {
            this.saveTimer = -1;
            this.saveToNote();
          }, 600);
        },
        // 🔴 v2.7.2：原为空实现（点关闭无反应）；改为返回上一页
        onClose: (): void => {
          if (this.noteId.length > 0) {
            this.saveToNote();
          }
          SafeAsync.runVoid(TAG, 'back', (): void => {
            router.back();
          });
        }
      })
    }
    .width('100%')
    .height('100%')
  }

  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
  }
}
