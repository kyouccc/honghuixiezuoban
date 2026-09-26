/**
 * Index.ets — 鸿绘 应用启动页 / 导航中枢（v2.3）
 *
 * 背景（Bug 修复）：
 *  EntryAbility.loadContent 加载 'pages/Index'，但本页此前仍是默认 Hello World 模板，
 *  且 main_pages.json 的 src 数组不含 pages/Index —— 预览器因此白屏。
 *  本次把 Index 重写为真正的应用首页，并在 main_pages.json 注册为首项。
 *
 * 用途：
 *  1. 品牌 / 版本展示；
 *  2. 导航中枢：白板 / 加入协作 / 设备管理 / 隐私政策；
 *  3. 修复 K-R2-2：页面层接线 NoteEngine 的 S2 门面 ——
 *     · 创建流转会话  → NoteEngine.createFlowSession（经 CollabStatusService）
 *     · 会话状态展示  → NoteEngine.getSessionManager().getState()
 *     · 权限指示      → NoteEngine.getPermissionGuard().getRole()
 *     · 板面同步状态  → NoteEngine.getDistributedBoardSync().isEnabled()
 *
 * 注意事项：
 *  - build() 内不做任何耗时计算，状态一律来自 @State（aboutToAppear 异步加载）；
 *  - 所有导航 / 门面调用经 SafeAsync 兜底，异常只反映到 hintText，不会导致白屏。
 */

import { router, promptAction } from '@kit.ArkUI';
import {
  CollabStatusService,
  CollabStatusSnapshot,
  createEmptyCollabStatus
} from '../common/services/CollabStatusService';
import { SafeAsync, SafeErrorInfo } from '../common/utils/SafeAsync';
import { analytics } from '../common/services/AnalyticsService';
import { IconComponent } from '../common/components/IconComponent';
import { IconSymbols } from '../common/IconConstants';
import { crashRecoveryService, CrashRecoveryData, RecoverOutcome } from '../common/services/CrashRecoveryService';
import { CrashRecoveryDialog } from '../components/CrashRecoveryDialog';
import { BottomTabBar, TAB_KEY_ME } from '../components/BottomTabBar';
import { HCColor, HCAccent, HCOverlay } from '../common/theme/DesignTokens';
import { FEATURE_COLLAB_ENABLED } from '../common/Constants';
import { FEATURE_DEVICE_DISCOVERY_ENABLED } from '../common/Constants';
import { NoteEngine } from '../engine/NoteEngine';
import { NoteMeta } from '../engine/types/NoteModel';

const TAG_PAGE = 'IndexPage';
/** 会话状态轮询间隔（ms），首页低频刷新即可 */
const STATUS_REFRESH_MS: number = 1500;
// v2.7.0：第七轮驳回真因修复（填充性能根治 / 取色分层采样 / 文本工具双击编辑 /
//   闪卡与导图入口 / 导图筛选 / 协作加入 / 导出分享真实落盘 / 主题重启保持 /
//   设备发现真实化 / 底部导航条适配）
const APP_VERSION: string = 'v2.7.8';

/** 首页导航项（避免 build() 内出现无类型对象字面量） */
interface HomeAction {
  key: string;
  icon: string;       // Emoji降级方案
  symbol?: string;    // SymbolGlyph系统图标（优先）
  title: string;
  subtitle: string;
  route: string;
  primary: boolean;
  disabled?: boolean;
}

@Entry
@Component
struct Index {
  /** 协同状态快照（首帧空值，aboutToAppear 后异步填充） */
  @State status: CollabStatusSnapshot = createEmptyCollabStatus();
  @State hintText: string = '正在初始化引擎…';
  @State busy: boolean = false;
  @State ready: boolean = false;

  /** 最近编辑的笔记（快捷操作栏） */
  @State recentNotes: NoteMeta[] = [];
  /** 状态折叠标识 */
  @State statusExpanded: boolean = false;

