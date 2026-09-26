
/**
 * NotePage.ets — 我的笔记（应用首页，v2.4 阶段一 T1-4）
 *
 * 这是 v2.4 最重要的一次定位纠偏：
 *  在此之前，用户打开 App 看到的是一块**空白板子**，画完退出就没了，
 *  于是有了那句"功能一个都用不了"。本页把入口改成**笔记列表**——
 *  打开先看到自己的东西，点开继续写，退出自动存。
 *
 * 职责：
 *  1. 展示笔记列表（网格卡片，按 updatedAt 倒序）；
 *  2. 新建笔记（标题 + 底纸模板）→ 落盘 → 跳转 WhiteboardPage；
 *  3. 打开 / 重命名 / 删除笔记；
 *  4. 关键词过滤（本地内存过滤，无需扫盘）；
 *  5. 存储不可用时给出明确提示，而不是白屏（S-5）。
 *
 * 约束：
 *  - 页面层**不直接**接触 fileIo / preferences，一切经 NoteEngine 门面（铁律 2）；
 *  - onPageShow 每次回到本页都刷新列表——从白板返回后标题/时间/缩略图要立刻更新；
 *  - 「收藏」Tab 阶段一置灰不可点（U-7），避免做一半的功能误导用户。
 */

import { router, promptAction } from '@kit.ArkUI';
import { crashRecoveryService, CrashRecoveryData, RecoverOutcome } from '../common/services/CrashRecoveryService';
import { common } from '@kit.AbilityKit';
import { NoteEngine } from '../engine/NoteEngine';
import { NoteRepository } from '../engine/NoteRepository';
import { SafeAsync, SafeErrorInfo } from '../common/utils/SafeAsync';
import { Logger } from '../common/Logger';
import { NoteCard } from '../components/NoteCard';
import { PaperPicker } from '../components/PaperPicker';
import { BottomTabBar, TAB_KEY_NOTES } from '../components/BottomTabBar';
import { privacyConsentService } from '../common/services/PrivacyConsentService';
import { PrivacyConsentDialog } from '../common/components/PrivacyConsentDialog';
import { analytics } from '../common/services/AnalyticsService';
import { NoteSearchService, SearchResult } from '../common/services/NoteSearchService';
import { favoriteService } from '../common/services/FavoriteService';
import { HCColor, HCRadius, HCPrimary, HCGray, HCBrand, HCOverlay } from '../common/theme/DesignTokens';
import {
  NoteMeta,
  NoteRouteParams,
  PaperOption,
  HC_DEFAULT_PAPER,
} from '../engine/types/NoteModel';

const TAG_PAGE = 'NotePage';

/** v2.6.0：「最近」页签的时间窗（近 7 天有编辑） */
const RECENT_WINDOW_MS: number = 7 * 24 * 60 * 60 * 1000;
/** v2.6.0：闪卡/导图筛选的只读探测上限（防止笔记极多时一次性扫盘卡顿） */
const RICH_PROBE_LIMIT: number = 200;

/** 列表项：元信息 + 缩略图 dataURL（缩略图独立文件，读不到就空串走占位）+ 草稿待恢复标记 */
interface NoteListItem {
  meta: NoteMeta;
  thumb: string;
  /** T2-1b：是否存在「校验通过且比正文新」的未提交草稿（列表徽标） */
  hasPendingTmp: boolean;
}

/**
 * v2.6.0 审核修复（问题⑤真因）：
 *   ArkUI 规范——@Builder 默认按值传递参数，传入的状态变量变化【不会】刷新 @Builder 内部 UI。
 *   原 tabChip(label, switchable, onTap) 把 `switchable` 当值传入并在体内决定高亮，
 *   于是点击 Tab 时 onClick 生效（Toast 会弹），但「全部」的蓝色高亮**永远不动**，
 *   列表也不随 Tab 重排 —— 审核员实测即「筛选笔记全部无响应，且筛选笔记无高亮」。
 *   修法：改为传对象字面量（按引用传递），把决定外观的 selected 显式放入对象。
 */
interface TabChipParam {
  label: string;
  selected: boolean;
  onTap: () => void;
}

@Entry
@Component
struct NotePage {
  @State private items: NoteListItem[] = [];
  @State private keyword: string = '';
  @State private loading: boolean = true;
  @State private storageReady: boolean = false;
  @State private emptyHint: string = '还没有笔记，点右下角「+」开始第一篇';
  @State private searchResults: SearchResult[] = [];
  @State private isSearching: boolean = false;
  /** F-05：noteId → SearchResult 映射，供网格卡片渲染命中高亮预览片段 */
  @State private searchResultMap: Map<string, SearchResult> = new Map<string, SearchResult>();
  private searchTimer: number = 0;

  /** U-03：顶部 Tab 筛选（'all' 全部 / 'recent' 最近 / 'fav' 收藏 / 'flash' 闪卡 / 'mind' 导图） */
  // 🔧 修复：onActiveTabChange 改为 public 修饰符，避免 ArkUI @Watch 回调在某些版本
  //   因可见性为 private 而不触发（导致切换到 闪卡/导图 tab 时空状态文案不更新）
  @State @Watch('onActiveTabChange') activeTab: string = 'all';
  onActiveTabChange(): void {
    // 闪卡/导图筛选依赖内容探测，切换前确保已完成（只读、一次性、带缓存）
    if (this.activeTab === 'flash' || this.activeTab === 'mind') {
      this.ensureRichFlags();
    }
    this.refreshEmptyHint();
    // v2.6.0：Tab 切换给出「已切到 X · 命中 N 篇」的确定性反馈。
    //   审核员在笔记很少时无法从列表差异判断是否生效，必须有明确回执。
    const hit: number = this.visibleItems().length;
    const labelMap: Map<string, string> = new Map([
      ['all', '全部'], ['recent', '最近'], ['fav', '收藏'], ['flash', '闪卡'], ['mind', '导图']
    ]);
    this.toast(`已切到「${labelMap.get(this.activeTab) ?? this.activeTab}」· ${hit} 篇`);
  }
  /** U-12：收藏笔记 id 集合（本地内存态；阶段一仅过滤展示，持久化接入收藏功能） */
  @State private favoriteIds: Set<string> = new Set<string>();

  /**
   * v2.6.0：notes 内「是否含闪卡 / 思维导图」的探测结果位图（noteId → flags）。
   * 列表索引 NoteMeta 无此计数，故按需只读探测一次并缓存，供「闪卡 / 导图」筛选使用。
   */
  @State private richFlags: Map<string, number> = new Map<string, number>();
  /** 内容位图是否已探测（reload 时复位） */
  @State private richProbed: boolean = false;

  /**
   * 🔧 v2.7.0 审核修复（问题② 底部导航条适配）：
   *   底部悬浮按钮 / 列表留白需避开系统导航条真实高度（AppStorage hcSafeAreaBottom）。
   */
  @StorageProp('hcSafeAreaBottom') safeBottom: number = 0;

  private safeBottomInset(): number {
    const v: number = this.safeBottom;
    return v !== undefined && v !== null && v > 0 ? v : 0;
  }

