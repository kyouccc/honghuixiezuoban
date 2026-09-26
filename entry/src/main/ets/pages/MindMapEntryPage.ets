/**
 * MindMapEntryPage.ets — 思维导图独立入口页（v2.7.0 持久化修复）
 *
 * ══════════════════════════════════════════════════════════════════════
 * v2.7.0 审核修复（问题①-5「点击笔记详情返回导图列表后，内容清空」）
 *
 * 真因：本页此前只有一句 `@State map = MindMapModel.createEmpty(...)`，
 *   导图完全存在于内存中 —— 既没有从磁盘加载，也没有任何保存动作。
 *   于是「我的 → 思维导图 → 编辑 → 切走再回来（或从笔记详情返回）」
 *   内存态被重建，导图内容必然清空；`onClose` 还是空实现（点关闭无反应）。
 *
 * 修法：把独立导图绑定到一篇**专用笔记**（标题「思维导图」）：
 *   进入时读取该笔记的 mindmaps[0]，改动后防抖回写该笔记并落盘，
 *   与笔记内的思维导图共用同一套持久化链路（content.mindmaps）。
 * ══════════════════════════════════════════════════════════════════════
 */

import { router } from '@kit.ArkUI';
import { MindMapPage } from './MindMapPage';
import { HCMindMap, NoteContent, NoteMeta, NoteLoadResult, HC_DEFAULT_PAPER } from '../engine/types/NoteModel';
import { MindMapModel } from '../engine/types/MindMapModel';
import { NoteEngine } from '../engine/NoteEngine';
import { NoteRepository, NoteSaveResult } from '../engine/NoteRepository';
import { SafeAsync } from '../common/utils/SafeAsync';
import { Logger } from '../common/Logger';

const TAG = 'MindMapEntryPage';
/** 独立导图专用笔记的标题（用于在笔记列表中定位/创建） */
const DEDICATED_TITLE: string = '思维导图';
/** 改动后的落盘防抖（ms） */
const SAVE_DEBOUNCE_MS: number = 800;

/** v2.7.2：路由参数契约（从白板「扩展工具 → 思维导图」进入时携带 noteId） */
interface MindMapRouteParams {
  noteId?: string;
  title?: string;
}

@Entry
@Component
struct MindMapEntryPage {
  @State map: HCMindMap = MindMapModel.createEmpty('思维导图', '中心主题');
  /** 承载本页导图的笔记 id（空=尚未定位到） */
  private noteId: string = '';
  /** v2.7.2：true = 由白板带 noteId 进入（读写该笔记的导图），false = 独立导图专用笔记模式 */
  private boundToNote: boolean = false;
  private saveTimer: number = -1;

  aboutToAppear(): void {
    this.readRouteParams();
    this.loadOrCreate();
  }

  /** v2.7.2：读取路由参数，优先绑定到指定笔记 */
  private readRouteParams(): void {
    SafeAsync.runVoid(TAG, 'readRouteParams', (): void => {
      const params: MindMapRouteParams = router.getParams() as MindMapRouteParams;
      if (params !== null && params !== undefined) {
        const id: string = params.noteId !== undefined && params.noteId !== null ? params.noteId : '';
        if (id.length > 0) {
          this.noteId = id;
          this.boundToNote = true;
        }
      }
    });
  }

  aboutToDisappear(): void {
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
      this.saveTimer = -1;
    }
    // 退出前尽力保存一次
    this.persist();
  }

  /** 定位/创建承载笔记并读出导图 */
  private loadOrCreate(): void {
    SafeAsync.runAsyncVoid(TAG, 'loadOrCreate', async (): Promise<void> => {
      const engine: NoteEngine = NoteEngine.getInstance();
      if (!engine.isStorageReady()) {
        Logger.warn(TAG, '存储未就绪，暂以内存导图工作');
        return;
      }
      const repo: NoteRepository = engine.getNoteRepository();

      // v2.7.2：由白板带 noteId 进入 → 直接读写该笔记的导图，不再另建专用笔记
      if (this.boundToNote && this.noteId.length > 0) {
        const bound: NoteLoadResult = await repo.loadNote(this.noteId);
        if (bound.ok && bound.content.mindmaps !== undefined && bound.content.mindmaps !== null
            && bound.content.mindmaps.length > 0) {
          this.map = bound.content.mindmaps[0];
        }
        Logger.info(TAG, `已载入笔记导图 (noteId=${this.noteId}, nodes=${this.map.nodes.length})`);
        return;
      }

      const metas: NoteMeta[] = await repo.listNotes();
      let target: NoteMeta | null = null;
      for (let i = 0; i < metas.length; i++) {
        if (metas[i].title === DEDICATED_TITLE) {
          target = metas[i];
          break;
        }
      }
      if (target === null) {
        target = await repo.createNote(DEDICATED_TITLE, HC_DEFAULT_PAPER);
      }
      this.noteId = target.id;
      const loaded: NoteLoadResult = await repo.loadNote(target.id);
      if (loaded.ok && loaded.content.mindmaps !== undefined && loaded.content.mindmaps !== null
          && loaded.content.mindmaps.length > 0) {
        this.map = loaded.content.mindmaps[0];
        Logger.info(TAG, `已载入导图：${this.map.nodes.length} 个节点`);
      } else {
        this.map = MindMapModel.createEmpty('思维导图', '中心主题');
      }
    }, (info) => {
      Logger.error(TAG, `载入导图失败: ${info.message}`);
    });
  }

  /** 改动回调：更新内存态并防抖落盘 */
  private onMapChanged(newMap: HCMindMap): void {
    this.map = newMap;
    if (this.saveTimer !== -1) {
      clearTimeout(this.saveTimer);
    }
    this.saveTimer = setTimeout((): void => {
      this.saveTimer = -1;
      this.persist();
    }, SAVE_DEBOUNCE_MS);
  }

  /** 把当前导图写回专用笔记 */
  private persist(): void {
    const id: string = this.noteId;
    if (id.length === 0) {
      return;
    }
    const current: HCMindMap = this.map;
    SafeAsync.runAsyncVoid(TAG, 'persist', async (): Promise<void> => {
      const repo: NoteRepository = NoteEngine.getInstance().getNoteRepository();
      const loaded: NoteLoadResult = await repo.loadNote(id);
      if (!loaded.ok) {
        Logger.warn(TAG, '导图落盘失败：无法读取承载笔记');
        return;
      }
      const content: NoteContent = loaded.content;
      content.mindmaps = [current];
      const result: NoteSaveResult = await repo.saveNote(content, true);
      if (result.ok) {
        Logger.info(TAG, `导图已保存：${current.nodes.length} 个节点`);
      } else {
        Logger.error(TAG, `导图保存失败: ${result.errorMessage}`);
      }
    });
  }

  build() {
    Column() {
      MindMapPage({
        map: this.map,
        onChanged: (newMap: HCMindMap): void => {
          this.onMapChanged(newMap);
        },
        onClose: (): void => {
          // 🔧 v2.7.0：原为空实现，点关闭无反应；改为返回上一页（并先落盘）
          this.persist();
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
    PageTransitionEnter({ duration: 300, curve: Curve.EaseOut })
    PageTransitionExit({ duration: 200, curve: Curve.EaseIn })
  }
}