  /** v2.5.2 审核修复：未保存内容横幅（替代单依赖弹窗的恢复方式） */
  @State hasPendingRecovery: boolean = false;
  @State recoveryTitle: string = '';
  
  /** 操作卡片按压缩放动画 */
  @State actionScaleX: Map<string, number> = new Map();
  @State actionScaleY: Map<string, number> = new Map();
  
  // 设 崩溃恢复对话框（F-04）
  @State showCrashRecoveryDialog: boolean = false;
  private crashRecoveryDialogController: CustomDialogController = new CustomDialogController({
    builder: CrashRecoveryDialog({
      onRecover: () => {
        this.showCrashRecoveryDialog = false;
        // 🔧 v3.1 修复：恢复动作成功后给出明确反馈（CrashRecoveryDialog 内部已跳转编辑页）
        promptAction.showToast({ message: '未保存内容已恢复', duration: 2000 });
      },
      onDiscard: () => {
        this.showCrashRecoveryDialog = false;
        promptAction.showToast({ message: '已丢弃未保存内容', duration: 1500 });
      }
    }),
    autoCancel: false,
    customStyle: true
  });

  private service: CollabStatusService = CollabStatusService.getInstance();
  private refreshTimer: number = -1;
  private pageEnterTime: number = 0;

  /**
   * 🔴 v2.7.6：「设备管理」入口按开关过滤。
   *   该页的「附近设备」依赖分布式设备发现能力（需 DISTRIBUTED_DATASYNC 权限），
   *   本版本为降低提审风险已移除该权限 → 设备列表必然为空，
   *   会被判为"登录同账号+超级终端后仍读取不到设备"的功能异常。
   *   故先隐藏入口，功能实现完整保留（DeviceManagePage 未改动）。
   */
  private visibleActions(): HomeAction[] {
    if (FEATURE_DEVICE_DISCOVERY_ENABLED) {
      return this.actions;
    }
    const out: HomeAction[] = [];
    for (let i = 0; i < this.actions.length; i++) {
      if (this.actions[i].key !== 'device') {
        out.push(this.actions[i]);
      }
    }
    return out;
  }

  private readonly actions: HomeAction[] = [
    {
      key: 'whiteboard',
      icon: '画',
      symbol: IconSymbols.PALETTE,  // 使用SymbolGlyph系统图标
      title: '新建白板',
      subtitle: '无限画布 · 手写笔记 · 双链书签',
      route: 'pages/WhiteboardPage',
      primary: true
    },
    {
      key: 'notes',
      icon: '笔',
      symbol: IconSymbols.DOC_TEXT,
      title: '我的笔记',
      subtitle: '本地保存 · 手写笔记 · 双链管理',
      route: 'pages/NotePage',
      primary: false
    },
    {
      key: 'device',
      icon: '机',
      symbol: IconSymbols.PHONE,
      title: '设备管理',
      subtitle: '查看同账号登录设备 · 软总线发现管理',
      route: 'pages/DeviceManagePage',
      primary: false
    },
    {
      key: 'theme',
      icon: '主',
      symbol: IconSymbols.SETTINGS,
      title: '主题设置',
      subtitle: '深浅模式 · 纸张样式 · 主题皮肤',
      route: 'pages/ThemeSettingsPage',
      primary: false
    },
    {
      key: 'privacy',
      icon: '隐',
      symbol: IconSymbols.INFO,
      title: '隐私政策',
      subtitle: '权限管理 · 数据安全 · 隐私声明',
      route: 'pages/PrivacyPage',
      primary: false
    },
    {
      key: 'mindmap',
      icon: '思',
      symbol: IconSymbols.DOC_TEXT,
      title: '思维导图',
      subtitle: '大纲导入 · 节点编辑 · 手绘转导图',
      route: 'pages/MindMapEntryPage',
      primary: false
    },
    {
      key: 'flashcard',
      icon: '卡',
      symbol: IconSymbols.DOC_TEXT,
      title: '闪卡复习',
      subtitle: 'SM-2间隔重复 · 翻卡复习 · 新建/删除',
      route: 'pages/FlashcardEntryPage',
      primary: false
    }
  ];