  /**
   * v2.7.1：批注跳转的"自愈兜底"标记。
   *   true = 已发起跳转但尚未离开本页；onPageHide 置回 false 表示跳转确实生效。
   */
  /** v2.7.2：卡片「⋯」操作弹层状态（替代对长按菜单的依赖） */
  @State private showCardMenu: boolean = false;
  private cardMenuId: string = '';
  private cardMenuTitle: string = '';

  /** 新建面板 */
  @State private showCreate: boolean = false;
  @State private paperOptions: PaperOption[] = [];

  /** 重命名面板 */
  @State private showRename: boolean = false;
  @State private renameId: string = '';
  @State private renameText: string = '';

  /** 删除确认面板 */
  @State private showDelete: boolean = false;
  @State private deleteId: string = '';
  @State private deleteTitle: string = '';

  private engine: NoteEngine = NoteEngine.getInstance();
  private searchService: NoteSearchService = new NoteSearchService(NoteEngine.getInstance());

  // 🔧 修复：已接入华为平台隐私托管服务，移除自建隐私弹窗，避免出现两个隐私弹窗

  // ═══════════════════════════════════════════════════════════════
  // 生命周期
  // ═══════════════════════════════════════════════════════════════

  /** v2.5.6：是否存在待恢复的未保存内容 */
  @State hasPendingRecovery: boolean = false;
  /** v2.5.6：待恢复笔记标题 */
  @State recoveryTitle: string = '';

  aboutToAppear(): void {
    this.paperOptions = this.engine.getPaperOptions();
    this.reload();
    // 🔧 修复：已接入华为平台隐私托管，无需自建隐私弹窗检查
    this.loadFavorites();
    // 🔧 v2.5.6 审核修复：本页也提供未保存内容恢复入口（与 Index 横幅双保险）。
    //   审核录屏显示在笔记列表页出现"恢复未保存的内容"提示但点击无效，
    //   本页补一条可正常工作的恢复横幅，确保该入口始终可用。
    this.checkPendingRecovery();
  }

  /** v2.5.6：检测是否存在待恢复的未保存内容（v2.6.0：需上次确为异常退出） */
  private checkPendingRecovery(): void {
    try {
      if (crashRecoveryService.hasPendingRecovery()) {
        const data: CrashRecoveryData | null = crashRecoveryService.getRecoveryData();
        this.hasPendingRecovery = true;
        this.recoveryTitle = data && data.title.length > 0 ? data.title : '未命名笔记';
      }
    } catch (err) {
      Logger.warn(TAG_PAGE, 'checkPendingRecovery 跳过：恢复服务未就绪');
    }
  }