  // ─── 生命周期 ───

  aboutToAppear(): void {
    this.pageEnterTime = Date.now();

    // 设 崩溃恢复检测（F-04）
    SafeAsync.runAsyncVoid(TAG_PAGE, 'checkCrashRecovery', async (): Promise<void> => {
      await crashRecoveryService.initialize();

      // v2.6.0：只有「上次异常退出」才提示恢复（hasPendingRecovery），
      //   正常退出后残留的快照会被 initialize() 自动清理，不再反复弹窗。
      if (crashRecoveryService.hasPendingRecovery()) {
        this.showCrashRecoveryDialog = true;
        this.crashRecoveryDialogController.open();
      }

      // v2.5.2 审核修复：即使弹窗因 CustomDialogController 异步调用限制未打开，
      //   也在页面顶部显示"未保存内容可恢复"横幅，让用户有明确入口恢复
      if (crashRecoveryService.hasPendingRecovery()) {
        const data = crashRecoveryService.getRecoveryData();
        this.hasPendingRecovery = true;
        this.recoveryTitle = data !== null && data.title.length > 0 ? data.title : '未命名笔记';
      }
    });
    
    // 异步加载：首帧先渲染骨架，避免引擎初始化阻塞渲染
    SafeAsync.runAsyncVoid(TAG_PAGE, 'initHome', async (): Promise<void> => {
      this.service.ensureLocalDeviceId();
      this.status = await this.service.snapshotAsync();
      this.ready = true;
      this.hintText = this.status.hasSession ? '流转会话进行中' : '当前为单机模式，可创建流转会话';
      
      // 加载最近编辑的笔记（最多3个）
      if (NoteEngine.getInstance().isStorageReady()) {
        const allNotes = await NoteEngine.getInstance().getNoteRepository().listNotes();
        this.recentNotes = allNotes.slice(0, 3);
      }
    }, (info: SafeErrorInfo): void => {
      this.ready = true;
      this.hintText = `初始化失败：${info.message}`;
    });

    this.startAutoRefresh();
    this.trackAsync((): void => {
      analytics.trackPageView('IndexPage');
    });
  }

  aboutToDisappear(): void {
    this.stopAutoRefresh();
    const duration: number = Date.now() - this.pageEnterTime;
    this.trackAsync((): void => {
      analytics.trackPageExit('IndexPage', duration);
    });
  }

  // ─── 视图 ───

  /** v2.7.0：系统底部避让高度（底部导航条/手势条），用于底部内容留白 */
  @StorageProp('hcSafeAreaBottom') safeBottom: number = 0;

  private safeBottomInset(): number {
    const v: number = this.safeBottom;
    return v !== undefined && v !== null && v > 0 ? v : 0;
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // v2.5.2 审核修复：未保存内容横幅（避免弹窗机制失效时无可恢复入口）
        if (this.hasPendingRecovery) {
          this.buildRecoveryBanner()
        }
        Scroll() {
          Column() {
            this.buildHeader();
            this.buildQuickActions();  // 快捷操作栏（新增）
            this.buildStatus();
            this.buildActions();
            this.buildFooter();
          }
          .width('100%')
          // v2.7.0：底部留白叠加系统导航条真实高度（问题② 底部导航条适配）
          .padding({ left: 18, right: 18, bottom: 110 + this.safeBottomInset() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(HCColor.PAGE_BG)

      // U-01：导航中枢归属「我的」Tab（含协作/设备/隐私入口）
      BottomTabBar({ activeKey: TAB_KEY_ME })
        .width('100%')
    }
    .width('100%')
    .height('100%')
  }

  /** v2.5.5 审核修复（审核项③延续真因）：横幅「立即恢复」直连恢复逻辑。
   *  之前按钮点击后走 crashRecoveryDialogController.open()——该弹窗在部分场景
   *  被 CustomDialogController 异步限制拦截，导致点击后无任何可见反馈，
   *  审核员据此判定"未保存内容无法恢复"。现在直接执行恢复 + Toast 反馈 + 跳转编辑页。 */
  private recovering: boolean = false;

  private async recoverNow(): Promise<void> {
    if (this.recovering) {
      return;
    }
    this.recovering = true;
    try {
      // v2.6.0：recoverNote 返回结构化结果（含"另存为新笔记"兜底），失败原因可精确展示
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
        promptAction.showToast({
          message: `恢复失败：${outcome.errorMessage}`,
          duration: 3000
        });
      }
    } catch (err) {
      promptAction.showToast({ message: '恢复异常，未保存内容仍保留，可重试', duration: 3000 });
    } finally {
      this.recovering = false;
    }
  }

  /** v2.5.2 审核修复：未保存内容恢复横幅（双保险机制） */
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
  
  /** 页面转场动画 */
  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }

  /** 品牌头部：Logo / 名称 / 版本 / 副标题 */
  @Builder
  buildHeader() {
    Column() {
      // 精简品牌区域：Logo + 标题 + 版本号一行展示
      Row() {
        IconComponent({
          symbol: IconSymbols.PALETTE,
          iconSize: 40,
          color: HCColor.PRIMARY
        })
        
        Column() {
          Text('鸿绘')
            .fontSize(22)
            .fontWeight(FontWeight.Bold)
            .fontColor(HCColor.TEXT_PRIMARY)
          Text('鸿绘 · 手写白板笔记')
            .fontSize(11)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)
        
        // 版本和状态标签
        Column() {
          Text(APP_VERSION)
            .fontSize(10)
            .fontColor(HCColor.PRIMARY)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(HCColor.PRIMARY_BG)
            .borderRadius(6)
          Text(this.ready ? '就绪' : '加载中')
            .fontSize(10)
            .fontColor(this.ready ? HCColor.SUCCESS : HCColor.WARNING)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(this.ready ? HCColor.SUCCESS_BG : HCColor.WARNING_BG)
            .borderRadius(6)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 24, bottom: 16 })
  }

  /** 快捷操作栏：最近编辑的笔记 */
  @Builder
  buildQuickActions() {
    if (this.recentNotes.length > 0) {
      Column() {
        Row() {
          Text('最近编辑')
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(HCColor.TEXT_PRIMARY)
          Blank()
          Text('查看全部 >')
            .fontSize(12)
            .fontColor(HCColor.PRIMARY)
            .onClick(() => {
              router.pushUrl({ url: 'pages/NotePage' });
            })
        }
        .width('100%')
        .margin({ bottom: 12 })

        Row() {
          ForEach(this.recentNotes, (note: NoteMeta) => {
            Column() {
              // 笔记卡片
              Row() {
                IconComponent({
                  symbol: IconSymbols.DOC_TEXT,
                  iconSize: 20,
                  color: HCColor.PRIMARY
                })
                
                Column() {
                  Text(note.title || '未命名笔记')
                    .fontSize(13)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(HCColor.TEXT_PRIMARY)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  
                  Text(this.formatRecentTime(note.updatedAt))
                    .fontSize(10)
                    .fontColor(HCColor.TEXT_TERTIARY)
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .margin({ left: 8 })
                .layoutWeight(1)
              }
              .width('100%')
              .padding(12)
              .backgroundColor(HCColor.SURFACE_ELEVATED)
              .borderRadius(8)
              .onClick(() => {
                router.pushUrl({
                  url: 'pages/WhiteboardPage',
                  params: {
                    noteId: note.id,
                    title: note.title,
                    paperTemplate: note.paperTemplate || 'blank',
                    isNew: false
                  }
                });
              })
            }
            .layoutWeight(1)
            .margin({ right: 8 })
          }, (note: NoteMeta) => note.id)
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(HCColor.SURFACE_ELEVATED)
      .borderRadius(12)
      .margin({ top: 12, bottom: 12 })
    }
  }

  /** 格式化最近时间 */
  private formatRecentTime(timestamp: number): string {
    const now = Date.now();
    const diff = now - timestamp;
    const minutes = Math.floor(diff / 60000);
    const hours = Math.floor(diff / 3600000);
    const days = Math.floor(diff / 86400000);
    
    if (minutes < 1) return '刚刚';
    if (minutes < 60) return `${minutes}分钟前`;
    if (hours < 24) return `${hours}小时前`;
    if (days < 7) return `${days}天前`;
    
    const date = new Date(timestamp);
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  /** 会话 / 权限状态卡片（K-R2-2：读取 NoteEngine S2 门面状态，支持折叠） */
  @Builder
  buildStatus() {
    Column() {
      // 标题栏（可点击展开/折叠）
      this.buildStatusHeader();
      
      // 详细状态（折叠区域）
      if (this.statusExpanded) {
        this.buildStatusDetail();
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(14)
    .shadow({ radius: 10, color: HCOverlay.SHADE_05 })
  }

  /** 状态行（label + value） */
  @Builder
  buildStatusRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(12)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width(96)
      Text(value)
        .fontSize(12)
        .fontColor(HCColor.TEXT_SECONDARY)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }

  /** 状态卡片标题栏 */
  @Builder
  buildStatusHeader() {
    Row() {
      Text('协同状态')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(HCColor.TEXT_PRIMARY)
      Blank()
      Text(this.status.hasSession ? '● 会话中' : '○ 单机')
        .fontSize(12)
        .fontColor(this.status.hasSession ? HCColor.SUCCESS : HCColor.ICON_SECONDARY)
      IconComponent({
        symbol: this.statusExpanded ? IconSymbols.CHEVRON_UP : IconSymbols.CHEVRON_DOWN,
        iconSize: 16,
        color: HCColor.ICON_SECONDARY
      })
        .margin({ left: 8 })
    }
    .width('100%')
    .padding({ bottom: 10 })
    .onClick(() => {
      this.statusExpanded = !this.statusExpanded;
    })
  }

  /** 权限指示器 */
  @Builder
  buildPermissionIndicator() {
    Row() {
      Text('当前权限')
        .fontSize(12)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width(96)
      Text(`${this.status.permissionRole} · ${this.status.permissionRoleText}`)
        .fontSize(12)
        .fontColor(this.permissionColor())
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(this.permissionBackground())
        .borderRadius(8)
      Blank()
      Text(this.status.canWrite ? '可写' : '只读')
        .fontSize(11)
        .fontColor(this.status.canWrite ? HCColor.SUCCESS : HCColor.DANGER)
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /** 流转会话控制按钮 */
  @Builder
  buildFlowSessionControls() {
    Row() {
      Button(this.status.hasSession ? '结束流转会话' : '开始流转会话')
        .fontSize(13)
        .height(38)
        .layoutWeight(1)
        .fontColor(this.status.hasSession ? HCColor.DANGER : HCColor.SURFACE)
        .backgroundColor(this.status.hasSession ? HCColor.DANGER_BG : HCColor.PRIMARY)
        .borderRadius(10)
        .enabled(!this.busy)
        .onClick(() => {
          this.toggleFlowSession();
        })

      Button('刷新状态')
        .fontSize(13)
        .height(38)
        .width(96)
        .fontColor(HCColor.PRIMARY)
        .backgroundColor(HCColor.PRIMARY_BG)
        .borderRadius(10)
        .margin({ left: 10 })
        .enabled(!this.busy)
        .onClick(() => {
          this.refreshStatus();
        })
    }
    .width('100%')

    // 🔴 v2.7.5：协作功能暂时下线（见 Constants.FEATURE_COLLAB_ENABLED）。
    //   关闭时不展示协作说明 —— 否则会出现"有说明、无入口"的困惑。
    if (FEATURE_COLLAB_ENABLED) {
      Text('协作说明：流转会话需 2 台及以上已登录同一华为账号的鸿蒙设备（同一 WLAN），'
        + '在设备管理中确认发现后即可批注协同；单设备环境下仅支持本地编辑。')
        .fontSize(11)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width('100%')
        .margin({ top: 8 })
    }
  }

  /** 详细状态区域 */
  @Builder
  buildStatusDetail() {
    Column() {
      this.buildStatusRow('会话 ID', this.status.shortSessionId);
      this.buildStatusRow('笔记 / 设备组', this.status.hasSession
        ? `${this.status.noteId} / ${this.status.deviceGroupId}`
        : '—');
      this.buildStatusRow('本机设备', this.status.shortLocalDeviceId);
      this.buildStatusRow('会话角色', this.status.sessionRoleText);
      this.buildStatusRow('在线设备', `${this.status.onlineDeviceCount} 台`);
      this.buildStatusRow('板面同步', this.status.boardSyncEnabled ? '已开启' : '未开启');
      this.buildStatusRow('最近视口', this.status.lastViewportText);

      // 三级权限指示（VIEWER / ANNOTATOR / EDITOR）
      this.buildPermissionIndicator();

      Divider()
        .color(HCColor.DIVIDER)
        .margin({ top: 12, bottom: 12 })

      // 流转会话控制（HM-08）
      this.buildFlowSessionControls();

      Text(this.hintText)
        .fontSize(11)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width('100%')
        .margin({ top: 10 })
    }
    .width('100%')
    .padding({ top: 8 })
    .transition(TransitionEffect.OPACITY.animation({ duration: 200 }))
  }

  /** 主要导航入口 */
  @Builder
  buildActions() {
    Column() {
      ForEach(this.visibleActions(), (action: HomeAction) => {
        Row() {
          IconComponent({
            symbol: action.symbol,
            emoji: action.icon,
            iconSize: 26,
            color: action.primary ? HCColor.SURFACE : HCColor.TEXT_PRIMARY
          })
            .width(44)
            .height(44)
          
          Column() {
            Text(action.title)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(action.primary ? HCColor.SURFACE : HCColor.TEXT_PRIMARY)
            Text(action.subtitle)
              .fontSize(11)
              .fontColor(action.primary ? HCAccent.BTN_ON_PRIMARY : HCColor.TEXT_TERTIARY)
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          Text('›')
            .fontSize(20)
            .fontColor(action.primary ? HCAccent.BTN_ON_PRIMARY : HCColor.TEXT_DISABLED)
        }
        .width('100%')
        .padding({ left: 12, right: 16, top: 14, bottom: 14 })
        .backgroundColor(action.primary ? HCColor.PRIMARY : HCColor.SURFACE)
        .borderRadius(14)
        .margin({ top: 12 })
        .onClick(() => {
          this.navigate(action.route, action.key);
        })
        .scale({ x: this.actionScaleX.get(action.key) ?? 1, y: this.actionScaleY.get(action.key) ?? 1 })
        .animation({ duration: 150, curve: Curve.FastOutSlowIn })
        .onTouch((event: TouchEvent) => {
          if (event.type === TouchType.Down) {
            this.actionScaleX.set(action.key, 0.97);
            this.actionScaleY.set(action.key, 0.97);
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            this.actionScaleX.set(action.key, 1);
            this.actionScaleY.set(action.key, 1);
          }
        })
      }, (action: HomeAction) => action.key)
    }
    .width('100%')
    .margin({ top: 4 })
  }

  /** 底部说明 + 隐私入口 */
  @Builder
  buildFooter() {
    Column() {
      Text('隐私政策')
        .fontSize(12)
        .fontColor(HCColor.PRIMARY)
        .padding({ top: 16, bottom: 6 })
        .onClick(() => {
          this.navigate('pages/PrivacyPage', 'privacy');
        })
      Text('分布式软总线 · CRDT 协同 · 三级权限矩阵')
        .fontSize(10)
        .fontColor(HCColor.TEXT_DISABLED)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .margin({ top: 8 })
  }

  // ─── 交互逻辑 ───

  /**
   * 页面跳转（统一异常兜底，跳转失败只提示不崩溃）。
   * @param url 目标页面路径，必须已在 main_pages.json 注册
   * @param key 埋点标识
   */
  private navigate(url: string, key: string): void {
    this.hintText = `正在打开 ${key}…`;
    SafeAsync.runVoid(TAG_PAGE, `navigate:${url}`, () => {
      router.pushUrl({ url: url })
        .then(() => {
          this.hintText = this.status.hasSession ? '流转会话进行中' : '当前为单机模式，可创建流转会话';
        })
        .catch((err: Error) => {
          this.hintText = `打开失败：${SafeAsync.describe(err)}`;
        });
    }, (info: SafeErrorInfo): void => {
      this.hintText = `打开失败：${info.message}`;
    });
  }

  /**
   * 创建 / 结束超级终端流转会话（HM-08）。
   * 创建：NoteEngine.createFlowSession → DistributedBoardSync.setEnabled(true)
   */
  private toggleFlowSession(): void {
    this.busy = true;
    SafeAsync.runAsyncVoid(TAG_PAGE, 'toggleFlowSession', async (): Promise<void> => {
      if (this.status.hasSession) {
        this.status = this.service.endFlowSession();
        this.hintText = '会话已结束，板面同步已关闭';
      } else {
        this.status = this.service.startFlowSession('');
        this.hintText = `会话已创建：${this.status.shortSessionId}（角色 ${this.status.sessionRoleText}）`;
      }
      this.busy = false;
    }, (info: SafeErrorInfo): void => {
      this.busy = false;
      this.hintText = `操作失败：${info.message}`;
    });
  }

  /** 手动刷新会话状态 */
  private refreshStatus(): void {
    SafeAsync.runAsyncVoid(TAG_PAGE, 'refreshStatus', async (): Promise<void> => {
      this.status = await this.service.snapshotAsync();
      this.hintText = this.status.hasSession ? '流转会话进行中' : '当前为单机模式，可创建流转会话';
    });
  }

  /** 启动低频轮询（1.5s），保证从白板返回后状态自动同步 */
  private startAutoRefresh(): void {
    if (this.refreshTimer !== -1) {
      return;
    }
    this.refreshTimer = setInterval(() => {
      SafeAsync.runVoid(TAG_PAGE, 'autoRefresh', () => {
        this.status = this.service.snapshot();
      });
    }, STATUS_REFRESH_MS);
  }

  /** 停止轮询（防止页面销毁后定时器泄漏） */
  private stopAutoRefresh(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  /** 埋点异步化：不阻塞主线程渲染 */
  private trackAsync(action: () => void): void {
    setTimeout(() => {
      SafeAsync.runVoid(TAG_PAGE, 'analytics', action);
    }, 0);
  }

  private permissionColor(): ResourceColor {
    if (this.status.permissionRole === 'EDITOR') {
      return HCColor.SUCCESS;
    }
    if (this.status.permissionRole === 'ANNOTATOR') {
      return HCColor.WARNING;
    }
    return HCColor.DANGER;
  }

  private permissionBackground(): ResourceColor {
    if (this.status.permissionRole === 'EDITOR') {
      return HCColor.SUCCESS_BG;
    }
    if (this.status.permissionRole === 'ANNOTATOR') {
      return HCColor.WARNING_BG;
    }
    return HCColor.DANGER_BG;
  }
}