  /** v2.5.6：未保存内容恢复横幅（点击直接恢复，不经弹窗——弹窗异步 open 可能被拦截） */
  @Builder
  buildRecoveryBanner() {
    Row() {
      Column() {
        Text('检测到未保存的内容').fontSize(13).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
        Text(`「${this.recoveryTitle}」可恢复`).fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('立即恢复')
        .fontSize(12).fontColor(HCColor.SURFACE)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor(HCColor.PRIMARY)
        .borderRadius(8)
        .onClick((): void => {
          this.recoverNow();
        })

      Text('稍后')
        .fontSize(12).fontColor(HCColor.TEXT_TERTIARY)
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .margin({ left: 8 })
        .onClick((): void => {
          this.hasPendingRecovery = false;
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(HCColor.WARNING_BG)
    .border({ width: { bottom: 1 }, color: HCColor.DIVIDER })
  }

  /** v2.5.6：直接执行恢复（与 Index 同款：Toast 全程反馈 + 跳转编辑页） */
  private recovering: boolean = false;

  private async recoverNow(): Promise<void> {
    if (this.recovering) {
      return;
    }
    this.recovering = true;
    try {
      // v2.6.0：使用结构化恢复结果（含"另存为新笔记"兜底），失败可给出具体原因
      const outcome: RecoverOutcome = await crashRecoveryService.recoverNote();
      if (outcome.ok) {
        this.hasPendingRecovery = false;
        promptAction.showToast({
          message: outcome.importedAsNew ? '已恢复为新笔记' : '已恢复未保存内容',
          duration: 2000
        });
        router.pushUrl({
          url: 'pages/WhiteboardPage',
          params: { noteId: outcome.noteId, title: outcome.title }
        }).catch((err: Error) => {
          promptAction.showToast({ message: '已恢复，请到笔记列表打开', duration: 2500 });
        });
      } else {
        promptAction.showToast({ message: `恢复失败：${outcome.errorMessage}`, duration: 3000 });
      }
    } catch (err) {
      promptAction.showToast({ message: '恢复异常，未保存内容仍保留，可重试', duration: 3000 });
    } finally {
      this.recovering = false;
    }
  }

  /** 加载收藏状态 */
  private loadFavorites(): void {
    if (favoriteService.isReady()) {
      this.favoriteIds = favoriteService.getAllFavoriteIds();
      Logger.info(TAG_PAGE, `loadFavorites: 加载收藏状态成功，共 ${this.favoriteIds.size} 个收藏`);
    } else {
      Logger.warn(TAG_PAGE, 'loadFavorites: FavoriteService 未就绪');
    }
  }

  /** 从白板返回时刷新（标题 / 时间 / 笔画数 / 缩略图都可能变了） */
  onPageShow(): void {
    this.reload();
  }

  /**
   * v2.5.1：本页原先**没有** aboutToDisappear，搜索防抖定时器（searchTimer，300ms）
   * 永不清理 —— 用户输入关键字后 300ms 内离开页面，回调仍会向已销毁页面
   * 写入 isSearching / searchResults 等 @State。
   */
  aboutToDisappear(): void {
    if (this.searchTimer !== 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = 0;
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 数据
  // ═══════════════════════════════════════════════════════════════

  /** 等待存储初始化完成（最多等待 3 秒） */
  private async waitForStorage(): Promise<boolean> {
    const maxRetries: number = 6; // 6 次 × 500ms = 3 秒
    const interval: number = 500; // 每次间隔 500ms
    
    for (let i = 0; i < maxRetries; i++) {
      if (this.engine.isStorageReady()) {
        return true;
      }
      Logger.info(TAG_PAGE, `等待存储初始化... (${i + 1}/${maxRetries})`);
      await new Promise<void>((resolve: Function): void => {
        setTimeout((): void => {
          resolve();
        }, interval);
      });
    }
    return false;
  }

  /**
   * 重新加载列表。
   * 存储未就绪时不报错、不白屏，只把 storageReady 置 false 让顶部出提示条。
   */
  private reload(): void {
    SafeAsync.runAsyncVoid(TAG_PAGE, 'reload', async (): Promise<void> => {
      this.loading = true;
      
      // 等待存储初始化完成
      const ready: boolean = await this.waitForStorage();
      this.storageReady = ready;
      if (!ready) {
        this.items = [];
        this.loading = false;
        this.emptyHint = '本地存储尚未就绪，请稍候或重启应用';
        Logger.warn(TAG_PAGE, '存储未就绪，列表置空');
        return;
      }
      const repo: NoteRepository = this.engine.getNoteRepository();
      const metas: NoteMeta[] = await repo.listNotes();
      const next: NoteListItem[] = [];
      for (let i = 0; i < metas.length; i++) {
        const meta: NoteMeta = metas[i];
        const thumb: string = await repo.loadThumb(meta.id);
        // T2-1b：闸 B 判定（校验通过 + 比正文新），只有真草稿亮徽标
        const hasPendingTmp: boolean = repo.hasPendingTmp(meta.id);
        next.push({ meta: meta, thumb: thumb, hasPendingTmp: hasPendingTmp });
      }
      this.items = next;
      this.loading = false;
      // v2.6.0：列表变化后闪卡/导图内容位图失效，需重新探测
      this.richProbed = false;
      this.richFlags = new Map<string, number>();
      this.refreshEmptyHint();
      Logger.info(TAG_PAGE, `列表加载完成，共 ${next.length} 篇`);
    }, (info: SafeErrorInfo): void => {
      this.loading = false;
      this.emptyHint = `列表加载失败：${info.message}`;
    });
  }

  /** 根据当前 Tab 刷新空状态提示 */
  private refreshEmptyHint(): void {
    switch (this.activeTab) {
      case 'fav':
        this.emptyHint = '暂无收藏笔记，长按卡片可加入收藏';
        break;
      case 'flash':
        this.emptyHint = '暂无包含闪卡的笔记（在笔记内用扩展工具 → 闪卡添加）';
        break;
      case 'mind':
        this.emptyHint = '暂无包含思维导图的笔记（在笔记内用思维导图入口创建）';
        break;
      case 'recent':
        this.emptyHint = '最近 7 天没有编辑过的笔记';
        break;
      default:
        this.emptyHint = '还没有笔记，点右下角「+」开始第一篇';
        break;
    }
  }

  /**
   * v2.6.0 审核修复（问题⑤）：为「闪卡 / 导图」页签准备内容位图。
   * 列表索引不含闪卡/导图计数，故用 NoteRepository.peekContentFlags() 做**只读**文本探测，
   * 结果缓存在 richFlags（已探测过的 noteId 不重复扫盘）。上限 RICH_PROBE_LIMIT 条。
   */
  private ensureRichFlags(): void {
    if (this.richProbed) {
      return;
    }
    const repo: NoteRepository = this.engine.getNoteRepository();
    const next: Map<string, number> = new Map<string, number>();
    const limit: number = Math.min(this.items.length, RICH_PROBE_LIMIT);
    for (let i = 0; i < limit; i++) {
      const id: string = this.items[i].meta.id;
      next.set(id, repo.peekContentFlags(id));
    }
    this.richFlags = next;
    this.richProbed = true;
    Logger.info(TAG_PAGE, `闪卡/导图内容探测完成：${limit} 条`);
  }

  /** 关键词过滤（本地内存，不触盘） */
  /**
   * U-03：先按顶部 Tab 类型过滤，再按关键词过滤。
   * 'all' 不过滤；'recent' 按 updatedAt 倒序（与默认一致）；'fav' 收藏；'flash'/'mind' 类型占位（全部展示，注释保留类型识别扩展点）。
   */
  private visibleItems(): NoteListItem[] {
    // 第一步：Tab 类型过滤（v2.6.0：五个页签全部为**真实过滤**，不再有"展示全部"的占位）
    let base: NoteListItem[] = this.items;
    if (this.activeTab === 'fav') {
      base = this.items.filter((item: NoteListItem): boolean => this.favoriteIds.has(item.meta.id));
    } else if (this.activeTab === 'recent') {
      // 「最近」= 近 7 天有编辑（真实过滤；之前与「全部」完全同序 → 点了一点变化都没有）
      const cutoff: number = Date.now() - RECENT_WINDOW_MS;
      base = this.items.filter((item: NoteListItem): boolean => item.meta.updatedAt >= cutoff);
    } else if (this.activeTab === 'flash') {
      base = this.items.filter((item: NoteListItem): boolean => {
        const flags: number = this.richFlags.get(item.meta.id) ?? 0;
        return (flags & 1) === 1;
      });
    } else if (this.activeTab === 'mind') {
      base = this.items.filter((item: NoteListItem): boolean => {
        const flags: number = this.richFlags.get(item.meta.id) ?? 0;
        return (flags & 2) === 2;
      });
    }

    // 第二步：关键词过滤
    const kw: string = this.keyword.trim().toLowerCase();
    if (kw.length === 0) {
      return base;
    }
    
    // 如果正在搜索中，显示所有项目
    if (this.isSearching) {
      return base;
    }
    
    // 如果有搜索结果，显示匹配的笔记
    if (this.searchResults.length > 0) {
      const result: NoteListItem[] = [];
      for (const searchResult of this.searchResults) {
        const item = base.find(item => item.meta.id === searchResult.noteId);
        if (item) {
          result.push(item);
        }
      }
      return result;
    }
    
    // 备用搜索：使用简单的标题和标签搜索
    const result: NoteListItem[] = [];
    for (let i = 0; i < base.length; i++) {
      const item = base[i];
      const title: string = item.meta.title.toLowerCase();
      
      // 搜索标题
      if (title.indexOf(kw) >= 0) {
        result.push(item);
        continue;
      }
      
      // 搜索标签
      const tags = item.meta.tags || [];
      let tagMatch = false;
      for (let j = 0; j < tags.length; j++) {
        if (tags[j].toLowerCase().indexOf(kw) >= 0) {
          tagMatch = true;
          break;
        }
      }
      if (tagMatch) {
        result.push(item);
        continue;
      }
    }
    return result;
  }

  /** 按日期分组笔记（今天/昨天/更早） */
  private groupNotesByDate(items: NoteListItem[]): Map<string, NoteListItem[]> {
    const groups = new Map<string, NoteListItem[]>();
    const now = Date.now();
    const todayStart = new Date(now).setHours(0, 0, 0, 0);
    const yesterdayStart = todayStart - 86400000; // 24小时前
    
    for (const item of items) {
      const updatedAt = item.meta.updatedAt;
      let groupKey: string;
      
      if (updatedAt >= todayStart) {
        groupKey = '今天';
      } else if (updatedAt >= yesterdayStart) {
        groupKey = '昨天';
      } else {
        const date = new Date(updatedAt);
        const daysAgo = Math.floor((todayStart - updatedAt) / 86400000);
        if (daysAgo < 7) {
          groupKey = `${daysAgo}天前`;
        } else {
          groupKey = `${date.getMonth() + 1}月${date.getDate()}日`;
        }
      }
      
      if (!groups.has(groupKey)) {
        groups.set(groupKey, []);
      }
      groups.get(groupKey)!.push(item);
    }
    
    return groups;
  }

  /**
   * 安全取某个日期分组下的笔记。
   *
   * 🔧 v2.5.1 崩溃修复：原代码在 UI 里直接写 `groupNotesByDate(...).get(groupKey)!`，
   *   Map.get() 在 key 不存在时返回 undefined，`!` 会把它强转为非空类型，
   *   随后 `.length` / ForEach 遍历即触发空指针崩溃。
   *   这里显式判空并退化为空数组 —— 最坏情况只是该分组暂时不显示，绝不崩。
   */
  private notesInGroup(groupKey: string): NoteListItem[] {
    const grouped: Map<string, NoteListItem[]> = this.groupNotesByDate(this.visibleItems());
    const list: NoteListItem[] | undefined = grouped.get(groupKey);
    return list !== undefined && list !== null ? list : [];
  }

  private toast(message: string): void {
    SafeAsync.runVoid(TAG_PAGE, 'toast', (): void => {
      promptAction.showToast({ message: message, duration: 2000 });
    });
  }

  // ═══════════════════════════════════════════════════════════════
  // 操作
  // ═══════════════════════════════════════════════════════════════

  /** 新建：先落盘再跳转，保证「列表里能看到的，一定打得开」 */
  private doCreate(title: string, template: string): void {
    this.showCreate = false;
    if (!this.storageReady) {
      this.toast('本地存储不可用，暂时无法新建');
      return;
    }
    SafeAsync.runAsyncVoid(TAG_PAGE, 'createNote', async (): Promise<void> => {
      const repo: NoteRepository = this.engine.getNoteRepository();
      const safeTemplate: string = this.engine.normalizePaperTemplate(template);
      const meta: NoteMeta = await repo.createNote(title, safeTemplate);
      Logger.info(TAG_PAGE, `新建笔记 ${meta.id}`);
      this.openNote(meta.id, meta.title, meta.paperTemplate, true);
    }, (info: SafeErrorInfo): void => {
      this.toast(`新建失败：${info.message}`);
    });
  }

  private openNoteById(noteId: string): void {
    const item: NoteListItem | null = this.findItem(noteId);
    if (item === null) {
      this.toast('笔记不存在，正在刷新列表');
      this.reload();
      return;
    }
    this.openNote(item.meta.id, item.meta.title, item.meta.paperTemplate, false);
  }

  /** 跳转白板。路由参数契约见 NoteModel.NoteRouteParams */
  private openNote(noteId: string, title: string, paperTemplate: string, isNew: boolean): void {
    const params: NoteRouteParams = {
      noteId: noteId,
      title: title,
      paperTemplate: paperTemplate.length > 0 ? paperTemplate : HC_DEFAULT_PAPER,
      isNew: isNew,
    };
    SafeAsync.runVoid(TAG_PAGE, 'pushWhiteboard', (): void => {
      router.pushUrl({ url: 'pages/WhiteboardPage', params: params })
        .catch((err: Error): void => {
          Logger.error(TAG_PAGE, `跳转白板失败: ${SafeAsync.describe(err)}`);
          this.toast('打开笔记失败，请重试');
        });
    });
  }

  /**
   * 跳批注页（T2-1 入口）：长按列表项 / 卡片「⋯」→ 批注。
   *
   * ══════════════════════════════════════════════════════════════════════
   * 🔴 v2.7.2 审核修复（问题②-4「笔记-笔记列表-批注：点击无反应」，连续两轮未过）
   *
   * 逐帧证据（第九轮录屏 v01_003 / v01_004）：长按菜单**正常弹出**，
   *   点「批注」后菜单消失，但页面不切换、**且连第一行的 Toast 都没出现**。
   *
   * 结论：MenuItem 的 onClick 在真机上不可靠（v2.7.1 我加的 navPending/onPageHide
   *   自愈兜底也因此完全没有机会执行 —— 回调压根没进来）。
   *
   * 修法（两条路径同时提供，任一条可用即可）：
   *   ① 卡片上新增**始终可见的「⋯」按钮** → 页内操作弹层（与重命名/删除对话框同一套
   *      已在本工程稳定工作的机制），不再依赖长按菜单；
   *   ② 保留长按菜单，并把 `bindContextMenu` 改为**传 Builder 引用**（ArkUI 文档写法）。
   *   本方法本身也简化为「直接跳转 + 失败提示」，去掉 v2.7.1 那套依赖页面生命周期的脆弱兜底。
   * ══════════════════════════════════════════════════════════════════════
   */
  private openAnnotate(noteId: string): void {
    const item: NoteListItem | null = this.findItem(noteId);
    const params: NoteRouteParams = {
      noteId: noteId,
      title: item !== null && item.meta.title.length > 0 ? item.meta.title : '文档批注',
      paperTemplate: item !== null && item.meta.paperTemplate.length > 0
        ? item.meta.paperTemplate : HC_DEFAULT_PAPER,
      isNew: false,
    };
    this.toast('正在打开批注…');
    SafeAsync.runVoid(TAG_PAGE, 'pushAnnotation', (): void => {
      router.pushUrl({ url: 'pages/AnnotationPage', params: params })
        .catch((err: Error): void => {
          Logger.error(TAG_PAGE, `跳转批注页失败: ${SafeAsync.describe(err)}`);
          this.toast('批注页不可用，已改用白板批注');
          this.openNote(params.noteId, params.title, params.paperTemplate, false);
        });
    });
  }

  /** v2.7.2：卡片「⋯」→ 打开页内操作弹层（不依赖长按菜单） */
  private openCardMenu(noteId: string): void {
    const item: NoteListItem | null = this.findItem(noteId);
    if (item === null) {
      return;
    }
    this.cardMenuId = noteId;
    this.cardMenuTitle = item.meta.title.length > 0 ? item.meta.title : '未命名笔记';
    this.showCardMenu = true;
  }

  private beginRename(noteId: string): void {
    const item: NoteListItem | null = this.findItem(noteId);
    if (item === null) {
      return;
    }
    this.renameId = noteId;
    this.renameText = item.meta.title;
    this.showRename = true;
  }

  private commitRename(): void {
    const id: string = this.renameId;
    const title: string = this.renameText.trim();
    this.showRename = false;
    if (id.length === 0 || title.length === 0) {
      return;
    }
    // 🔴 v2.7.1 审核修复（问题③-3「笔记列表-重命名：笔记名更新不及时」）：
    //   两个原因叠加 ——
    //   ① 此前只等异步 renameNote + reload 落盘后才更新，用户看到明显延迟；
    //   ② 列表 ForEach 的 key 为 `${id}_${updatedAt}_${d/n}`，**不含标题**，
    //      标题变化时 key 不变 → ArkUI 复用旧列表项，界面不重建。
    //   修法：先就地改内存态并整体换数组（立即刷新），再异步落盘 + reload 校正。
    this.patchItemTitle(id, title);
    SafeAsync.runAsyncVoid(TAG_PAGE, 'renameNote', async (): Promise<void> => {
      const ok: boolean = await this.engine.getNoteRepository().renameNote(id, title);
      if (ok) {
        this.toast('已重命名');
      } else {
        this.toast('重命名失败');
      }
      this.reload();
    }, (info: SafeErrorInfo): void => {
      this.toast(`重命名失败：${info.message}`);
      this.reload();
    });
  }

  /** v2.7.1：就地更新列表项标题（不等落盘，界面即时反馈） */
  private patchItemTitle(noteId: string, title: string): void {
    for (let i = 0; i < this.items.length; i++) {
      const it: NoteListItem = this.items[i];
      if (it.meta.id !== noteId) {
        continue;
      }
      const meta: NoteMeta = it.meta;
      meta.title = title;
      const patched: NoteListItem = { meta: meta, thumb: it.thumb, hasPendingTmp: it.hasPendingTmp };
      this.items[i] = patched;
      this.items = this.items.slice();   // 整体换数组 → 触发 @State 刷新
      return;
    }
  }

  private beginDelete(noteId: string): void {
    const item: NoteListItem | null = this.findItem(noteId);
    if (item === null) {
      return;
    }
    this.deleteId = noteId;
    this.deleteTitle = item.meta.title;
    this.showDelete = true;
  }

  private commitDelete(): void {
    const id: string = this.deleteId;
    this.showDelete = false;
    if (id.length === 0) {
      return;
    }
    SafeAsync.runAsyncVoid(TAG_PAGE, 'deleteNote', async (): Promise<void> => {
      const ok: boolean = await this.engine.getNoteRepository().deleteNote(id);
      this.toast(ok ? '已删除' : '删除失败');
      this.reload();
    }, (info: SafeErrorInfo): void => {
      this.toast(`删除失败：${info.message}`);
    });
  }

  /** U-12：收藏/取消收藏（持久化存储，切换后收藏 Tab 实时过滤） */
  private toggleFavorite(noteId: string): void {
    SafeAsync.runAsyncVoid(TAG_PAGE, 'toggleFavorite', async (): Promise<void> => {
      const isFavorite = await favoriteService.toggleFavorite(noteId);
      
      // 更新内存状态
      if (isFavorite) {
        this.favoriteIds.add(noteId);
        this.toast('已收藏');
      } else {
        this.favoriteIds.delete(noteId);
        this.toast('已取消收藏');
      }
      
      // 触发 UI 刷新（Set 变更需要重新赋值驱动 @State 更新）
      const next: Set<string> = new Set<string>(this.favoriteIds);
      this.favoriteIds = next;
    }, (info: SafeErrorInfo): void => {
      this.toast(`操作失败：${info.message}`);
    });
  }

  private findItem(noteId: string): NoteListItem | null {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].meta.id === noteId) {
        return this.items[i];
      }
    }
    return null;
  }

  /**
   * 执行搜索（带防抖）
   * @param keyword 搜索关键词
   */
  private async performSearch(keyword: string): Promise<void> {
    const kw = keyword.trim();
    
    // 清除之前的计时器
    if (this.searchTimer) {
      clearTimeout(this.searchTimer);
    }
    
    // 清空之前的搜索结果
    this.searchResults = [];
    
    if (kw.length === 0) {
      return;
    }
    
    // 设置防抖计时器（300毫秒）
    this.searchTimer = setTimeout(async (): Promise<void> => {
      // 设置搜索状态
      this.isSearching = true;
      
      try {
        // 提取笔记元数据列表
        const noteMetas = this.items.map(item => item.meta);
        
        // 使用搜索服务进行搜索
        const results = await this.searchService.searchNotes(kw, noteMetas);
        
        // 更新搜索结果
        this.searchResults = results;
        // 构建 noteId → SearchResult 映射，供列表卡片渲染高亮预览片段
        const map: Map<string, SearchResult> = new Map<string, SearchResult>();
        for (let ri = 0; ri < results.length; ri++) {
          map.set(results[ri].noteId, results[ri]);
        }
        this.searchResultMap = map;
      } catch (error) {
        Logger.error('NotePage', '搜索失败: ' + JSON.stringify(error));
        // 搜索失败时，回退到简单的标题和标签搜索
        this.searchResults = [];
      } finally {
        this.isSearching = false;
      }
    }, 300) as number;
  }

  // ═══════════════════════════════════════════════════════════════
  // 视图
  // ═══════════════════════════════════════════════════════════════

  /**
   * F-05：从搜索结果取首个正文/闪卡匹配，截取关键词前后预览片段（供列表卡片高亮预览）。
   * 未命中返回空串（卡片据此不渲染预览行）。
   */
  private buildMatchPreview(result: SearchResult): string {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return '';
    }
    const lowerKw: string = kw.toLowerCase();
    const matches = result.matches;
    for (let i = 0; i < matches.length; i++) {
      const m = matches[i];
      if (m.type !== 'text' && m.type !== 'flashcard') {
        continue;
      }
      const content: string = m.content;
      if (content.length === 0) {
        continue;
      }
      const idx: number = content.toLowerCase().indexOf(lowerKw);
      if (idx < 0) {
        continue;
      }
      const start: number = idx - 12 > 0 ? idx - 12 : 0;
      const end: number = idx + kw.length + 12 < content.length ? idx + kw.length + 12 : content.length;
      let snippet: string = content.substring(start, end);
      if (start > 0) {
        snippet = '…' + snippet;
      }
      if (end < content.length) {
        snippet = snippet + '…';
      }
      return snippet;
    }
    return '';
  }

  /**
   * F-05：按笔记 id 取该笔记的命中预览片段；无命中或非搜索态返回空串。
   * 供 ForEach 的 item 构造直接取值——@Builder / ForEach 体内不允许写 const 裸语句，
   * 故把「查表 + 生成片段」两步收敛到这个普通私有方法里。
   */
  private previewFor(noteId: string): string {
    const hit: SearchResult | undefined = this.searchResultMap.get(noteId);
    if (hit === undefined) {
      return '';
    }
    return this.buildMatchPreview(hit);
  }

  build() {
    // F-04：整体右底对齐（FAB + BottomTabBar 都靠底），Column 占满剩余
    Stack({ alignContent: Alignment.BottomEnd }) {
      // ── 主体 ──
      Column() {
        this.headerBar()
        // v2.5.6：未保存内容恢复入口（检测到恢复数据时显示）
        if (this.hasPendingRecovery) {
          this.buildRecoveryBanner()
        }
        this.searchBar()
        this.tabBar()

        if (!this.storageReady) {
          this.warningBanner()
        }

        // 列表区（FAB 提升到最外层 Stack 避开 BottomTabBar 遮挡）
        Stack({ alignContent: Alignment.Center }) {
          if (this.loading) {
            this.loadingView()
          } else if (this.isSearching) {
            this.searchingView()
          } else if (this.items.length === 0) {
            // 🔧 审核 v2.4 修复：仅在「全库真的没有任何笔记」时显示"还没有笔记"，
            //   避免视频(4)f2 那种"header 显示 3 篇 / body 显示还没有笔记"自相矛盾。
            //   之前用 visibleItems().length===0 会把"有笔记但被 tab/收藏过滤掉"也归到这里。
            this.emptyView()
          } else if (this.visibleItems().length === 0) {
            this.noSearchResultsView()
          } else {
            this.gridView()
          }
        }
        .width('100%')
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HCColor.PAGE_BG)

      // ── 悬浮新建按钮（FAB）── 用 alignContent: BottomEnd + margin bottom 避开 BottomTabBar
      // BottomTabBar 高 88vp（pill 64 + home indicator 24）→ margin bottom 116vp = 28vp 间距
      Button() {
        Text('+')
          .fontSize(30)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .backgroundColor(HCColor.PRIMARY)
      .shadow({ radius: 12, color: HCOverlay.SHADE_BLUE, offsetX: 0, offsetY: 4 })
      // v2.7.0：叠加真实底部避让（问题② 底部导航条适配）
      .margin({ right: 20, bottom: 116 + this.safeBottomInset() })
      .onClick((): void => {
        this.showCreate = true;
      })

      // ── 底部 Tab 骨架（U-01：笔记/协作/我的）──
      BottomTabBar({ activeKey: TAB_KEY_NOTES })
        .width('100%')

      // ── 浮层：新建（底部抽屉样式）──
      if (this.showCreate) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.MASK_40)
          .onClick((): void => {
            this.showCreate = false;
          })

        Column() {
          PaperPicker({
            paperOptions: this.paperOptions,
            defaultTitle: '',
            onConfirm: (title: string, template: string): void => {
              this.doCreate(title, template);
            },
            onCancel: (): void => {
              this.showCreate = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
      }

      // ── 浮层：重命名（居中弹窗）──
      if (this.showRename) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.MASK_40)
          .onClick((): void => {
            this.showRename = false;
          })
        this.renamePanel()
      }

      // ── 浮层：删除确认（居中弹窗）──
      if (this.showDelete) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.MASK_40)
          .onClick((): void => {
            this.showDelete = false;
          })
        this.deletePanel()
      }

      // ── 浮层：卡片操作菜单（v2.7.2 新增）──
      //   由卡片上**始终可见的「⋯」按钮**打开，提供 收藏/重命名/批注/删除。
      //   与长按菜单并存，但**不依赖** bindContextMenu（该路径在真机上不可靠，
      //   连续两轮导致「批注点击无反应」「重命名更新不及时」）。
      if (this.showCardMenu) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.MASK_40)
          .onClick((): void => {
            this.showCardMenu = false;
          })
        this.cardMenuPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 页面转场动画 */
  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }

  @Builder
  headerBar() {
    // PRD v5 布局整改：顶部品牌+计数+操作合 1 行，节省 70% 顶部空间
    Row() {
      Column() {
        // 品牌名
        Text('鸿绘协作板')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(HCColor.TEXT_PRIMARY)
      }
      .alignItems(HorizontalAlign.Start)
      .width(140)

      Blank()

      // 计数 inline 到头部右侧（不单独占 1 行）
      Text(this.keyword.trim().length > 0 && !this.isSearching ?
        `${this.visibleItems().length}/${this.items.length}` :
        `${this.items.length} 篇`)
        .fontSize(11)
        .fontColor(this.keyword.trim().length > 0 && !this.isSearching ? HCColor.PRIMARY : HCColor.TEXT_TERTIARY)
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(10)
        .margin({ right: 8 })

      // 进入导航中心（协作 / 设备 / 隐私等能力仍保留）
      Button('更多')
        .height(30)
        .fontSize(12)
        .fontColor(HCColor.TEXT_SECONDARY)
        .backgroundColor(HCColor.DIVIDER)
        .padding({ left: 12, right: 12 })
        .onClick((): void => {
          SafeAsync.runVoid(TAG_PAGE, 'pushIndex', (): void => {
            router.pushUrl({ url: 'pages/Index' });
          });
        })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 14, bottom: 6 })
  }

  @Builder
  searchBar() {
    Row() {
      // F-02：用文字标签替代 Emoji 跨设备不一致
      Text('搜索')
        .fontSize(12)
        .fontColor(HCColor.TEXT_TERTIARY)
        .margin({ right: 8 })
      TextInput({ text: this.keyword, placeholder: '搜索标题、标签、正文' })
        .layoutWeight(1)
        .height(38)
        .fontSize(14)
        .backgroundColor(Color.Transparent)
        .padding(0)
        .onChange((value: string): void => {
          this.keyword = value;
          // 触发搜索
          this.performSearch(value);
        })
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .margin({ left: 20, right: 20 })
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(10)
    .border({ width: 1, color: HCColor.DIVIDER })
  }

  @Builder
  tabBar() {
    Scroll() {
      Row() {
        // 全部（默认激活）
        this.tabChip({ label: '全部', selected: this.activeTab === 'all',
          onTap: () => { this.activeTab = 'all'; } })

        // 最近：仅保留近 7 天有编辑的笔记（真实过滤，非"与全部同序"）
        this.tabChip({ label: '最近', selected: this.activeTab === 'recent',
          onTap: () => { this.activeTab = 'recent'; } })

        // 收藏：真实过滤（favoriteIds 集合）
        this.tabChip({ label: '收藏', selected: this.activeTab === 'fav',
          onTap: () => { this.activeTab = 'fav'; } })

        // 闪卡：按笔记内是否含闪卡过滤（v2.6.0 起为真实过滤）
        this.tabChip({ label: '闪卡', selected: this.activeTab === 'flash',
          onTap: () => { this.activeTab = 'flash'; } })

        // 导图：按笔记内是否含思维导图过滤（v2.6.0 起为真实过滤）
        this.tabChip({ label: '导图', selected: this.activeTab === 'mind',
          onTap: () => { this.activeTab = 'mind'; } })
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
    .height(44) // 固定高度，避免横向 Scroll 在 Column 内塌陷
    .padding({ left: 20, right: 20, top: 12, bottom: 8 })
  }

  /**
   * U-03：单 Tab 胶囊（可复用）。
   * v2.6.0：改为对象字面量传参（按引用传递）→ 选中高亮随 activeTab 实时刷新。
   * 点击后由调用方统一给出「结果条数」反馈，避免用户误判为无响应。
   */
  @Builder
  tabChip($$: TabChipParam) {
    Text($$.label)
      .fontSize(13)
      .fontWeight($$.selected ? FontWeight.Medium : FontWeight.Regular)
      .fontColor($$.selected ? HCColor.SURFACE : HCColor.TEXT_PRIMARY)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor($$.selected ? HCColor.PRIMARY : HCColor.SURFACE)
      .borderRadius(HCRadius.SM)
      .border({ width: $$.selected ? 0 : 1, color: HCColor.DIVIDER })
      .margin({ right: 8 })
      .onClick((): void => {
        if (!$$.selected) {
          $$.onTap();
        }
      })
  }

  @Builder
  warningBanner() {
    Row() {
      // F-02：纯文字标签替代 ⚠ Emoji（跨设备渲染一致性）
      Text('提示')
        .fontSize(11)
        .fontColor(HCColor.WARNING)
        .fontWeight(FontWeight.Bold)
        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        .borderRadius(4)
        .backgroundColor(HCColor.WARNING_BG)
        .margin({ right: 8 })
      Text('本地存储初始化未完成，暂时无法保存笔记')
        .fontSize(12)
        .fontColor(HCColor.WARNING)
        .layoutWeight(1)
      Button('重试')
        .height(26)
        .fontSize(12)
        .fontColor(HCColor.WARNING)
        .backgroundColor(HCColor.WARNING_BG)
        .onClick((): void => {
          this.reload();
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .margin({ left: 20, right: 20, bottom: 6 })
    .backgroundColor(HCColor.WARNING_BG)
    .borderRadius(8)
  }

  @Builder
  loadingView() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(HCColor.PRIMARY)
      Text('正在加载笔记…')
        .fontSize(13)
        .fontColor(HCColor.TEXT_TERTIARY)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  searchingView() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(HCColor.PRIMARY)
      Text('正在搜索…')
        .fontSize(13)
        .fontColor(HCColor.TEXT_TERTIARY)
        .margin({ top: 10 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  noSearchResultsView() {
    // PRD v5：与 emptyView 风格统一
    // 🔧 修复：标题改读 this.emptyHint（refreshEmptyHint 已按 activeTab 设置正确文案），
    //   切换到 闪卡/导图 tab 时不再显示"暂无收藏笔记..."
    Column() {
      Text(this.emptyHint)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ top: 32 })

      // 搜索态：保留关键词提示；非搜索态：按 tab 引导返回"全部"
      if (this.keyword.length > 0) {
        Row() {
          Text('关键词 ').fontSize(13).fontColor(HCColor.TEXT_TERTIARY)
          Text(`"${this.keyword}"`).fontSize(14).fontColor(HCColor.PRIMARY).fontWeight(FontWeight.Bold)
        }
        .margin({ top: 12 })

        Text('试试同义词、缩小关键词或检查拼写')
          .fontSize(12)
          .fontColor(HCColor.TEXT_TERTIARY)
          .margin({ top: 12 })
          .textAlign(TextAlign.Center)
          .padding({ left: 60, right: 60 })

        Button('清空搜索')
          .height(40)
          .fontSize(14)
          .fontColor(HCColor.SURFACE)
          .backgroundColor(HCColor.PRIMARY)
          .borderRadius(20)
          .padding({ left: 28, right: 28 })
          .margin({ top: 32 })
          .onClick((): void => {
            this.keyword = ''
            this.performSearch('')
          })
      } else {
        Text('切换到「全部」查看所有笔记，或在白板内新建')
          .fontSize(12)
          .fontColor(HCColor.TEXT_TERTIARY)
          .margin({ top: 12 })
          .textAlign(TextAlign.Center)
          .padding({ left: 60, right: 60 })

        Button('查看全部笔记')
          .height(40)
          .fontSize(14)
          .fontColor(HCColor.SURFACE)
          .backgroundColor(HCColor.PRIMARY)
          .borderRadius(20)
          .padding({ left: 28, right: 28 })
          .margin({ top: 32 })
          .onClick((): void => {
            this.activeTab = 'all'
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  emptyView() {
    // PRD v5 布局整改：空状态插画化 + 主操作按钮，引导用户创建第一篇
    // 🔧 修复：标题与副标题改读 this.emptyHint（refreshEmptyHint 已按 activeTab 设置正确文案），
    //   切换到 闪卡/导图 tab 时不再显示"暂无收藏笔记..."
    Column() {
      // SVG 插画（鸿绘画笔 + 笔记本）
      Stack() {
        Stack() {
          // 笔记本外框
          Column()
            .width(120)
            .height(150)
            .borderRadius(8)
            .backgroundColor(HCColor.SURFACE)
            .border({ width: 1.5, color: HCColor.PRIMARY })
            .shadow({ radius: 16, color: 'rgba(0,125,255,0.12)', offsetY: 6 })

          // 横线（底纸）
          Column() {
            Column().width(70).height(6).backgroundColor(HCBrand.AMBER_TINT).borderRadius(3)
            Blank().height(16)
            Column().width(80).height(6).backgroundColor(HCColor.BORDER).borderRadius(3)
            Blank().height(10)
            Column().width(60).height(6).backgroundColor(HCColor.BORDER).borderRadius(3)
          }
          .padding({ top: 24, left: 20 })
          .width(120)
          .height(150)

          // 笔（斜放）
          Row() {
            Column().width(72).height(6).backgroundColor(HCColor.PRIMARY).borderRadius(3)
              .rotate({ angle: -25 }).offset({ x: 6, y: 12 })
          }
          .width(120).height(150)
          .hitTestBehavior(HitTestMode.None)
        }
        .width(120).height(150)
      }

      // 主标题：使用 this.emptyHint（refreshEmptyHint 已按 tab 注入正确文案）
      Text(this.emptyHint)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ top: 32 })

      // 副标题：仅在「全部」tab 时引导创建
      if (this.activeTab === 'all') {
        Text('点下方按钮创建第一篇，或点右下角「+」')
          .fontSize(12)
          .fontColor(HCColor.TEXT_TERTIARY)
          .margin({ top: 8 })

        // 主操作按钮
        Button('+ 创建第一篇')
          .height(46)
          .fontSize(15)
          .fontColor(HCColor.SURFACE)
          .fontWeight(FontWeight.Medium)
          .backgroundColor(HCColor.PRIMARY)
          .borderRadius(23)
          .padding({ left: 32, right: 32 })
          .margin({ top: 32 })
          .shadow({ radius: 12, color: 'rgba(0,125,255,0.25)', offsetY: 4 })
          .onClick((): void => {
            this.showCreate = true
          })
      } else {
        Text('返回「全部」查看已有笔记，或在白板内新建')
          .fontSize(12)
          .fontColor(HCColor.TEXT_TERTIARY)
          .margin({ top: 8 })
          .textAlign(TextAlign.Center)
          .padding({ left: 40, right: 40 })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding({ bottom: 60 })  // 留出 FAB + BottomTabBar 空间
  }

  @Builder
  gridView() {
    // 如果是"全部"Tab且无搜索关键词，使用分组展示
    if (this.activeTab === 'all' && this.keyword.trim().length === 0) {
      this.groupedGridView();
    } else {
      this.flatGridView();
    }
  }

  /** 分组网格视图（按日期分组） */
  @Builder
  groupedGridView() {
    // 🔧 v2.5.1 崩溃修复：分组取值一律走 notesInGroup() 安全方法。
    //   原实现在 keys() / .get(groupKey)!.length / .get(groupKey)! 三处各重建一次 Map，
    //   若 visibleItems() 在渲染中途变化（异步更新/重渲染），后两次重建的 Map 可能已经
    //   不含该 groupKey —— `!` 非空断言对 undefined 解引用 → 直接崩溃。
    //   （与视频(4)"3 篇 vs 还没有笔记"列表闪烁同源，同一个根因的两种表现。）
    Scroll() {
      Column() {
        ForEach(Array.from(this.groupNotesByDate(this.visibleItems()).keys()), (groupKey: string) => {
          Column() {
            // 分组标题
            Row() {
              Text(groupKey)
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(HCColor.TEXT_SECONDARY)
              Text(`${this.notesInGroup(groupKey).length}篇`)
                .fontSize(12)
                .fontColor(HCColor.TEXT_TERTIARY)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 4, bottom: 8, top: 16 })
            
            // 该分组的笔记网格
            Grid() {
              ForEach(this.notesInGroup(groupKey), (item: NoteListItem): void => {
                GridItem() {
                  NoteCard({
                    meta: item.meta,
                    thumb: item.thumb,
                    hasPendingTmp: item.hasPendingTmp,
                    searchKeyword: this.keyword,
                    matchPreview: this.previewFor(item.meta.id),
                    isFavorite: this.favoriteIds.has(item.meta.id),
                    isFiltered: this.activeTab !== 'all',
                    onOpen: (id: string): void => {
                      this.openNoteById(id);
                    },
                    onRename: (id: string): void => {
                      this.beginRename(id);
                    },
                    // 🔴 v2.7.2 审核修复（问题②-4「批注点击无反应」**真正根因**）：
                    //   网格视图此前**漏传 onAnnotate**（只有列表视图传了），
                    //   而审核截图/录屏用的正是网格视图 → 点「批注」走默认空实现，
                    //   完全无反应（连 Toast 都不会出现）。现补齐。
                    onAnnotate: (id: string): void => {
                      this.openAnnotate(id);
                    },
                    onMore: (id: string): void => {
                      this.openCardMenu(id);
                    },
                    onDelete: (id: string): void => {
                      this.beginDelete(id);
                    },
                    onToggleFavorite: (id: string): void => {
                      this.toggleFavorite(id);
                    }
                  })
                }
                // 🔴 v2.7.2：key 必须包含 title —— 否则重命名后 key 不变，
                  //   ArkUI 复用旧列表项 → 「重命名更新不及时」。
              }, (item: NoteListItem): string => `${item.meta.id}_${item.meta.updatedAt}_${item.meta.title}_${item.hasPendingTmp ? 'd' : 'n'}`)
            }
            .columnsTemplate('1fr 1fr')
            .rowsGap(12)
            .columnsGap(12)
            .width('100%')
          }
          .width('100%')
        }, (groupKey: string): string => groupKey)
      }
      .width('100%')
    }
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
    .edgeEffect(EdgeEffect.Spring)
  }

  /** 扁平网格视图（原有逻辑） */
  @Builder
  flatGridView() {
    Grid() {
      ForEach(this.visibleItems(), (item: NoteListItem): void => {
        GridItem() {
          NoteCard({
            meta: item.meta,
            thumb: item.thumb,
            hasPendingTmp: item.hasPendingTmp,
            searchKeyword: this.keyword,
            matchPreview: this.previewFor(item.meta.id),
            isFavorite: this.favoriteIds.has(item.meta.id),
            onOpen: (id: string): void => {
              this.openNoteById(id);
            },
            onRename: (id: string): void => {
              this.beginRename(id);
            },
            onAnnotate: (id: string): void => {
              this.openAnnotate(id);
            },
            onMore: (id: string): void => {
              this.openCardMenu(id);
            },
            onDelete: (id: string): void => {
              this.beginDelete(id);
            },
            onToggleFavorite: (id: string): void => {
              this.toggleFavorite(id);
            }
          })
        }
      }, (item: NoteListItem): string => `${item.meta.id}_${item.meta.updatedAt}_${item.meta.title}_${item.hasPendingTmp ? 'd' : 'n'}`)
    }
    .columnsTemplate('1fr 1fr')
    .columnsGap(12)
    .rowsGap(12)
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 20, right: 20, top: 4, bottom: 90 + this.safeBottomInset() })
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  /**
   * v2.7.2：卡片操作菜单弹层（收藏 / 重命名 / 批注 / 删除）。
   * 与 renamePanel / deletePanel 同一套页内弹层机制，稳定可用。
   */
  @Builder
  cardMenuPanel() {
    Column() {
      Text(this.cardMenuTitle.length > 0 ? this.cardMenuTitle : '未命名笔记')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(HCColor.TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Center)
        .margin({ bottom: 10 })

      this.cardMenuRow(this.favoriteIds.has(this.cardMenuId) ? '取消收藏' : '收藏', (): void => {
        this.toggleFavorite(this.cardMenuId);
        this.showCardMenu = false;
      })
      this.cardMenuRow('重命名', (): void => {
        const id: string = this.cardMenuId;
        this.showCardMenu = false;
        this.beginRename(id);
      })
      this.cardMenuRow('批注', (): void => {
        const id: string = this.cardMenuId;
        this.showCardMenu = false;
        this.openAnnotate(id);
      })
      this.cardMenuRow('删除', (): void => {
        const id: string = this.cardMenuId;
        this.showCardMenu = false;
        this.beginDelete(id);
      })
    }
    .width('86%')
    .padding({ left: 16, right: 16, top: 16, bottom: 8 })
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(16)
    .shadow({ radius: 20, color: 'rgba(0,0,0,0.20)', offsetY: 4 })
    .onClick((): void => { /* 吞掉点击，避免冒泡到遮罩关闭 */ })
  }

  @Builder
  cardMenuRow(label: string, onTap: () => void) {
    Text(label)
      .fontSize(15)
      .fontColor(HCColor.TEXT_PRIMARY)
      .width('100%')
      .height(48)
      .textAlign(TextAlign.Center)
      .border({ width: { top: 1 }, color: HCColor.DIVIDER })
      .onClick((): void => {
        onTap();
      })
  }

  @Builder
  renamePanel() {
    Column() {
      Text('重命名')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ top: 20, bottom: 14 })

      TextInput({ text: this.renameText, placeholder: '未命名笔记' })
        .maxLength(60)
        .height(44)
        .fontSize(15)
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(10)
        .margin({ left: 20, right: 20 })
        .onChange((value: string): void => {
          this.renameText = value;
        })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(HCColor.TEXT_SECONDARY)
          .backgroundColor(HCColor.DIVIDER)
          .onClick((): void => {
            this.showRename = false;
          })
        Blank().width(12)
        Button('保存')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(HCColor.PRIMARY)
          .onClick((): void => {
            this.commitRename();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 16, bottom: 20 })
    }
    .width('84%')
    .backgroundColor(Color.White)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  deletePanel() {
    Column() {
      Text('删除笔记')
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ top: 20, bottom: 8 })

      Text(`「${this.deleteTitle}」删除后无法恢复，确定继续吗？`)
        .fontSize(13)
        .fontColor(HCColor.TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
        .padding({ left: 20, right: 20 })

      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(HCColor.TEXT_SECONDARY)
          .backgroundColor(HCColor.DIVIDER)
          .onClick((): void => {
            this.showDelete = false;
          })
        Blank().width(12)
        Button('删除')
          .layoutWeight(1)
          .height(42)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(HCColor.DANGER)
          .onClick((): void => {
            this.commitDelete();
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 18, bottom: 20 })
    }
    .width('84%')
    .backgroundColor(Color.White)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }
}
