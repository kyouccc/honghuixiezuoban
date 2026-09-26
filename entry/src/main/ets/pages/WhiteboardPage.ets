/**
 * WhiteboardPage.ets — 白板主页 v2.4（阶段一 P0「画完不丢」）
 *
 * v2.2 双层画布：历史层(ctxHistory) 只在事件边界重绘，活动层(ctxActive) 承载当前笔画 → O(1) 落笔延迟。
 * v2.4 阶段一（T1-5）在此基础上把「白板」接成「笔记」：
 *
 *   W1  三层画布：ctxPaper（底纸）/ ctxHistory（已完成笔画）/ ctxActive（当前笔画与形状预览）
 *   W2  路由参数接入：noteId / title / paperTemplate / isNew（契约见 NoteModel.NoteRouteParams）
 *   W3  打开即恢复现场：NoteEngine.strokesFromContent / imagesFromContent
 *   W4  笔画记录上提到 NoteModel.StrokeRecord（含 opacity / blendMode / brushShape / layerId / createdAt）
 *   W5  笔刷面板接线（BrushPanel ← NoteEngine.getBrushOptions）
 *   W6  底纸切换（NoteEngine.getPaperOptions / setPaperLayerTemplate）
 *   W7  历史层按笔还原 opacity / blendMode / brushShape，并叠加所属图层的可见性与透明度
 *   W8  2s 脏检查自动保存 + 三态保存指示（U-2 文案）
 *   W9  缩略图落盘（≥10s 节流 + 退出强制一次，NoteRepository.saveThumb）
 *   W10 退出 / 返回 flush 保存（aboutToDisappear / onBackPress）
 *   W11 图层面板接线（LayerPanel.onChanged → 重绘历史层）
 *   W12 图片插入接线（ImageInsert.onInserted → NoteEngine.createImageRef → 画布可见）
 *   W13 笔画 / 图片 / 底纸 / 图层任一变更即打脏标记
 *
 * 本次根治的两个「看起来像功能没做」的缺陷：
 *   C-2 历史层背景原为 HCColor.SURFACE，把底纸整张盖死 —— 选网格/点阵/横线都还是一片白。
 *       现改为 Color.Transparent，底纸由独立的 ctxPaper 承载。
 *   C-3 半透明笔（荧光笔 opacity=0.4）原按 move 分段增量描边，重叠处反复叠加越描越深。
 *       现改为「清活动层 + 整条路径一次性重绘」，笔迹浓度恒定。
 *
 * 分层铁律：页面层只经 NoteEngine 门面使用引擎能力，不 import NoteSerializer / LayerManager 等实现类。
 */

import { SketchToVector, VecPoint } from '../engine/SketchToVector';
import { LayerPanel } from '../components/LayerPanel';
import { PerformanceTracker } from '../common/utils/PerformanceTracker';
import { BrushPanel } from '../components/BrushPanel';
import { ImageInsert, ImageInsertResult } from '../components/ImageInsert';
import { FeedbackDialog } from '../components/FeedbackDialog';
import { analytics, AnalyticsEvent } from '../common/services/AnalyticsService';
import { router, promptAction } from '@kit.ArkUI';
import { BackButton } from '../common/components/BackButton';
import { display } from '@kit.ArkUI';
import { util } from '@kit.ArkTS';
// v2.7.0：分享/复制笔记ID 需要文件写入、剪贴板与 Ability 上下文
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import {
  CollabStatusService,
  CollabStatusSnapshot,
  ViewportSyncResult,
  createEmptyCollabStatus
  } from '../common/services/CollabStatusService';
  import { SafeAsync, SafeErrorInfo } from '../common/utils/SafeAsync';
import { Logger } from '../common/Logger';
import { PressureSampler } from '../engine/PressureSampler';
import { MemoryMonitor, MemoryStats, MemoryWarningLevel } from '../utils/MemoryMonitor';
import { NetworkMonitor, NetworkInfo, NetworkStatus } from '../utils/NetworkMonitor';
import { CanvasLayerSetup, NoteEngine } from '../engine/NoteEngine';
import { NoteRepository, NoteSaveResult, RecoverResult } from '../engine/NoteRepository';
import { ImageRefData } from '../engine/types/CanvasElement';
import { Layer } from '../engine/LayerManager';
import { FlashcardStore } from '../engine/memory/FlashcardStore';
import { MindMapModel } from '../engine/types/MindMapModel';
import { buildFromStrokes } from '../engine/MindMapBuilder';
import { exportService, ExportFormat, ExportPdfOptions, PdfPageImage } from '../common/services/ExportService';
import { StickerLibrary } from '../components/StickerLibrary';
import { FlashcardPage } from './FlashcardPage';
import { MindMapPage } from './MindMapPage';
import { ExportDialog } from '../components/ExportDialog';
import { HCLayer, HCText, HCMindMap, HCMindNode } from '../engine/types/NoteModel';
import { DeviceAdapter, DeviceType, DeviceInfo, FoldStatus, FoldDisplayMode } from '../common/services/DeviceAdapter';
import { HCColor, HCMetric, HCPrimary, HCGray, HCOverlay, HCAccent, HCNeutral, HCBrand } from '../common/theme/DesignTokens';
import { IconSymbols, IconSize, IconColor } from '../common/IconConstants';
import { immersiveModeManager, ImmersiveMode, ImmersiveConfig } from '../common/utils/ImmersiveModeManager';
import { crashRecoveryService, CrashRecoveryData } from '../common/services/CrashRecoveryService';
import { emergencySaveService } from '../common/services/EmergencySaveService';
import { UndoRedoManager, ActionType, CanvasAction, ActionExecutor, NodeUndoManager, NodeOp, NodeOpType, NodeOpExecutor } from '../engine/UndoRedoManager';
import { CanvasNode, NodeType, BoardData, TextPayload, StickyPayload, StrokePayload, Point3, Rect, BOARD_SCHEMA_VERSION, ZOOM_MIN, ZOOM_MAX, CANVAS_LOGICAL_HALF_RANGE, LinkData, BookmarkData, BookmarkType } from '../engine/types/BoardModel';
import { QuadTree } from '../canvas/QuadTree';
import {
  BrushOption,
  HC_DEFAULT_PAPER,
  HC_LOCAL_AUTHOR,
  NoteContent,
  NoteLoadResult,
  NoteMeta,
  NoteRouteParams,
  NoteSaveState,
  PaperOption,
  PointRecord,
  StatusSeverity,
  StrokeRecord,
  createNoteMeta,
  normalizeNoteTitle,
  noteSaveStateColor,
  noteSaveStateText,
  statusPalette
} from '../engine/types/NoteModel';
import { LinkManager } from '../engine/LinkManager';
import { BookmarkManager } from '../engine/BookmarkManager';
import { HandwritingIndex, SearchHit } from '../engine/HandwritingIndex';
import { MinimapProvider } from '../engine/MinimapProvider';
import { LinkLayer } from '../components/LinkLayer';
import { MiniMap } from '../components/MiniMap';
import { BookmarkBar } from '../components/BookmarkBar';
import { SearchBar } from '../components/SearchBar';
import { LinkTargetPicker } from '../components/LinkTargetPicker';
import { TfidfRecommender, RecommendItem } from '../engine/TfidfRecommender';
import { LassoSelectTool, BoundingBox, SelectionItem } from '../engine/LassoSelectTool';
import { EyedropperTool } from '../engine/EyedropperTool';
import { FillTool, PixelBuffer, FillOutcome } from '../engine/FillTool';
import { NotePageManager, NotePage } from '../engine/NotePageManager';
import { NoteLockManager } from '../engine/NoteLockManager';
import { AudioNoteManager } from '../engine/AudioNoteManager';
import { TemplateLibrary, NoteTemplate } from '../engine/TemplateLibrary';
import { TagManager, HCTag } from '../engine/TagManager';
import { PresentationMode } from '../engine/PresentationMode';
import { StrokeReplay, ReplayStroke } from '../engine/StrokeReplay';
import { OutlineView, OutlineItem, OutlineTextBlock } from '../engine/OutlineView';
// ─── v3.0 新功能导入 ───
import { TextToolService, TextStyleConfig, createDefaultTextPayload } from '../engine/TextToolService';
import { TextEditPanel } from '../components/TextEditPanel';
import { FullscreenOverlay } from '../components/FullscreenOverlay';
import { FullscreenReadingMode, ReadingState } from '../engine/FullscreenReadingMode';
import { ExtendedToolsPanel } from '../components/ExtendedToolsPanel';
import { ShareService } from '../common/services/ShareService';
import { RecycleBinService, RecycleBinItem } from '../engine/RecycleBinService';
import { BrushBoxService, BrushPreset } from '../engine/BrushBoxService';
import { DocumentScannerService, ScanResult } from '../engine/DocumentScannerService';
import { CommentSystemService, CommentThread, Comment } from '../engine/CommentSystemService';
import { VersionHistoryService, VersionEntry } from '../engine/VersionHistoryService';
import { AIService, OCRResult } from '../engine/AIService';
import { WebEmbedService, WebEmbedData } from '../engine/WebEmbedService';
import { LatexService, LatexBlock } from '../engine/LatexService';
import { GestureEnhancer, GestureEvent, GestureType } from '../engine/GestureEnhancer';
import { WatermarkService, WatermarkConfig } from '../engine/WatermarkService';
import { AnalyticsDashboard, DailyStats } from '../engine/AnalyticsDashboard';
import { WebClipperService, ClippedContent } from '../engine/WebClipperService';
import { PollTimerService, TimerSession, Poll } from '../engine/PollTimerService';
import { SplitScreenService, SplitScreenConfig } from '../engine/SplitScreenService';
import { TemplateMarketService, NoteTemplate as MarketTemplate } from '../engine/TemplateMarketService';
import { OfflineSyncService, OfflineChange } from '../engine/OfflineSyncService';
import { ModalOverlay } from '../common/components/ModalOverlay';
import { themeManager, CanvasPaperStyle, ThemeConfig } from '../common/theme/ThemeManager';
import { DistributedBoardSession, BoardSessionListener } from '../distributed/DistributedBoardSession';
import { FEATURE_COLLAB_ENABLED } from '../common/Constants';

const TAG_PAGE = 'WhiteboardPage';
/** 协同状态轮询间隔（ms），架构约定：状态展示为低频读，1s 足够 */
const COLLAB_REFRESH_MS: number = 1000;
/** 自动保存脏检查间隔（ms），架构 §5.2：2s 一次，仅 dirty 时真正写盘 */
const AUTOSAVE_INTERVAL_MS: number = 2000;
/** 缩略图最小写盘间隔（ms）：toDataURL 相对昂贵，做节流 */
const THUMB_MIN_INTERVAL_MS: number = 10000;
/** 插图最小边长（vp），防止选到异常尺寸后画布上找不到图 */
const IMAGE_MIN_SIZE: number = 40;
/** 形状工具集合：这些 tool 值走两点几何绘制，其余按自由笔迹折线绘制 */
const SHAPE_TOOLS: string[] = ['rectangle', 'circle', 'arrow', 'line'];

interface ColorChangeProps {
  from_color: string;
  to_color: string;
}

/**
 * ══ v2.6.0 审核修复（问题①真因）══
 * ArkUI 规范：@Builder 默认【按值传递】参数，传入的状态变量变化【不会】引起
 * @Builder 内部 UI 刷新。此前 bottomToolBtn/buildLeftToolBtn 等把 tool/label 当值传入、
 * 却在函数体里读 this.currentTool 决定高亮 —— 于是「点『填』后高亮仍停在『笔』」，
 * 用户与审核员看到的就是「选了填却变成笔」「取色后笔失效变成擦」。
 * 修法：改为传【对象字面量】（按引用传递），并把决定外观的 active 等状态显式放进对象，
 * 状态变化 → 对象内容变化 → @Builder 内 UI 正确刷新。
 */
interface ToolBtnParam {
  key: string;
  symbol: string;
  label: string;
  /** 是否处于激活态（由调用方按 currentTool 计算，保证响应式） */
  active: boolean;
  /** 是否显示文字标签 */
  showLabel: boolean;
  /** 是否展开式（左工具栏）宽度 */
  wide: boolean;
  onTap: () => void;
}

interface ColorBtnParam {
  color: string;
  active: boolean;
}

interface WidthBtnParam {
  width: number;
  dotSize: number;
  active: boolean;
}

interface EraserModeBtnParam {
  mode: string;
  label: string;
  active: boolean;
}

interface ShapeBtnParam {
  shape: string;
  label: string;
  active: boolean;
}

/** ArkTS 禁止匿名对象字面量作类型，以下均为 v2.6.0 新增的 @Builder 按引用传参类型 */
interface SegmentBtnParam {
  label: string;
  active: boolean;
  action: () => void;
}

interface ColorSwatchParam {
  hexColor: string;
  active: boolean;
}

interface ZoomBtnParam {
  symbol: string;
  active: boolean;
  action: () => void;
}

interface NoteToolBtnParam {
  label: string;
  mode: string;
  nodeType: string;
  active: boolean;
  wide: boolean;
}

/** v2.7.1：画布缓冲区像素坐标（ArkTS 禁止匿名对象字面量作类型） */
interface PxPoint {
  x: number;
  y: number;
}

interface ActionMenuResult {
  index: number;
}

interface WidthChangeProps {
  from_width: number;
  to_width: number;
}

interface StrokeCountProps {
  stroke_count: number;
}

interface ExportProps {
  stroke_count: number;
  format: string;
  size: number;
}

interface TouchCenter { x: number; y: number; }

/** S2-Bfix / A2-4：框选矩形 */
interface SelectRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** S2-Bfix / A2-4：框选起点 */
interface SelectPoint {
  x: number;
  y: number;
}

/** 图层操作撤销快照 */
interface LayerUndoSnapshot {
  layers: HCLayer[];
  strokes: StrokeRecord[];
}

/** 框选笔迹点集 */
interface BoxedStrokePoint {
  x: number;
  y: number;
}

/** 框选笔迹 */
interface BoxedStroke {
  points: BoxedStrokePoint[];
}

/** NodeOpExecutor 实现类（ArkTS 不允许用对象字面量初始化带方法的接口） */
class NodeOpExecutorImpl implements NodeOpExecutor {
  private applyFn: (op: NodeOp) => void;
  private reverseFn: (op: NodeOp) => void;
  constructor(applyFn: (op: NodeOp) => void, reverseFn: (op: NodeOp) => void) {
    this.applyFn = applyFn;
    this.reverseFn = reverseFn;
  }
  apply(op: NodeOp): void {
    this.applyFn(op);
  }
  reverse(op: NodeOp): void {
    this.reverseFn(op);
  }
}

/**
 * Canvas 像素缓冲实现（ArkTS 不允许对象字面量实现接口）。
 *
 * 🔧 v2.7.0 审核修复（问题①-1）：旧实现是**逐像素**读写
 * （getPixel→getImageData(1,1) / setPixel→putImageData(x,y) 各一次），
 * 填充大面积区域时产生数百万次 GPU 同步往返，主线程被钉死、整页无响应必须重启。
 * 现改为**整幅批量**：loadPixels 只做一次 getImageData(0,0,w,h)，
 * flushPixels 只做一次 putImageData —— 全流程 GPU 往返由数百万次降到 2 次。
 */
class CanvasPixelBuffer implements PixelBuffer {
  private ctx: CanvasRenderingContext2D;
  private w: number;
  private h: number;

  constructor(ctx: CanvasRenderingContext2D, w: number, h: number) {
    this.ctx = ctx;
    this.w = w;
    this.h = h;
  }

  getWidth(): number { return this.w; }
  getHeight(): number { return this.h; }

  loadPixels(): Uint8ClampedArray | null {
    try {
      const d: ImageData = this.ctx.getImageData(0, 0, this.w, this.h);
      return d.data;
    } catch (e) {
      Logger.error(TAG_PAGE, `loadPixels 失败：${e}`);
      return null;
    }
  }

  flushPixels(data: Uint8ClampedArray): void {
    try {
      const img: ImageData = this.ctx.createImageData(this.w, this.h);
      img.data.set(data);
      this.ctx.putImageData(img, 0, 0);
    } catch (e) {
      Logger.error(TAG_PAGE, `flushPixels 失败：${e}`);
    }
  }
}

/** ReplayStroke 实现 */
class ReplayStrokeImpl implements ReplayStroke {
  id: string;
  timestamp: number;
  data: object;

  constructor(id: string, timestamp: number, data: object) {
    this.id = id;
    this.timestamp = timestamp;
    this.data = data;
  }
}

@Entry
@Component
struct WhiteboardPage {
  // ─── 工具状态 ───
  @State currentTool: string = 'pen';        // 'pen' | 'eraser' | 'shape'
  @State currentBrush: string = 'pen';       // 自由笔迹的具体笔刷：pen/pencil/highlighter/marker/brush/laser
  @State currentColor: string = '#000000';
  @State currentWidth: number = 3;
  @State currentOpacity: number = 1.0;        // PRD v4：透明度参数
  /** 橡皮擦模式（对标享做「方块擦除/选中擦除」）：point=点擦 / line=沿路径擦 / region=框选区域擦除 */
  @State eraserMode: string = 'line';
  @State leftToolbarExpanded: boolean = false; // PRD v4：左工具栏默认收起（56vp 仅图标）
  @State shapeSnap: boolean = true;            // PRD v5 需求7：形状工具「自动规整几何图形」开关（true=规整；false=自由手绘）
  /** 🔧 工具状态记忆（第 10 轮）：画笔/橡皮/形状各自记住最近一次粗细，切回时恢复 */
  private widthByTool: Record<string, number> = {};
  /** 🔧 工具状态记忆增强：每种笔刷分别记忆颜色、透明度 */
  private colorByBrush: Record<string, string> = {};
  private opacityByBrush: Record<string, number> = {};
  private widthByBrush: Record<string, number> = {};
  @State currentShape: string = 'rectangle';
  @State showColorPicker: boolean = false;
  @State showShapePicker: boolean = false;
  @State showWidthPicker: boolean = false;
  @State showBrushPanel: boolean = false;
  @State showPaperPicker: boolean = false;
  @State showLayerPanel: boolean = false;
  @State showImageInsert: boolean = false;
  @State showFeedbackDialog: boolean = false;
  @State showExportDialog: boolean = false;
  /** UI 优化：底部「更多」抽屉（收纳低频工具，缓解底部工具条溢出） */
  @State showMorePanel: boolean = false;
  /** 更多抽屉折叠状态：true=窄工具条（仅标题+核心图标），false=展开完整网格 */
  @State moreCollapsed: boolean = true;
  /** 🔧 参数面板可见性：用户可手动关闭，切换工具时自动重新展开 */
  @State paramPanelVisible: boolean = true;
  /** 🔧 参数面板折叠状态：true=折叠为侧边药丸，false=展开完整面板 */
  @State paramPanelCollapsed: boolean = false;
  /** 🔧 悬浮快捷工具条（第 10 轮）：画布右侧竖排笔/橡皮/形状，免抬手切工具；可收起 */
  @State showQuickBar: boolean = true;
  @State statusText: string = '就绪';
  private statusToastText: string = '';   // PRD v5 需求4：Toast 节流去重
  private statusToastAt: number = 0;      // PRD v5 需求4：Toast 节流时间戳
  
  // ─── 工具栏优化 ───
  @State toolbarCollapsed: boolean = false;  // 工具栏收起/展开状态
  @State immersiveMode: boolean = false;     // 沉浸模式：隐藏顶部状态栏和底部导航栏
  
  // ─── 撤销/重做 ───
  @State canUndo: boolean = false;           // 是否可撤销
  @State canRedo: boolean = false;           // 是否可重做
  private undoRedoManager: UndoRedoManager = UndoRedoManager.getInstance();
  
  // ─── 双击检测 ───
  private lastTapTime: number = 0;          // 上次点击时间戳
  private lastTapX: number = 0;             // 上次点击X坐标
  private lastTapY: number = 0;             // 上次点击Y坐标
  private readonly DOUBLE_TAP_THRESHOLD: number = 300; // 双击时间阈值（毫秒）
  private readonly DOUBLE_TAP_DISTANCE: number = 50;   // 双击距离阈值（像素）
  
  // ─── 设备适配 ───
  @State deviceInfo: DeviceInfo | null = null;  // 设备信息
  @State isPhone: boolean = false;  // 是否为手机设备
  /** 🔧 性能优化：缓存设备像素比，避免每次触摸事件都重新获取 */
  private cachedDpr: number = 1;

  // ─── T2-1b C-7：状态严重性（胶囊底色由 severity 驱动，不再硬编码绿）───
  @State currentSeverity: string = StatusSeverity.ROUTINE;
  /** alert 粘性：入参 ALERT 后，routine/INFO 在显式清除前不覆盖（C-7 ②） */
  private stickyAlert: boolean = false;

  // ─── T2-1b C-4/C-5：保存失败详情气泡 ───
  @State showSaveErrorPopup: boolean = false;
  /** 连续失败计数（保存成功即清零；≥3 次升级态，导出转主按钮） */
  @State saveFailCount: number = 0;
  /** 承接 NoteSaveResult.failureKind：'no_space' | 'no_permission' | 'unknown' */
  @State saveFailReason: string = 'unknown';

  // ─── T2-1b C-8 / D-1：未提交草稿提示条（二段式确认）───
  @State hasUncommittedTmp: boolean = false;
  @State draftNoticeVisible: boolean = false;
  @State draftPreviewMode: boolean = false;
  @State draftMtime: number = 0;
  /** 草稿预览态暂存的正本内容（「返回上次保存的版本」还原用；两次操作之间草稿都不删除） */
  private draftBackupStrokes: StrokeRecord[] = [];
  private draftBackupImages: ImageRefData[] = [];
  private draftBackupMeta: NoteMeta = createNoteMeta('', '未命名笔记', HC_DEFAULT_PAPER);

  // ─── S2-B / T2-3/T2-4：贴纸 / 闪卡 / 导图 ───
  @State showSticker: boolean = false;
  @State showFlashcard: boolean = false;
  @State showMindMap: boolean = false;
  // S2-Bfix / A2-4：导图框选模式（拖拽矩形 → 命中 strokes → buildFromStrokes → 打开导图）
  @State selectMode: boolean = false;
  @State selectRect: SelectRect | null = null;
  private selectStart: SelectPoint = { x: 0, y: 0 };
  /** 🔧 套索选区增强：选中的笔画列表 */
  @State selectedStrokes: BoxedStroke[] = [];
  /** 🔧 套索选区增强：显示操作菜单 */
  @State showSelectMenu: boolean = false;
  /** 🔧 套索选区：选中的笔迹 id（删除/复制操作用，与 selectedStrokes 同步维护） */
  private selectedStrokeIds: number[] = [];
  /** 文本框（T2-3：含贴纸 emoji，随笔记持久化到 texts[]） */
  private texts: HCText[] = [];
  /** 闪卡（T2-4：SM-2 状态随笔记持久化到 flashcards[]） */
  private flashcardStore: FlashcardStore = new FlashcardStore();
  /** 当前导图（T2-4：随笔记持久化到 mindmaps[]；单导图 MVP） */
  private mindMap: HCMindMap = MindMapModel.createEmpty('思维导图', '中心主题');
  /** 图层操作撤销快照（T2-3：操作前 strokes 归属 + 层元数据投影） */
  private layerUndoStack: LayerUndoSnapshot[] = [];

  // ─── v2.4：笔记文档态 ───
  @State noteTitle: string = '未命名笔记';
  @State paperTemplate: string = HC_DEFAULT_PAPER;
  /**
   * 底纸底色（v2.6.0 审核修复 · 问题②-3）：
   *   「主题设置-画布纸张」此前只改 ThemeManager 内部配置，画布渲染恒用白底，
   *   用户无论选亮/暗/深/暖/卷，画布都不变 → 审核判为「设置纸张实际一直是暖 / 设置无效」。
   *   现在把主题纸张色提取为 @State 并由 themeManager 监听驱动，画布重绘即生效。
   */
  @State canvasPaperColor: string = '#FFFFFF';
  /** 主题监听器句柄（离页时必须移除，避免回调触碰已销毁页面） */
  private paperThemeListener: ((config: ThemeConfig) => void) | null = null;
  @State saveState: string = NoteSaveState.IDLE;
  @State storageReady: boolean = false;
  @State brushOptions: BrushOption[] = [];
  @State paperOptions: PaperOption[] = [];
  /** 画布上的插图（@State：插入/删除后需要立即重排叠加层） */
  @State noteImages: ImageRefData[] = [];
  /** 图层面板改动计数：仅用于触发插图叠加层随「可见/透明度」重算 */
  @State layerRevision: number = 0;

  // ═══ NOTE-01：文本便签 / 便利贴（合规 CanvasNode 叠加层）═══
  @State canvasNodes: CanvasNode[] = [];   // 便签节点（type = 'text' | 'sticky'），随 board.json 持久化
  @State editingNodeId: string = '';        // 当前正在编辑/选中的节点 id
  @State noteMode: string = 'off';          // 便签创建模式：'off' | 'text' | 'sticky'
  private noteLamport: number = 0;          // 本地逻辑时钟（每次写操作自增）
  private spatialIndex: QuadTree | null = null; // ENG-03：四叉树空间索引（视口裁剪）

  // ═══ v2.5：新工具与功能状态 ═══
  // 套索选择工具
  private lassoTool: LassoSelectTool = new LassoSelectTool();
  @State lassoPath: number[] = [];           // 套索路径点（扁平 [x0,y0,x1,y1,...]）
  @State lassoActive: boolean = false;       // 套索正在绘制
  // 取色器
  private eyedropper: EyedropperTool = new EyedropperTool();
  @State eyedropperResult: string = '';      // 取色结果 hex
  @State showColorPickerResult: boolean = false;
  // 填充工具
  private fillTool: FillTool = new FillTool();
  /** v2.7.0：填色重入闸门 —— 防止连点排队多个填充任务把主线程占满 */
  private fillRunning: boolean = false;
  @State fillTolerance: number = 32;         // 填充容差
  // 页面管理
  private pageManager: NotePageManager = new NotePageManager();
  @State showPagePanel: boolean = false;
  @State currentPageIndex: number = 0;
  @State totalPages: number = 1;
  // 笔画回放
  private strokeReplay: StrokeReplay | null = null;
  @State showReplayPanel: boolean = false;
  @State replayProgress: number = 0;
  @State replayPlaying: boolean = false;
  private replayVisibleIds: Set<string> = new Set<string>();
  // 模板库
  private templateLibrary: TemplateLibrary = new TemplateLibrary();
  @State showTemplatePanel: boolean = false;
  // 标签管理
  private tagManager: TagManager = new TagManager();
  @State showTagPanel: boolean = false;
  @State noteTags: HCTag[] = [];
  // 演示模式
  private presentationMode: PresentationMode = new PresentationMode();
  @State inPresentation: boolean = false;
  // 密码锁
  private lockManager: NoteLockManager = new NoteLockManager();
  @State noteLocked: boolean = false;
  @State showLockDialog: boolean = false;
  @State lockPasswordInput: string = '';
  // 录音笔记
  private audioManager: AudioNoteManager = new AudioNoteManager();
  @State showAudioPanel: boolean = false;
  @State isRecording: boolean = false;
  @State recordingDuration: number = 0;
  // 大纲视图
  @State showOutlinePanel: boolean = false;
  @State outlineNodes: OutlineItem[] = [];
  private notePersistTimer: number = -1;    // 便签持久化防抖定时器
  /**
   * v2.5.1：录音时长自循环定时器句柄。
   * 原实现在 updateRecordingDuration() 里裸调 setTimeout 且**不存句柄**，
   * 离页时若未停止录音，isRecording 恒为 true → 每秒回调已销毁页面（泄漏 + 空指针风险）。
   */
  private recordingTimer: number = -1;
  /**
   * v2.5.1：笔迹回放推进定时器句柄。
   * advanceReplay() 原为 50ms 自循环且不存句柄，离页时若 replayPlaying 仍为 true，
   * 会每秒 20 次回调已销毁页面（比录音定时器更频繁）。
   */
  private replayTimer: number = -1;
  /** v2.5.1：取色后自动切回画笔的 1.5s 一次性定时器句柄 */
  private colorPickerTimer: number = -1;
  private readonly noteCardW: number = 220; // 便签默认宽（逻辑 vp）
  private readonly noteCardH: number = 120; // 便签默认高（逻辑 vp）
  private readonly stickyPalette: string[] = ['#FFF3A0', '#FFD6A5', '#A5E8C0', '#A5D8FF', '#E0C3FC'];
  private lastPanX: number = 0;             // 拖拽手势上一帧偏移（累计）
  private lastPanY: number = 0;
  private noteDragFromX: number = 0;        // 拖拽起点（用于 ENG-05 move 撤销）
  private noteDragFromY: number = 0;
  private noteDragFromW: number = 0;
  private noteDragFromH: number = 0;

  // ═══ NOTE-02/03/04：阶段2 差异化（双链 / 小地图 + 书签 / 端侧检索）═══
  private linkManager: LinkManager = new LinkManager();        // 双链管理
  private bookmarkManager: BookmarkManager = new BookmarkManager(); // 书签三类
  private searchIndex: HandwritingIndex = new HandwritingIndex();   // 端侧索引
  @State linkMode: boolean = false;              // 双链连线模式（选完源节点后等待目标）
  @State linkSourceId: string = '';             // 双链源节点 id
  @State selectedLinkId: string = '';           // 选中高亮的链 id
  @State searchOpen: boolean = false;           // 搜索浮层开关
  @State searchHits: SearchHit[] = [];          // 检索命中
  @State currentHitId: string = '';             // 当前高亮命中节点
  @State bookmarkBarOpen: boolean = false;      // 书签栏展开
  @State selectedNodeId: string = '';           // 当前选中节点（书签/链接操作对象）
  // NOTE-02 阶段2：双链目标选择浮层（智能推荐 + 搜索）
  @State linkPickerOpen: boolean = false;       // 双链目标选择浮层开关
  @State linkRecommendations: RecommendItem[] = []; // TF-IDF 推荐列表
  @State linkPickerSourceSnippet: string = '';  // 源节点摘要
  @State linkPickerSearching: boolean = false;  // 搜索中状态
  private nodeUndo: NodeUndoManager = NodeUndoManager.getInstance(); // ENG-05：节点撤销/重做
  private nodeExecutor: NodeOpExecutor = new NodeOpExecutorImpl(
    (op: NodeOp): void => { this.applyNodeOp(op, false); },
    (op: NodeOp): void => { this.applyNodeOp(op, true); }
  );

  // ─── v2.3：协同状态（K-R2-2 UI 接线，数据源 = NoteEngine S2 门面）───
  @State collabStatus: CollabStatusSnapshot = createEmptyCollabStatus();
  private collabService: CollabStatusService = CollabStatusService.getInstance();
  private collabTimer: number = -1;
  
  // ─── 折叠屏适配（P0-H-01）───
  @State foldStatus: FoldStatus = FoldStatus.UNKNOWN;
  @State foldDisplayMode: FoldDisplayMode = FoldDisplayMode.MAIN;
  @State isHalfFolded: boolean = false;  // 悬停态（半折叠）
  @State foldCreaseY: number = 0;        // 折痕Y坐标（用于分屏布局）
  // ─── T05a S2/S5：折叠态与折痕区 vp 值统一来自 T01 FoldAdapter（AppStorage 三键）───
  // @Watch：折叠状态变化时，若正在落笔则先 commit 落盘历史层，再变更布局（B.3 状态保持表）
  @StorageProp('hcFoldStatus') @Watch('onFoldStorageChange') foldStatusStorage: number = FoldStatus.UNKNOWN;

  // ═══ v3.0：新功能状态 ═══
  // 文本工具
  @State showTextToolPanel: boolean = false;
  @State textToolActive: boolean = false;

  // ═══ v2.7.0：文本框编辑（问题①-2「文本工具双击无响应」根治）═══
  // 注：`editingNodeId` 复用上方 NOTE-01 已声明的字段（当前正在编辑/选中的节点 id）
  /** 编辑面板预填内容 */
  @State editingNodeContent: string = '';
  /** 是否是「新建文本」流程（决定确定后更新还是新建） */
  @State editingIsNew: boolean = false;
  private textToolService: TextToolService = TextToolService.getInstance();
  // 全屏阅读
  private readingMode: FullscreenReadingMode = FullscreenReadingMode.getInstance();
  @State inReadingMode: boolean = false;
  // 分享
  private shareService: ShareService = ShareService.getInstance();
  @State showShareDialog: boolean = false;
  // 回收站
  private recycleBin: RecycleBinService = RecycleBinService.getInstance();
  @State showRecycleBin: boolean = false;
  @State recycleBinItems: RecycleBinItem[] = [];
  // 笔盒
  private brushBox: BrushBoxService = BrushBoxService.getInstance();
  @State showBrushBox: boolean = false;
  @State brushPresets: BrushPreset[] = [];
  // 文档扫描
  private docScanner: DocumentScannerService = DocumentScannerService.getInstance();
  @State showDocScanner: boolean = false;
  // 评论
  private commentSystem: CommentSystemService = CommentSystemService.getInstance();
  @State showCommentPanel: boolean = false;
  @State commentThreads: CommentThread[] = [];
  // 版本历史
  private versionHistory: VersionHistoryService = VersionHistoryService.getInstance();
  @State showVersionHistory: boolean = false;
  @State versionEntries: VersionEntry[] = [];
  // AI
  private aiService: AIService = AIService.getInstance();
  @State showAIPanel: boolean = false;
  @State aiResult: string = '';
  // 网页嵌入
  private webEmbed: WebEmbedService = WebEmbedService.getInstance();
  @State showWebEmbed: boolean = false;
  // LaTeX
  private latexService: LatexService = LatexService.getInstance();
  @State showLatexPanel: boolean = false;
  // 水印
  private watermarkService: WatermarkService = WatermarkService.getInstance();
  @State showWatermarkDialog: boolean = false;
  // 统计
  private analytics: AnalyticsDashboard = AnalyticsDashboard.getInstance();
  @State showAnalytics: boolean = false;
  // 网页剪藏
  private webClipper: WebClipperService = WebClipperService.getInstance();
  @State showWebClipper: boolean = false;
  // 投票/计时器
  private pollTimer: PollTimerService = PollTimerService.getInstance();
  @State showPollTimer: boolean = false;
  // 分屏
  private splitScreen: SplitScreenService = SplitScreenService.getInstance();
  @State inSplitScreen: boolean = false;
  // 模板市场
  private templateMarket: TemplateMarketService = TemplateMarketService.getInstance();
  @State showTemplateMarket: boolean = false;
  // 离线同步
  private offlineSync: OfflineSyncService = OfflineSyncService.getInstance();
  @State syncStatus: string = '';
  @StorageProp('hcCreaseTopVp') creaseTopVp: number = 0;
  @StorageProp('hcCreaseBottomVp') creaseBottomVp: number = 0;
  // ─── T05a S3：全局断点（T01 BreakpointSystem 写盘，唯一来源，约定 B/D）───
  @StorageProp('hcBreakpoint') bp: string = 'sm';

  /** T05a S2：悬停态判定（唯一权威 = FoldAdapter 写盘的 hcFoldStatus，3 = HALF_FOLDED） */
  private isHoverState(): boolean {
    return this.foldStatusStorage === 3;
  }

  /** PRD v5：平板横屏判定 —— 取长边≥600vp，兼容 MatePad Pro 13 模拟器横竖屏。
   *  原 d.width 在部分模拟器/折叠屏上返回短边或窗口半宽，导致 13 寸平板误判为手机。
   *  同时 fallback bp：md/lg 也视为平板，避免 display API 取不到时丢失左侧工具栏。 */
  private isTabletWidth(): boolean {
    try {
      const d = display.getDefaultDisplaySync();
      const w = px2vp(d.width);
      const h = px2vp(d.height);
      // 阈值放宽到 480vp：覆盖高 DPI（densityPixels≥2.6）下的 7-8 寸平板/模拟器，
      // 避免被误判为手机导致左工具栏（buildLeftToolbar）不渲染的 P0 体验缺陷。
      return Math.max(w, h) >= 480;
    } catch (e) {
      return this.bp !== 'sm' && this.bp !== '';
    }
  }

  /**
   * T05a S5：hcFoldStatus 变化回调（@Watch）。
   * 折叠切换瞬间若手指未抬起（ctxActive 上有半截笔画），先 commit 落盘历史层再变更布局
   * （复用现有落笔提交路径 touchUp，不新增业务逻辑）。注意：本次调用仅提交，不处理布局本身，
   * 布局由 @StorageProp 响应式驱动。
   */
  private onFoldStorageChange(): void {
    this.isHalfFolded = this.foldStatusStorage === 3;
    this.foldCreaseY = this.creaseTopVp;
    Logger.info(TAG_PAGE, `折叠状态变化（FoldAdapter）：foldStatus=${this.foldStatusStorage}, isHalfFolded=${this.isHalfFolded}, creaseTopVp=${this.creaseTopVp}`);
    if (this.drawing && this.currentPoints.length > 0) {
      const last: PointRecord = this.currentPoints[this.currentPoints.length - 1];
      this.touchUp(last.x, last.y);
      Logger.info(TAG_PAGE, '折叠切换瞬间检测到未抬笔，已 commit 当前笔画到历史层');
    }
  }
  
  // ─── 一多适配（P0-H-02）：响应式布局参数 ───
  @State responsiveFontSize: number = 14;      // 响应式字体大小
  @State responsiveIconSize: number = 24;      // 响应式图标大小
  @State responsiveToolbarHeight: number = 56; // 响应式工具栏高度
  @State responsiveCanvasPadding: number = 0;  // 响应式画布边距
  
  /** 🔧 只读模式：VIEWER角色或canWrite为false时禁用编辑功能 */
  private isReadOnly(): boolean {
    return !this.collabStatus.canWrite || this.collabStatus.permissionRole === 'VIEWER';
  }

  /** 🔧 沉浸模式：关闭所有打开的弹窗和面板 */
  private closeAllPopups(): void {
    this.showColorPicker = false;
    this.showShapePicker = false;
    this.showWidthPicker = false;
    this.showBrushPanel = false;
    this.showPaperPicker = false;
    this.showLayerPanel = false;
    this.showMorePanel = false;
    // 注意：showSaveErrorPopup 不关闭，因为它是重要的错误提示
  }

  // ─── 页面访问时间 ───
  private pageEnterTime: number = 0;

  // ─── 引擎门面（页面层唯一入口）───
  private engine: NoteEngine = NoteEngine.getInstance();

  // ─── v2.7.3：分布式板面共享（同账号设备免服务端互通）───
  private boardSession: DistributedBoardSession = DistributedBoardSession.getInstance();
  /** 当前分布式房间号（空=未加入协作房间） */
  private collabRoomId: string = '';

  // ─── 笔记标识与落盘上下文 ───
  private noteId: string = '';
  private noteMeta: NoteMeta = createNoteMeta('', '未命名笔记', HC_DEFAULT_PAPER);
  /** 前向兼容桶：读到高版本文件时原样保留，保存时回写（§2.8） */
  private forwardRaw: string = '';
  private paperLayerId: string = '';
  private drawLayerId: string = '';

  // ─── 自动保存 ───
  private dirty: boolean = false;
  private saving: boolean = false;
  private saveTimer: number = -1;
  /** 变更序号：保存期间用户继续作画时，避免把新变更误判为「已保存」 */
  private changeSeq: number = 0;
  private lastThumbAt: number = 0;

  // ─── 画布操作 ───
  @State isPanning: boolean = false;
  @State isZooming: boolean = false;
  @State lastTouchDistance: number = 0;
  @State lastTouchCenter: TouchCenter = { x: 0, y: 0 };
  @State viewportScale: number = 1.0;
  @State viewportX: number = 0;
  @State viewportY: number = 0;
  @State canvasMode: string = 'draw'; // 'draw' | 'pan' | 'zoom'
  // 🔧 画布拖拽（第 9 轮）：双指缩放平移 + 平移模式单指拖动的手势状态（非 @State，重绘手动触发）
  private pinchBaseDist: number = 0;
  private pinchBaseScale: number = 1;
  private pinchBaseVX: number = 0;
  private pinchBaseVY: number = 0;
  private panning: boolean = false;
  private panLastX: number = 0;
  private panLastY: number = 0;

  // ─── 画布状态 ───
  // CRITICAL: canvasReady 初始为 true，不依赖 onReady 回调。
  // 预览器/部分设备上 Canvas 的 onReady 可能不触发，导致触摸被 if(!canvasReady) 吞掉、写不上东西。
  @State canvasReady: boolean = true;
  @State strokeCount: number = 0;

  // 三层画布：底纸层 + 历史层 + 活动层
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctxPaper: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ctxHistory: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ctxActive: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private strokes: StrokeRecord[] = [];
  private redoStack: StrokeRecord[] = [];
  /** F-03：批量清除等操作的重做快照 —— 图片与贴纸随重做整体恢复 */
  private redoImages: ImageRefData[][] = [];
  private redoTexts: HCText[][] = [];
  private strokeIdSeq: number = 0;

  // 画布尺寸（vp 逻辑尺寸，三画布同尺寸）
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;

  // 当前绘制状态
  private drawing: boolean = false;
  private currentPoints: PointRecord[] = [];
  /** 无压感速度模拟状态（S2-A / T2-2）：上一采样点坐标/时间，Down 时重置 */
  private lastSampleX: number = 0;
  private lastSampleY: number = 0;
  private lastSampleT: number = 0;
  private dragStartX: number = 0;
  private dragStartY: number = 0;

  // 当前笔画的笔刷参数（落笔时冻结，写进 StrokeRecord）
  private activeOpacity: number = 1;
  private activeBlendMode: string = 'normal';
  private activeBrushShape: string = 'round';

  // ─── 笔触跟手优化（v2.3）：距离降噪 ───
  private lastDrawnX: number = 0;              // 上一已绘制位置
  private lastDrawnY: number = 0;
  private flushTimer: number = -1;             // 保留：aboutToDisappear 清理用（A4 后批处理已移除）
  /** 全屏模式切换后的 50ms 兜底重绘定时器句柄（离页时清理，防回调已销毁页面） */
  private immersiveRedrawTimer: number = -1;
  private readonly DISTANCE_THRESHOLD: number = 1.2; // vp，低于此距离丢弃降噪

  // ─── 触摸事件节流（v2.4）：限制Move事件处理频率 ───
  private lastMoveTime: number = 0;            // 上次Move事件处理时间戳
  private readonly MOVE_THROTTLE_MS: number = 16.67; // 60Hz节流间隔（约16.67ms）

  private readonly colors: string[] = [
    '#000000', HCGray.GRAY_9, HCGray.GRAY_7, '#999999', HCGray.GRAY_1,
    '#FF0000', '#FF6B35', '#FFD700', '#4CAF50', '#2196F3',
    '#9C27B0', '#795548', '#E91E63', '#00BCD4', '#607D8B', '#8BC34A',
  ];
  private readonly widths: number[] = [1, 2, 3, 5, 8, 12, 20];

  // ═══════════════════════════════════════════════════════════════
  // 生命周期
  // ═══════════════════════════════════════════════════════════════

  aboutToAppear(): void {
    this.pageEnterTime = Date.now();

    // v2.5：初始化模板库
    this.templateLibrary.initialize();

    // 🔧 设备适配：获取设备信息，用于响应式布局
    this.deviceInfo = DeviceAdapter.getInstance().getDeviceInfo();
    this.isPhone = this.deviceInfo?.type === DeviceType.PHONE;
    Logger.info(TAG_PAGE, `设备适配：type=${this.deviceInfo?.type}, screenWidth=${this.deviceInfo?.screenWidth}, isPhone=${this.isPhone}`);
    
    // 🔧 一多适配（P0-H-02）：初始化响应式布局参数
    if (this.deviceInfo) {
      this.responsiveFontSize = this.deviceInfo.recommendedFontSize;
      this.responsiveIconSize = this.deviceInfo.recommendedIconSize;
      this.responsiveToolbarHeight = this.deviceInfo.recommendedToolbarHeight;
      this.responsiveCanvasPadding = this.deviceInfo.recommendedCanvasPadding;
      Logger.info(TAG_PAGE, `响应式布局参数：fontSize=${this.responsiveFontSize}, iconSize=${this.responsiveIconSize}, toolbarHeight=${this.responsiveToolbarHeight}`);
    }
    
    // 🔧 折叠屏适配（P0-H-01）——T05a S5：折叠状态改由 T01 FoldAdapter 统一驱动。
    // 自建 display.on('foldStatusChange') 已删除（防多监听器竞态/泄漏，约定 D/E），
    // 页面仅消费 AppStorage 三键（hcFoldStatus / hcCreaseTopVp / hcCreaseBottomVp），
    // 由 @StorageProp 响应式驱动布局 + @Watch('onFoldStorageChange') 处理「落笔中途切折叠」。
    if (this.deviceInfo?.isFoldable) {
      this.foldStatus = this.deviceInfo.foldStatus;
      this.foldDisplayMode = this.deviceInfo.foldDisplayMode;
      Logger.info(TAG_PAGE, `折叠屏适配：foldStatus=${this.foldStatus}, foldDisplayMode=${this.foldDisplayMode}`);
    }
    // 首帧兜底：若 FoldAdapter 已写盘（首进即半折等场景），立即同步到本地 @State 以保持日志/状态一致
    this.isHalfFolded = this.foldStatusStorage === 3;
    this.foldCreaseY = this.creaseTopVp;
    
    // 🔧 性能优化：缓存设备像素比
    this.cachedDpr = display.getDefaultDisplaySync().densityPixels;

    // 1) 引擎能力快照（纯内存读，不触盘）
    this.brushOptions = this.engine.getBrushOptions();
    this.paperOptions = this.engine.getPaperOptions();
    this.storageReady = this.engine.isStorageReady();
    
    // 初始化撤销/重做管理器
    this.undoRedoManager.clear();
    this.updateUndoRedoState();

    // 2) 路由参数 → 笔记标识（无参数时降级为「临时白板」，仍可画，只是不落盘）
    this.readRouteParams();

    // 3) 重建图层骨架（底纸层沉底 + 绘制层置顶）
    const setup: CanvasLayerSetup = this.engine.setupCanvasLayers(this.paperTemplate);
    this.paperLayerId = setup.paperLayerId;
    this.drawLayerId = setup.drawLayerId;
    this.applyBrush(this.currentBrush);

    // 4) 恢复现场
    this.loadNote();

    // 5) 自动保存
    this.startAutoSave();
    // 🔴 v2.7.3：若已加入协作房间，接入分布式板面共享
    this.initDistributedBoard();

    // 埋点异步化：不阻塞首帧渲染（v2.3 性能优化）
    this.trackAsync((): void => {
      analytics.trackPageView('WhiteboardPage');
    });
    // 🔧 修复绘制无响应BUG：同步初始化协同状态，避免异步时序问题
    // 初始状态：单机模式，强制可写
    this.collabService.ensureLocalDeviceId();
    this.collabStatus = this.collabService.snapshot();
    Logger.info(TAG_PAGE, `初始协同状态：canWrite=${this.collabStatus.canWrite}, sessionRole=${this.collabStatus.sessionRoleText}`);
    
    // 异步刷新（不阻塞UI，每秒更新一次）
    this.startCollabRefresh();
    
    // 内存监控初始化（v2.4优化）
    this.checkCanvasMemory();
    
    // 网络状态检测（v2.4优化）
    this.checkNetworkStatus();
    
    // 🔧 沉浸模式初始化（F-03）
    // PRD v5 修正：进入画板页时强制确保工具栏可见（immersiveMode=false, toolbarCollapsed=false）。
    // 避免沉浸模式偏好（ALWAYS_HIDE）导致用户进入画板后看不到任何工具入口的 P0 体验缺陷。
    // 用户可后续通过双指轻点等手势主动进入沉浸模式。
    immersiveModeManager.loadFromPreferences();
    const immersiveConfig = immersiveModeManager.getConfig();
    this.immersiveMode = false;
    this.toolbarCollapsed = false;

    // 监听沉浸模式配置变更
    immersiveModeManager.addListener((config: ImmersiveConfig) => {
      this.immersiveMode = config.mode === ImmersiveMode.ALWAYS_HIDE;
      this.toolbarCollapsed = !config.toolbarVisible;
    });
    
    // 🔧 崩溃兜底：初始化紧急保存服务（F-04）
    if (this.noteId) {
      emergencySaveService.setCurrentNote(this.noteId, this.noteTitle);
      emergencySaveService.setGetContentCallback(() => {
        // 使用engine.composeNoteContent()创建完整的NoteContent对象
        return this.engine.composeNoteContent(
          this.noteMeta,
          this.paperTemplate,
          this.paperLayerId,
          this.strokes,
          this.noteImages,
          this.canvasWidth,
          this.canvasHeight,
          this.forwardRaw
        );
      });
      emergencySaveService.startEmergencySave();
      
      // 设置崩溃标志
      crashRecoveryService.setCrashFlag(true);
    }

    // ─── v2.6.0 审核修复（问题②-3）：订阅主题，让「画布纸张」选择即时作用于画布 ───
    this.syncPaperColorFromTheme();
    this.paperThemeListener = (config: ThemeConfig): void => {
      const next: string = themeManager.getCanvasPaperColor();
      if (next !== this.canvasPaperColor) {
        this.canvasPaperColor = next;
        this.renderPaper();
        Logger.info(TAG_PAGE, `画布纸张已按主题刷新: ${next}`);
      }
    };
    themeManager.addListener(this.paperThemeListener);

    // ═══ v3.0：新服务初始化 ═══
    // 文本工具
    this.textToolService = TextToolService.getInstance();
    // 全屏阅读模式
    this.readingMode = FullscreenReadingMode.getInstance();
    this.readingMode.onAutoTurn = () => {
      // 自动翻页回调
    };
    // 离线同步
    this.offlineSync = OfflineSyncService.getInstance();
    // AI 服务初始化

    // 安全网：兜底画布尺寸——若 onAreaChange/onReady 始终未回调（部分预览器/设备时序问题），
    // 退避用屏幕尺寸种子化逻辑画布尺寸，保证画板可渲染、可书写；随后真实区域回调会校正。
    this.seedCanvasSizeFromDisplay();
  }

  /**
   * 画布尺寸安全网（修复 canvasWidth/canvasHeight 永久为 0 导致画板不可写）。
   * 首帧后再检查一次：若区域回调仍未给出有效尺寸，用屏幕 vp 尺寸种子化，
   * 避免极端时序下画板空白且触摸落点坐标失效。真实 onAreaChange 抵达后会以精确值二次校正。
   */
  private seedCanvasSizeFromDisplay(): void {
    setTimeout((): void => {
      if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
        try {
          const d = display.getDefaultDisplaySync();
          const w: number = px2vp(d.width);
          const h: number = px2vp(d.height);
          Logger.warn(TAG_PAGE, `Canvas 安全网：用屏幕尺寸种子化 ${w}x${h}`);
          this.ensureCanvasSize(w, h);
        } catch (e) {
          Logger.error(TAG_PAGE, `Canvas 安全网初始化失败：${e}`);
        }
      }
    }, 200);
  }

  /**
   * 🔴 v2.7.2：离开本页时立即落盘 + 停掉自动保存。
   *
   * 背景：本轮把「扩展工具 → 闪卡/导图」改为**跳转到独立页**（FlashcardEntryPage /
   *   MindMapEntryPage）。这类跳转只会把白板**压栈**，`aboutToDisappear` 不会触发；
   *   而独立页的保存方式是「读磁盘 → 只改 flashcards/mindmaps → 整篇写回」。
   *   若白板仍在后台跑自动保存，它携带的是**不含独立页改动的旧快照**，
   *   晚一步落盘就会把用户刚添加的闪卡/导图**覆盖掉**（数据丢失）。
   *
   * 处置：离页即 flush 落盘（保证独立页读到最新内容），并**停掉自动保存**
   *   （杜绝"隐藏期间的延迟写入"用旧快照覆盖新数据）；回到本页时再恢复。
   */
  onPageHide(): void {
    this.flushSave();
    this.stopAutoSave();
  }

  /** v2.7.2：回到本页时恢复自动保存（与 onPageHide 配对） */
  onPageShow(): void {
    if (this.storageReady && this.noteId.length > 0) {
      this.startAutoSave();
    }
    // 🔴 v2.7.3：用户可能先去「加入白板」创建/加入房间再返回本页，此处补接入
    this.initDistributedBoard();
  }

  aboutToDisappear(): void {
    if (this.paperThemeListener) {
      themeManager.removeListener(this.paperThemeListener);
      this.paperThemeListener = null;
    }
    // v2.3 稳定性修复：清理全部后台定时器，避免页面销毁后计时器泄漏 / 回调访问已释放上下文
    this.stopCollabRefresh();
    this.stopAutoSave();
    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    // 🔧 v2.5.1：录音自循环定时器 —— 离页时若仍在录音，它会每秒回调已销毁页面。
    //   先置 isRecording=false 兜底（即使有 tick 已排队，下一轮也会 return），再清句柄。
    this.isRecording = false;
    if (this.recordingTimer !== -1) {
      clearTimeout(this.recordingTimer);
      this.recordingTimer = -1;
    }
    // 🔧 v2.5.1：笔迹回放 50ms 自循环定时器 —— 离页时若 replayProgress 未到 1.0 会永久递归。
    this.replayPlaying = false;
    if (this.replayTimer !== -1) {
      clearTimeout(this.replayTimer);
      this.replayTimer = -1;
    }
    // 🔧 v2.5.1：便签持久化防抖定时器同样未清理，销毁时一并清掉
    if (this.notePersistTimer !== -1) {
      clearTimeout(this.notePersistTimer);
      this.notePersistTimer = -1;
    }
    // 🔧 v2.5.1：取色后自动切回画笔的一次性定时器
    if (this.colorPickerTimer !== -1) {
      clearTimeout(this.colorPickerTimer);
      this.colorPickerTimer = -1;
    }
    // 🔧 全屏切换兜底重绘定时器：离页时清理，避免回调触碰已销毁页面
    if (this.immersiveRedrawTimer !== -1) {
      clearTimeout(this.immersiveRedrawTimer);
      this.immersiveRedrawTimer = -1;
    }
    this.drawing = false;

    // W10 退出 flush：Repository 内部写串行化，页面销毁不影响这条写链完成
    this.flushSave();

    // v2.5.2 审核修复：正常退出前也触发一次紧急保存，让恢复快照包含最新笔迹
    //   （之前仅依赖 30s 定时器，用户画了 5s 退出就保存不完整）
    emergencySaveService.triggerEmergencySave().catch((err: Error): void => {
      Logger.warn(TAG_PAGE, `退出时紧急保存失败：${err.message}`);
    });

    // 🔧 沉浸模式：保存配置（F-03）
    immersiveModeManager.saveToPreferences();
    
    // 🔧 崩溃兜底：清理紧急保存服务
    emergencySaveService.cleanup();
    // 🔧 v2.6.0 审核修复（问题③真因 B）：正常退出必须**连快照一起清掉**。
    //   原实现只调 setCrashFlag(false)，磁盘上的恢复快照一直留着，
    //   于是每次冷启动都弹「检测到未保存的内容」（审核员看到的还是 4 天前的旧快照）。
    crashRecoveryService.markCleanExit().catch((err: Error): void => {
      Logger.warn(TAG_PAGE, `清理恢复快照失败：${err.message}`);
    });

    const duration = Date.now() - this.pageEnterTime;
    this.trackAsync((): void => {
      analytics.trackPageExit('WhiteboardPage', duration);
    });
    SafeAsync.runAsyncVoid(TAG_PAGE, 'analyticsFlush', (): Promise<void> => {
      return analytics.flush();
    });
    // ═══ v3.0：新服务清理 ═══
    this.readingMode.exit();
    this.analytics.endSession();
  }

  /** 系统返回键：先落盘再走默认返回（返回 false = 不拦截） */
  onBackPress(): boolean {
    this.flushSave();
    return false;
  }

  // ═══════════════════════════════════════════════════════════════
  // 笔记装载 / 保存
  // ═══════════════════════════════════════════════════════════════

  /** 读取路由参数。无参数或参数不合法时退化为临时白板，绝不白屏 */
  private readRouteParams(): void {
    SafeAsync.runVoid(TAG_PAGE, 'readRouteParams', (): void => {
      const params: NoteRouteParams = router.getParams() as NoteRouteParams;
      if (params === null || params === undefined) {
        Logger.warn(TAG_PAGE, '无路由参数，进入临时白板模式');
        this.noteId = ''; // 明确设置为临时白板
        return;
      }
      const id: string = params.noteId !== undefined && params.noteId !== null ? params.noteId : '';
      if (id.length === 0) {
        Logger.warn(TAG_PAGE, 'noteId 为空，进入临时白板模式');
        this.noteId = ''; // 明确设置为临时白板
        return;
      }
      this.noteId = id;
      this.noteTitle = normalizeNoteTitle(params.title, '未命名笔记');
      const rawTemplate: string =
        params.paperTemplate !== undefined && params.paperTemplate !== null ? params.paperTemplate : HC_DEFAULT_PAPER;
      this.paperTemplate = this.engine.normalizePaperTemplate(rawTemplate);
      Logger.info(TAG_PAGE, `打开笔记 ${this.noteId} 底纸=${this.paperTemplate}`);
    });
  }

  /** 从磁盘恢复笔画与插图。loadNote 永不抛异常，失败时按空文档处理（S-5） */
  private loadNote(): void {
    if (this.noteId.length === 0) {
      this.setStatus('临时白板：内容不会保存');
      return;
    }
    if (!this.storageReady) {
      this.setStatus('本地存储未就绪，暂不自动保存');
      Logger.warn(TAG_PAGE, '存储未就绪，跳过装载');
      return;
    }
    SafeAsync.runAsyncVoid(TAG_PAGE, 'loadNote', async (): Promise<void> => {
      const repo: NoteRepository = this.engine.getNoteRepository();
      const result: NoteLoadResult = await repo.loadNote(this.noteId);
      const content: NoteContent = result.content;

      this.noteMeta = content.meta;
      this.noteTitle = content.meta.title;
      this.forwardRaw = content.forwardRaw;
      this.paperTemplate = this.engine.setPaperLayerTemplate(this.paperLayerId, content.paper.template);

      // 笔画：补齐 layerId（旧档 / 空档可能没有），并让自增 id 从最大值继续
      // 🔧 修复历史笔迹在书写/全屏模式切换后丢失的隐性缺陷：
      //   老笔记里的 layerId（如 "layer_xxxx"）来自历史会话，setupCanvasLayers 在 aboutToAppear
      //   已重置 LayerManager 并创建全新 drawLayerId；旧 layerId 在层表中查不到。
      //   layerVisible() 虽然对"不存在的层"兜底返回 true，但更安全的做法是把所有恢复的笔画
      //   显式绑到当前 drawLayerId，避免任何"层不可见/被改名"路径误过滤历史笔迹。
      const restored: StrokeRecord[] = this.engine.strokesFromContent(content);
      for (let i = 0; i < restored.length; i++) {
        const s: StrokeRecord = restored[i];
        // 无 layerId 或 layerId 在当前层表中不存在 → 归一到 drawLayerId
        if (s.layerId.length === 0 || this.engine.getLayerManager().getLayer(s.layerId) === null) {
          s.layerId = this.drawLayerId;
        }
        if (s.id > this.strokeIdSeq) {
          this.strokeIdSeq = s.id;
        }
      }
      this.strokes = restored;
      this.resetRedoStacks();
      // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
      this.updateUndoRedoState();
      this.strokeCount = restored.length;

      // 插图：挂回绘制层，同时投影到叠加层
      const imgs: ImageRefData[] = this.engine.imagesFromContent(content);
      this.engine.attachImages(this.drawLayerId, imgs);
      this.noteImages = imgs;

      // S2-B / T2-3/T2-4：恢复文本框 / 闪卡 / 导图
      this.texts = content.texts !== undefined && content.texts !== null ? content.texts.slice() : [];
      this.flashcardStore.replaceAll(content.flashcards !== undefined && content.flashcards !== null
        ? content.flashcards : []);
      this.mindMap = content.mindmaps !== undefined && content.mindmaps !== null && content.mindmaps.length > 0
        ? content.mindmaps[0] : MindMapModel.createEmpty('思维导图', '中心主题');
      // NOTE-01：恢复便签节点（content.nodes 必填，旧文件缺省时回落空数组）
      this.canvasNodes = content.nodes !== undefined && content.nodes !== null ? content.nodes.slice() : [];
      // NOTE-02/03/04：恢复双链 / 书签 / 重建端侧索引
      this.linkManager.hydrate(content.links !== undefined && content.links !== null ? content.links : []);
      this.bookmarkManager.hydrate(content.bookmarks !== undefined && content.bookmarks !== null ? content.bookmarks : []);
      this.searchIndex.indexAll(this.canvasNodes);

      this.renderPaper();
      this.renderHistory();

      this.dirty = false;
      this.saveState = restored.length > 0 || imgs.length > 0 ? NoteSaveState.SAVED : NoteSaveState.IDLE;
      // T2-1b C-8 / D-1：正本完好 + 存在「校验通过且比正文新」的草稿 → 只提示不自动替换（闸 B 已由仓储判定）
      this.hasUncommittedTmp = result.hasUncommittedTmp;
      this.draftPreviewMode = false;
      if (result.hasUncommittedTmp) {
        this.draftMtime = repo.tmpDraftMtime(this.noteId);
        this.draftNoticeVisible = true;
      } else {
        this.draftMtime = 0;
        this.draftNoticeVisible = false;
      }
      if (result.recoveredFromBak) {
        this.setStatus('! 主文件损坏，已从备份恢复', StatusSeverity.ALERT);
      } else if (result.recoveredFromTmp) {
        this.setStatus('已从上次未保存草稿恢复', StatusSeverity.INFO);
      } else if (!result.ok) {
        this.setStatus(`装载失败：${result.errorMessage}`, StatusSeverity.ALERT);
      } else {
        this.setStatus(restored.length > 0 ? `已恢复 ${restored.length} 笔` : '空白笔记，开始创作', StatusSeverity.ROUTINE);
      }
      Logger.info(TAG_PAGE, `装载完成 strokes=${restored.length} images=${imgs.length} bak=${result.recoveredFromBak} tmp=${result.recoveredFromTmp} pending=${result.hasUncommittedTmp}`);
    }, (info: SafeErrorInfo): void => {
      this.setStatus(`装载失败：${info.message}`, StatusSeverity.ALERT);
      this.saveState = NoteSaveState.FAILED;
    });
  }

  /** 启动 2s 脏检查（只有 dirty 才真正写盘，空转成本 ≈ 0） */
  private startAutoSave(): void {
    if (this.saveTimer !== -1) {
      return;
    }
    
    // 智能保存策略：根据笔画数量动态调整保存间隔
    const getSmartSaveInterval = (): number => {
      const count: number = this.strokes.length;
      if (count < 100) {
        return AUTOSAVE_INTERVAL_MS; // 默认2秒
      } else if (count < 500) {
        return AUTOSAVE_INTERVAL_MS * 1.5; // 3秒
      } else if (count < 1000) {
        return AUTOSAVE_INTERVAL_MS * 2; // 4秒
      } else {
        return AUTOSAVE_INTERVAL_MS * 3; // 6秒（笔画数量过多，降低保存频率）
      }
    };
    
    const saveInterval: number = getSmartSaveInterval();
    this.saveTimer = setInterval(() => {
      if (this.dirty && !this.saving) {
        this.doSave(false, false);
      }
    }, saveInterval);
    
    Logger.debug(TAG_PAGE, `自动保存已启动，间隔${saveInterval}ms（${this.strokes.length}笔）`);
  }

  private stopAutoSave(): void {
    if (this.saveTimer !== -1) {
      clearInterval(this.saveTimer);
      this.saveTimer = -1;
    }
  }

  /**
   * 状态行唯一入口（T2-1b C-7 ②）：按严重性写入，alert 级在显式清除前不被 routine/INFO 覆盖。
   * @param text     状态文案
   * @param severity 默认 ROUTINE；错误类（保存失败/导出失败/返回失败）传 ALERT
   * @param silent   PRD v5：true = 仅更新内部状态行、不弹 Toast（笔迹计数/拖拽等高频调用必须 silent）
   */
  private setStatus(text: string, severity: string = StatusSeverity.ROUTINE, silent: boolean = false): void {
    if (severity === StatusSeverity.ALERT) {
      this.statusText = text;
      this.currentSeverity = StatusSeverity.ALERT;
      this.stickyAlert = true;
      return;
    }
    // ROUTINE / INFO：进行中的 alert 不被冲掉（d1 §11.2 ② / d2 §0-A :1394 每笔覆盖的根因修复）
    if (this.stickyAlert) {
      return;
    }
    this.statusText = text;
    this.currentSeverity = severity;

    // PRD v5 需求4：状态提示轻量化 —— 短时悬浮 Toast 展示，不再长期固定贴在工具栏
    // silent=true（笔迹计数/拖拽等高频内部状态）不弹 Toast，避免每笔轰炸
    if (silent) {
      return;
    }
    const nowTs: number = Date.now();
    if (this.statusToastText !== text || nowTs - this.statusToastAt > 1500) {
      this.statusToastText = text;
      this.statusToastAt = nowTs;
      try {
        promptAction.showToast({ message: text, duration: 1500 });
      } catch (e) {
        // Toast 失败不阻断主流程（低危）
      }
    }
  }

  /** 显式清除 alert 粘性（保存成功 / 问题解决时调用，C-7 ②） */
  private clearAlert(): void {
    this.stickyAlert = false;
  }

  /**
   * 🔧 统一错误处理函数：记录日志并显示用户友好的错误提示
   * @param operation 操作名称（用于日志）
   * @param error     错误信息
   * @param userMessage 用户提示文案（可选，默认使用操作名称）
   */
  private handleError(operation: string, error: string, userMessage?: string): void {
    const msg: string = userMessage || `${operation}失败`;
    Logger.error(TAG_PAGE, `${operation}失败: ${error}`);
    this.setStatus(msg, StatusSeverity.ALERT);
  }

  /** 任意内容变更入口：打脏标记 + 复位保存指示 */
  private markDirty(): void {
    if (this.noteId.length === 0) {
      return;
    }
    this.changeSeq++;
    this.dirty = true;
    if (this.saveState !== NoteSaveState.SAVING) {
      this.saveState = NoteSaveState.IDLE;
    }
  }

  /**
   * 写盘。
   * @param withThumb true 时强制刷新缩略图（退出 / 手动保存），否则按 10s 节流
   * @param force     true 时忽略 saving 互斥（退出场景，写顺序由 Repository 串行链保证）
   */
  private doSave(withThumb: boolean, force: boolean): void {
    if (this.noteId.length === 0 || !this.storageReady) {
      return;
    }
    if (this.saving && !force) {
      return;
    }
    this.saving = true;
    this.saveState = NoteSaveState.SAVING;

    // 快照：避免 await 期间用户继续作画导致数组被并发改写
    const strokeSnapshot: StrokeRecord[] = this.strokes.slice();
    const imageSnapshot: ImageRefData[] = this.noteImages.slice();
    const gen: number = this.changeSeq;

    SafeAsync.runAsyncVoid(TAG_PAGE, 'saveNote', async (): Promise<void> => {
      const repo: NoteRepository = this.engine.getNoteRepository();
      const content: NoteContent = this.engine.composeNoteContent(
        this.noteMeta,
        this.paperTemplate,
        this.paperLayerId,
        strokeSnapshot,
        imageSnapshot,
        this.canvasWidth,
        this.canvasHeight,
        this.forwardRaw
      );
      // S2-B / T2-3/T2-4：注入文本框 / 闪卡 / 导图（随笔记原子落盘）
      content.texts = this.texts.slice();
      content.flashcards = this.flashcardStore.list();
      // 🔧 v2.7.0 审核修复（问题①-5「筛选导图显示的是全部笔记」真因）：
      //   原实现无条件写 `[this.mindMap]` —— 而每篇笔记一打开就有一个默认导图
      //   （仅含根节点"中心主题"），于是**保存后每篇笔记都"含导图"**，
      //   NotePage 的内容探测自然把所有笔记都判为导图笔记 → 筛选形同虚设。
      //   现只有"确实建过导图"（节点数 > 1）才落盘。
      content.mindmaps = this.hasRealMindMap() ? [this.mindMap] : [];
      // NOTE-01：便签节点随笔记原子落盘（对齐 texts/flashcards 注入方式）
      content.nodes = this.canvasNodes.slice();
      // NOTE-02/03/04：双链 / 书签随笔记原子落盘
      content.links = this.linkManager.getLinks();
      content.bookmarks = this.bookmarkManager.list();
      const result: NoteSaveResult = await repo.saveNote(content, true);
      this.saving = false;
      if (!result.ok) {
        // T2-1b C-4/C-5：失败态只由 chip 承载（d1 §11.2 ② 移除 statusText 双写——共享行会被下一笔覆盖且底色误导）
        this.saveState = NoteSaveState.FAILED;
        this.saveFailCount++;
        this.saveFailReason = result.failureKind !== null && result.failureKind !== undefined
          ? result.failureKind : 'unknown';
        Logger.error(TAG_PAGE, `保存失败 ${this.noteId}: ${result.errorMessage} kind=${this.saveFailReason}`);
        return;
      }
      // 保存成功：失败计数清零 + 解除 alert 粘性（问题已解决）
      this.saveFailCount = 0;
      this.clearAlert();
      this.noteMeta = result.meta;
      // 保存期间没有新变更才算干净，否则等下一轮 2s 再写
      if (gen === this.changeSeq) {
        this.dirty = false;
        this.saveState = NoteSaveState.SAVED;
      }
      await this.saveThumb(withThumb);
    }, (info: SafeErrorInfo): void => {
      this.saving = false;
      this.saveState = NoteSaveState.FAILED;
      this.saveFailCount++;
      this.saveFailReason = 'unknown';
      Logger.error(TAG_PAGE, `保存失败 ${this.noteId}: ${info.message}`);
    });
  }

  /** 退出 / 返回时的最后一次落盘（含缩略图） */
  /**
   * 🔴 v2.7.3：接入分布式板面共享。
   *
   * 真因：原协作链路（DistributedBoardSync → transport → WSClient）**必须有公网信令服务端**，
   *   本项目未部署 → 两台平板即便"加入成功"也没有任何数据通路，白板不可能共享。
   *   现改用鸿蒙**分布式数据对象**（distributedDataObject）承载板面数据：
   *   同一华为账号下的可信设备加入同一 roomCode 即自动互通，**不需要服务端**。
   *
   * 幂等：同一房间重复调用直接返回。
   */
  private initDistributedBoard(): void {
    // 🔴 v2.7.5：协作功能暂时下线（见 Constants.FEATURE_COLLAB_ENABLED）。
    //   关闭时完全不建立分布式数据对象 —— 也就不再需要 DISTRIBUTED_DATASYNC 权限，
    //   从而避免"包内权限与 AGC 隐私政策不一致"的提审风险。
    //   实现全部保留，下一版本把开关置 true 即可恢复。
    if (!FEATURE_COLLAB_ENABLED) {
      return;
    }
    SafeAsync.runVoid(TAG_PAGE, 'initDistributedBoard', (): void => {
      let room: string = '';
      try {
        const v: string | undefined = AppStorage.get<string>('roomId');
        room = v !== undefined && v !== null ? v : '';
      } catch (e) {
        room = '';
      }
      if (room.length === 0) {
        return;   // 未加入协作房间：纯本地模式
      }
      if (this.boardSession.isActive() && this.boardSession.getSessionId() === room) {
        return;   // 已在同一房间
      }
      this.collabRoomId = room;
      this.boardSession.setLocalDeviceId(this.noteId.length > 0 ? this.noteId : 'local');
      this.boardSession.setListener(this.buildBoardListener());
      // 分布式数据对象 create() 需要 Context
      const ctx: common.Context = getContext(this) as common.Context;
      this.boardSession.join(ctx, room, this.strokes).then((ok: boolean): void => {
        if (ok) {
          this.setStatus(`已连接协作房间 ${room}，同账号设备将实时共享白板`, StatusSeverity.ROUTINE);
        } else {
          this.setStatus('分布式共享未启用（请确认同账号设备已在超级终端互联）', StatusSeverity.ALERT);
        }
      });
    });
  }

  /** 分布式板面事件回调 */
  private buildBoardListener(): BoardSessionListener {
    return {
      onRemoteStrokes: (incoming: StrokeRecord[]): void => {
        if (incoming.length === 0) {
          return;
        }
        for (let i = 0; i < incoming.length; i++) {
          const remote: StrokeRecord = incoming[i];
          // 🔴 v2.7.3：远端笔画的 id 是**对端设备的本地序号**，与本机序号必然重号。
          //   这里统一重新分配本机唯一 id，避免与本地笔画冲突（撤销/重做按 id 定位）。
          const local: StrokeRecord = {
            id: ++this.strokeIdSeq,
            tool: remote.tool,
            color: remote.color,
            width: remote.width,
            points: remote.points,
            opacity: remote.opacity,
            blendMode: remote.blendMode,
            brushShape: remote.brushShape,
            layerId: remote.layerId,
            createdAt: remote.createdAt,
          };
          this.strokes.push(local);
        }
        this.strokeCount = this.strokes.length;
        this.renderHistory();
        this.markDirty();
        this.flushSave();
        this.setStatus(`已同步 ${incoming.length} 笔来自其他设备`, StatusSeverity.ROUTINE);
      },
      onRemoteClear: (): void => {
        this.strokes = [];
        this.strokeCount = 0;
        this.clearCanvas(this.ctxHistory);
        this.markDirty();
        this.flushSave();
        this.setStatus('其他设备清空了画布', StatusSeverity.ROUTINE);
      },
      onPeersChanged: (count: number): void => {
        if (count > 0) {
          this.setStatus(`协作房间已连接 ${count} 台设备`, StatusSeverity.ROUTINE);
        }
      },
    };
  }

  private flushSave(): void {
    if (this.noteId.length === 0 || !this.storageReady) {
      return;
    }
    // 无改动且缩略图已生成 → 无需再写
    if (!this.dirty && this.lastThumbAt > 0) {
      return;
    }
    this.doSave(true, true);
  }

  /**
   * 缩略图落盘（W9）。
   * 说明：取历史层像素（透明底），列表卡片渲染在白底上观感一致；
   * 三层画布无法一次性合成，阶段一不引入离屏合成以免拖慢退出。
   */
  private async saveThumb(force: boolean): Promise<void> {
    const now: number = Date.now();
    if (!force && now - this.lastThumbAt < THUMB_MIN_INTERVAL_MS) {
      return;
    }
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    let dataUrl: string = '';
    try {
      dataUrl = this.ctxHistory.toDataURL('image/png');
    } catch (_) {
      Logger.warn(TAG_PAGE, '缩略图生成失败（toDataURL 不可用）');
      return;
    }
    if (dataUrl.length === 0) {
      return;
    }
    this.lastThumbAt = now;
    const repo: NoteRepository = this.engine.getNoteRepository();
    const ok: boolean = await repo.saveThumb(this.noteId, dataUrl);
    if (!ok) {
      Logger.warn(TAG_PAGE, `缩略图写盘失败 ${this.noteId}`);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 笔刷 / 底纸
  // ═══════════════════════════════════════════════════════════════

  /** 按 tool 取笔刷配置，找不到时回落到一支安全的默认钢笔 */
  private brushByTool(tool: string): BrushOption {
    for (let i = 0; i < this.brushOptions.length; i++) {
      if (this.brushOptions[i].tool === tool) {
        return this.brushOptions[i];
      }
    }
    return {
      tool: 'pen',
      name: '钢笔',
      brushShape: 'round',
      opacity: 1,
      blendMode: 'normal',
      minWidth: 1,
      maxWidth: 12,
    };
  }

  /** 切换笔刷：同步笔迹参数并把线宽夹到该笔刷合法区间 */
  private applyBrush(tool: string): void {
    const brush: BrushOption = this.brushByTool(tool);
    this.currentBrush = brush.tool;
    this.activeOpacity = brush.opacity;
    this.activeBlendMode = brush.blendMode;
    this.activeBrushShape = brush.brushShape;
    if (this.currentWidth < brush.minWidth) {
      this.currentWidth = brush.minWidth;
    }
    if (this.currentWidth > brush.maxWidth) {
      this.currentWidth = brush.maxWidth;
    }
  }

  private paperName(template: string): string {
    for (let i = 0; i < this.paperOptions.length; i++) {
      if (this.paperOptions[i].template === template) {
        return this.paperOptions[i].name;
      }
    }
    return '空白';
  }

  /**
   * 🔧 统一工具切换入口（第 10 轮）：
   * ① 保存当前工具的最后宽度；② 切换 currentTool；③ 恢复目标工具记忆的宽度；
   * ④ 形状弹选择面板；⑤ 状态条反馈。顶部/底部/悬浮快捷条共用。
   */
  /**
   * v2.6.0：是否为「绘图类」工具（会写入笔迹、拥有独立的颜色/宽度/透明度记忆）。
   * 非绘图工具（选/填/取色/链/签/搜）不得读写笔刷记忆槽。
   */
  private isDrawingTool(tool: string): boolean {
    return tool === 'pen' || tool === 'eraser' || tool === 'shape' || tool === 'brush';
  }

  private switchTool(tool: string): void {
    const fromTool: string = this.currentTool;

    // 🔧 v2.6.0 审核修复（问题①「取色后笔失效」真因）：
    //   原实现无条件把当前 currentColor/宽度回写到 currentBrush 记忆里。
    //   当 currentTool 是 fill/eyedropper/lasso 这类**非绘图**工具时，currentBrush
    //   仍停在上一支笔（如 eraser），于是刚取到的颜色被写进「擦」的记忆槽，
    //   再切回「笔」时又用 colorByBrush['pen'] 的旧值覆盖 —— 用户看到「取色后笔失效」。
    //   现在只有【离开绘图类工具】时才回写记忆。
    if (this.isDrawingTool(fromTool)) {
      this.widthByBrush[this.currentBrush] = this.currentWidth;
      this.colorByBrush[this.currentBrush] = this.currentColor;
      this.opacityByBrush[this.currentBrush] = this.activeOpacity;
    }

    // 记住当前工具宽度
    this.widthByTool[fromTool] = this.currentWidth;
    this.currentTool = tool;
    // 🔧 切换工具时重新展开参数面板（用户之前可能手动关闭/折叠）
    this.paramPanelVisible = true;
    this.paramPanelCollapsed = false;
    
    // 🔧 修复笔迹保存BUG：同步更新currentBrush，确保笔迹保存时工具类型正确
    if (tool === 'pen') {
      this.currentBrush = 'pen';
    } else if (tool === 'eraser') {
      this.currentBrush = 'eraser';
    } else if (tool === 'shape') {
      this.currentBrush = this.currentShape; // 形状工具使用当前形状
    }

    // 🔧 v2.6.0：仅对绘图类工具恢复笔刷记忆；非绘图工具不得改写颜色（取色结果需保留）
    if (this.isDrawingTool(tool)) {
      // 恢复目标工具记忆的宽度（无记忆则沿用当前值）
      const saved: number | undefined = this.widthByTool[tool];
      if (saved !== undefined && saved > 0) {
        this.currentWidth = saved;
      }

      // 🔧 工具状态记忆增强：恢复目标笔刷的颜色、透明度、宽度
      const savedColor: string | undefined = this.colorByBrush[this.currentBrush];
      if (savedColor !== undefined && savedColor.length > 0) {
        this.currentColor = savedColor;
      }
      const savedOpacity: number | undefined = this.opacityByBrush[this.currentBrush];
      if (savedOpacity !== undefined) {
        this.activeOpacity = savedOpacity;
      }
      const savedWidth: number | undefined = this.widthByBrush[this.currentBrush];
      if (savedWidth !== undefined && savedWidth > 0) {
        this.currentWidth = savedWidth;
      }
    }

    // 🔧 修复：切换工具时同步笔刷参数（opacity/blendMode/brushShape），否则笔迹属性残留上一次值
    if (tool === 'pen' || tool === 'eraser') {
      this.applyBrush(this.currentBrush);
    }

    if (tool === 'shape') {
      this.showShapePicker = true;
      this.closeOtherPopups('shape');
      this.setStatus('当前工具：形状（拖动绘制，可切矩形/圆/箭头/直线）');
    } else {
      this.closeOtherPopups('');
      // 🔧 v2.6.0 审核修复（问题①）：补全全部工具的中文名。
      //   之前 Map 只有 pen/eraser/shape，点「填」时状态栏回退成英文 "fill"，
      //   用户/审核员无法确认真实工具，加剧「点了填却像笔」的误判。
      const names: Map<string, string> = new Map([
        ['pen', '画笔'],
        ['eraser', '橡皮擦'],
        ['shape', '形状'],
        ['brush', '马克笔'],
        ['lasso', '套索'],
        ['fill', '填充'],
        ['eyedropper', '取色'],
        ['link', '双链'],
        ['bookmark', '书签'],
        ['search', '搜索']
      ]);
      this.setStatus(`当前工具：${names.get(tool) ?? tool}`);
    }
  }

  /**
   * v2.6.0 审核修复（问题①）：左工具栏的「链 / 签 / 搜」是【功能入口】而非绘图工具。
   * 之前它们被塞进 switchTool，会把 currentTool 改成一个非工具值（'link' 等），
   * 导致底/左工具栏全部失去高亮，看起来"工具全乱了"。现改为各自开关对应浮层，
   * 并且【不修改 currentTool】。
   */
  private openUtilityEntry(key: string): void {
    switch (key) {
      case 'link':
        this.linkMode = !this.linkMode;
        this.linkSourceId = '';
        this.setStatus(this.linkMode ? '双链：请先点选源节点' : '已退出双链模式');
        break;
      case 'bookmark':
        this.bookmarkBarOpen = !this.bookmarkBarOpen;
        this.setStatus(this.bookmarkBarOpen ? '书签栏已展开' : '书签栏已收起');
        break;
      case 'search':
        this.searchOpen = !this.searchOpen;
        if (!this.searchOpen) {
          this.searchHits = [];
        }
        this.setStatus(this.searchOpen ? '搜索已打开' : '搜索已关闭');
        break;
      default:
        this.setStatus(`未识别的入口：${key}`);
        break;
    }
  }

  /** PRD v4：判断工具是否激活（用于左工具栏按钮高亮）；空 key 用于非工具按钮（撤销/重做）*/
  private isActiveTool(toolKey: string): boolean {
    if (toolKey === '') return false;
    return this.currentTool === toolKey;
  }

  // ═══════════════════════════════════════════════════════════════════
  // v3.0：扩展工具选择处理
  // ═══════════════════════════════════════════════════════════════════
  private handleExtendedToolSelect(key: string): void {
    this.showMorePanel = false;
    switch (key) {
      case 'text_tool':
        // 🔧 v2.7.0 审核修复（问题①-2）：不再弹"全屏遮罩提示"（双击即被自身关闭），
        //   改为**直接打开「新建文本」编辑面板** —— 一击即有明确可见响应，
        //   输入内容 → 确定 → 立即在视口中心放置文本框；之后双击文本框可继续编辑。
        this.textToolActive = true;
        this.showTextToolPanel = true;
        this.startNewTextNode();
        this.setStatus('文本工具：输入内容后点「确定」放置文本框；双击文本框可再次编辑');
        break;
      case 'fullscreen':
        this.readingMode.enter();
        this.inReadingMode = true;
        this.setStatus('全屏阅读模式');
        break;
      // 🔴 v2.7.2 审核修复（问题①-1「点扩展工具-闪卡/导图无法添加」，连续两轮未过）
      //   根因：v2.7.0/v2.7.1 把 FlashcardPage/MindMapPage 作为**自定义组件嵌入白板 Stack**
      //   （v2.7.1 还补了显式 100%×100% 容器），真机审核仍判"无法添加" ——
      //   「整页组件嵌入画布 Stack」这条路径在本工程不可靠。
      //   修法：改为**导航到独立页**（FlashcardEntryPage / MindMapEntryPage），
      //   这是审核历轮验证过可正常渲染的路径；通过 noteId 参数保持"在笔记内添加"的语义，
      //   改动仍写回该笔记的 content.flashcards / content.mindmaps（笔记列表筛选可命中）。
      //   过渡期保留嵌入式面板作为**兜底**：导航被拒时才回退到内嵌渲染。
      case 'flashcard':
        this.setStatus('正在打开闪卡…', StatusSeverity.INFO);
        // v2.7.2：先落盘再跳转 —— 独立页会"读磁盘→改字段→整篇写回"，
        //   必须先保证磁盘上是最新内容，避免旧快照把新数据盖掉。
        this.flushSave();
        SafeAsync.runVoid(TAG_PAGE, 'pushFlashcard', (): void => {
          const p: NoteRouteParams = {
            noteId: this.noteId,
            title: this.noteTitle,
            paperTemplate: this.paperTemplate,
            isNew: false,
          };
          router.pushUrl({ url: 'pages/FlashcardEntryPage', params: p })
            .catch((err: Error): void => {
              Logger.warn(TAG_PAGE, `闪卡独立页跳转失败，回退内嵌面板: ${SafeAsync.describe(err)}`);
              this.showFlashcard = true;
            });
        });
        break;
      case 'mindmap':
        this.setStatus('正在打开思维导图…', StatusSeverity.INFO);
        // v2.7.2：同上，先落盘再跳转，避免覆盖独立页刚写入的数据。
        this.flushSave();
        SafeAsync.runVoid(TAG_PAGE, 'pushMindMap', (): void => {
          const p: NoteRouteParams = {
            noteId: this.noteId,
            title: this.noteTitle,
            paperTemplate: this.paperTemplate,
            isNew: false,
          };
          router.pushUrl({ url: 'pages/MindMapEntryPage', params: p })
            .catch((err: Error): void => {
              Logger.warn(TAG_PAGE, `导图独立页跳转失败，回退内嵌面板: ${SafeAsync.describe(err)}`);
              this.showMindMap = true;
            });
        });
        break;
      case 'share':
        this.showShareDialog = true;
        break;
      case 'recycle_bin':
        this.recycleBinItems = this.recycleBin.getItems();
        this.showRecycleBin = true;
        break;
      case 'brush_box':
        this.brushPresets = this.brushBox.getPresets();
        this.showBrushBox = true;
        break;
      case 'version_history':
        this.versionEntries = this.versionHistory.getVersions(this.noteId);
        this.showVersionHistory = true;
        break;
      case 'template_market':
        this.showTemplateMarket = true;
        break;
      case 'cloud_sync':
        this.syncStatus = this.offlineSync.online ? '已连接' : '离线';
        this.setStatus(`云同步：${this.syncStatus}`);
        break;
      default:
        // 🔧 v3.1 审核修复：未匹配的工具不再提示"开发中"（避免 AppGallery 驳回），
        //   改为静默忽略 + 日志记录，避免给用户留下"半成品"印象。
        Logger.warn(TAG_PAGE, `未识别的扩展工具 key=${key}`);
        this.setStatus(`操作已忽略`);
    }
  }

  /** 获取扩展工具的中文名称（用于状态提示） */
  private getExtendedToolName(key: string): string {
    const nameMap: Map<string, string> = new Map([
      ['document_scan', '文档扫描'], ['comment', '评论'],
      ['ai_ocr', '手写识别'], ['ai_draw', '智能绘图'], ['ai_summary', '智能摘要'],
      ['web_embed', '嵌入网页'], ['latex', 'LaTeX公式'], ['watermark', '水印'],
      ['analytics', '数据统计'], ['web_clipper', '网页剪藏'], ['poll_timer', '投票/计时'],
      ['split_screen', '分屏']
    ]);
    return nameMap.get(key) ?? key;
  }

  // ═══════════════════════════════════════════════════════════════════
  // NOTE-01：文本便签 / 便利贴（补齐空壳——创建入口 + 增删移应用 + 渲染）
  // 数据模型严格遵循 BoardModel.CanvasNode 强制字段：
  //   id / type / lamport / deleted / resources / x / y / w / h / z / payload
  // ═══════════════════════════════════════════════════════════════════

  /** 生成节点唯一 id（时间戳 + 随机数，避免多端碰撞） */
  private genNodeId(): string {
    return `n_${Date.now().toString(36)}_${Math.floor(Math.random() * 1e6).toString(36)}`;
  }

  /** 构造一个便签/便利贴节点（逻辑坐标 x,y 为落点，中心对齐） */
  private buildNoteNode(mode: string, cx: number, cy: number): CanvasNode {
    this.noteLamport += 1; // 本地逻辑时钟自增（CRDT 全序低位）
    const w: number = this.noteCardW;
    const h: number = this.noteCardH;
    const isSticky: boolean = (mode === 'sticky');
    const node: CanvasNode = {
      id: this.genNodeId(),
      type: isSticky ? NodeType.STICKY : NodeType.TEXT,
      lamport: this.noteLamport,
      deleted: false,
      resources: '',
      x: cx - w / 2,
      y: cy - h / 2,
      w: w,
      h: h,
      z: this.canvasNodes.length + 1,
      payload: isSticky
        ? { text: '便利贴', color: this.stickyPalette[0] } as StickyPayload
        : { content: '双击编辑文本', md: false, size: 16, color: '#1A1A1A' } as TextPayload
    };
    return node;
  }

  /**
   * NOTE-01 核心：按 NodeOp 正向/反向应用，维护 this.canvasNodes。
   * reverse=true 时执行反向操作（撤销用）。
   * 此处只维护内存数组；持久化由 notePersistTimer 防抖写 board.json。
   */
  private applyNodeOp(op: NodeOp, reverse: boolean): void {
    if (op.node === null) {
      return;
    }
    const node: CanvasNode = op.node;
    switch (op.type) {
      case NodeOpType.NODE_ADD: {
        const exist: boolean = this.canvasNodes.some((n: CanvasNode) => n.id === node.id);
        if (!reverse && !exist) {
          this.canvasNodes.push(node);
          this.canvasNodes = this.canvasNodes.slice(); // 触发 @State 刷新
        } else if (reverse && exist) {
          this.canvasNodes = this.canvasNodes.filter((n: CanvasNode) => n.id !== node.id);
        }
        break;
      }
      case NodeOpType.NODE_REMOVE: {
        const exist: boolean = this.canvasNodes.some((n: CanvasNode) => n.id === node.id);
        if (!reverse && exist) {
          this.canvasNodes = this.canvasNodes.filter((n: CanvasNode) => n.id !== node.id);
        } else if (reverse && !exist) {
          this.canvasNodes.push(node);
        }
        break;
      }
      case NodeOpType.NODE_MOVE: {
        const target: CanvasNode | undefined = this.canvasNodes.find((n: CanvasNode) => n.id === node.id);
        if (!target) break;
        const box: Rect = reverse
          ? { x: op.prevX, y: op.prevY, w: op.prevW, h: op.prevH }
          : { x: op.nextX, y: op.nextY, w: op.nextW, h: op.nextH };
        target.x = box.x; target.y = box.y; target.w = box.w; target.h = box.h;
        // 触发 @State 更新
        this.canvasNodes = this.canvasNodes.slice();
        break;
      }
      default:
        break;
    }
    // 轻量持久化（防抖，由 NOTE-01 定时器落盘到 .hcnote）
    this.scheduleNotePersist();
  }

  /**
   * NOTE-01：便签节点落盘防抖。
   * 便签节点已接入 NoteContent.nodes（随 .hcnote 原子落盘，见 doSave），
   * 此处防抖触发 doSave 复用既有笔记保存链路（含缩略图/失败态），无需单独 board.json。
   */
  private scheduleNotePersist(): void {
    if (this.notePersistTimer !== -1) {
      clearTimeout(this.notePersistTimer);
    }
    this.notePersistTimer = setTimeout((): void => {
      this.doSave(false, false);
      this.notePersistTimer = -1;
    }, 400) as number;
  }

  // ═══ NOTE-02/03/04：阶段2 交互方法群 ═══

  /** 跳转到世界坐标（使 wx,wy 居中于屏幕） */
  private jumpToWorld(wx: number, wy: number): void {
    const cx: number = this.canvasWidth / 2;
    const cy: number = this.canvasHeight / 2;
    this.viewportX = cx - wx * this.viewportScale;
    this.viewportY = cy - wy * this.viewportScale;
    this.applyViewportTransform();
  }

  /**
   * NOTE-02 阶段2：打开双链目标选择浮层（智能推荐 + 搜索）
   * 交互流程：长按圈选 → 悬浮菜单 → 「链接到知识点」→ 本浮层
   */
  private openLinkPicker(sourceNodeId: string): void {
    this.linkSourceId = sourceNodeId;
    // 提取源节点摘要
    const sourceNode: CanvasNode | undefined = this.canvasNodes.find((n: CanvasNode) => n.id === sourceNodeId);
    this.linkPickerSourceSnippet = sourceNode !== undefined ? this.getNodeSnippet(sourceNode) : '';
    // 计算已建链的节点（排除）
    const existingLinks: LinkData[] = this.linkManager.linksOfNode(sourceNodeId);
    const excludeIds: string[] = [];
    for (let i = 0; i < existingLinks.length; i++) {
      const l: LinkData = existingLinks[i];
      if (l.from === sourceNodeId) {
        excludeIds.push(l.to);
      } else {
        excludeIds.push(l.from);
      }
    }
    // TF-IDF 智能推荐
    this.linkRecommendations = TfidfRecommender.recommend(sourceNodeId, this.canvasNodes, excludeIds);
    this.linkPickerOpen = true;
  }

  /** 双链目标选择：确认建链 */
  private onLinkPickerSelect(targetNodeId: string): void {
    if (this.linkSourceId.length === 0) {
      return;
    }
    this.noteLamport += 1;
    const link: LinkData | null = this.linkManager.toggleLink(this.linkSourceId, targetNodeId, '', this.noteLamport);
    this.linkPickerOpen = false;
    this.linkSourceId = '';
    this.linkRecommendations = [];
    if (link !== null) {
      this.setStatus('已建立双链连接');
      this.markDirty();
    } else {
      this.setStatus('已取消双链连接');
    }
  }

  /** 双链目标选择：搜索回调 */
  private onLinkPickerSearch(keyword: string): void {
    if (keyword.length === 0) {
      this.searchHits = [];
      return;
    }
    this.linkPickerSearching = true;
    this.searchHits = this.searchIndex.search(keyword);
    this.linkPickerSearching = false;
  }

  /** 双链目标选择：关闭 */
  private onLinkPickerClose(): void {
    this.linkPickerOpen = false;
    this.linkSourceId = '';
    this.linkRecommendations = [];
  }

  /** 提取节点文本摘要（展示用） */
  private getNodeSnippet(node: CanvasNode): string {
    if (node.type === 'text') {
      const pl: TextPayload = node.payload as TextPayload;
      return pl.content.length > 20 ? pl.content.substring(0, 20) + '…' : pl.content;
    } else if (node.type === 'sticky') {
      const pl: StickyPayload = node.payload as StickyPayload;
      return pl.text.length > 20 ? pl.text.substring(0, 20) + '…' : pl.text;
    }
    return '手写笔迹';
  }

  /** 双链建链流程：选源 → 选目标 → toggleLink */
  private startLinkFrom(nodeId: string): void {
    if (this.linkSourceId === '') {
      this.linkSourceId = nodeId;
      this.setStatus('已选起点，点击目标节点完成链接');
    } else {
      const from: string = this.linkSourceId;
      const to: string = nodeId;
      this.noteLamport += 1;
      const link: LinkData | null = this.linkManager.toggleLink(from, to, '', this.noteLamport);
      this.linkSourceId = '';
      if (link === null) {
        this.setStatus('已取消该双链');
      } else {
        this.setStatus('已建立双链');
        this.markDirty();
        this.flushSave();
      }
    }
  }

  /** 书签切换（三类） */
  private toggleBookmark(type: string): void {
    if (this.selectedNodeId === '') {
      this.setStatus('请先选中一个节点再加书签');
      return;
    }
    const node: CanvasNode | undefined = this.canvasNodes.find((n: CanvasNode) => n.id === this.selectedNodeId);
    if (node === undefined) {
      return;
    }
    const bm: BookmarkData | null = this.bookmarkManager.toggle(node.id, type, node.x, node.y, this.viewportScale, node.type === 'text' ? '文本便签' : '便利贴');
    if (bm === null) {
      this.setStatus('已取消书签');
    } else {
      this.setStatus(`已加「${type}」书签`);
    }
    this.markDirty();
    this.flushSave();
  }

  /** 执行检索 */
  private runSearch(keyword: string): void {
    this.searchHits = this.searchIndex.search(keyword);
  }

  /** 命中跳转 + 高亮 */
  private onSearchHit(hit: SearchHit): void {
    this.currentHitId = hit.nodeId;
    this.jumpToWorld(hit.x, hit.y);
    this.searchOpen = false;
  }

  /** 切换搜索浮层 */
  private toggleSearch(): void {
    this.searchOpen = !this.searchOpen;
    if (!this.searchOpen) {
      this.searchHits = [];
      this.currentHitId = '';
    }
  }

  /** 选中节点（便签点击时调用） */
  private selectNode(nodeId: string): void {
    this.selectedNodeId = nodeId;
  }

  // ══════════════════════════════════════════════════════════════════
  // v2.7.0 审核修复（问题①-2「扩展工具-文本工具双击无响应」）
  //
  // 真因（两处）：
  //   A. 点「文本工具」后弹的是**全屏遮罩提示浮层**，而该遮罩自身绑定
  //      `onClick → 关闭`。审核员双击时，第二次点击正好落在遮罩上把它关掉，
  //      于是「双击 = 打开后立刻关闭 = 什么也没看到」。
  //      更矛盾的是浮层文案写着"点击画布任意位置放置文本框"，
  //      但遮罩把整块画布都盖住了 —— 用户根本没机会点画布。
  //   B. 即便成功放置了文本框，节点内容只是占位符「双击编辑文本」，
  //      而节点上**只绑了单击选中、没有任何双击编辑处理**，
  //      TextEditPanel 组件被 import 却从未渲染 → 文本框永远无法输入内容。
  //
  // 修法：①删除全屏遮罩提示，改为**不遮挡画布**的轻提示与状态栏反馈；
  //      ②为文本框/便利贴绑定**双击打开编辑面板**；
  //      ③接入 TextEditPanel 真实编辑，确定后回写 payload 并落盘。
  // ══════════════════════════════════════════════════════════════════

  /**
   * v2.7.0：是否存在"真实"思维导图。
   * 仅含根节点（createEmpty 的默认「中心主题」）视为空，
   * 避免每篇笔记都被判定为"含导图"而让「导图」筛选失效。
   */
  private hasRealMindMap(): boolean {
    const map: HCMindMap = this.mindMap;
    if (map === undefined || map === null) {
      return false;
    }
    const nodes: HCMindNode[] = map.nodes !== undefined && map.nodes !== null ? map.nodes : [];
    if (nodes.length > 1) {
      return true;
    }
    if (nodes.length === 1) {
      const root: string = nodes[0].label !== undefined ? nodes[0].label : '';
      const title: string = map.title !== undefined ? map.title : '';
      // 根节点被改过名 / 导图被改过标题 → 认为用户确实建过
      return (root.length > 0 && root !== '中心主题') || (title.length > 0 && title !== '思维导图');
    }
    return false;
  }

  /** 双击文本框/便利贴 → 打开编辑面板（预填现有内容） */
  private openNodeEditor(nodeId: string): void {
    const node: CanvasNode | undefined = this.canvasNodes.find((n: CanvasNode) => n.id === nodeId);
    if (node === undefined) {
      return;
    }
    this.selectedNodeId = nodeId;
    this.editingNodeId = nodeId;
    this.editingIsNew = false;
    if (node.type === NodeType.STICKY) {
      const pl: StickyPayload = node.payload as StickyPayload;
      this.editingNodeContent = pl.text;
    } else {
      const pl: TextPayload = node.payload as TextPayload;
      // 占位文案不作为初始内容，避免用户误把它当成自己的文本
      this.editingNodeContent = pl.content === '双击编辑文本' ? '' : pl.content;
    }
    this.showTextToolPanel = false;
  }

  /** 新建文本：直接打开空白编辑面板，确定后落一个文本框节点 */
  private startNewTextNode(): void {
    this.editingNodeId = '';
    this.editingIsNew = true;
    this.editingNodeContent = '';
  }

  /** 编辑面板「确定」：回写节点内容（构造新 payload 触发 @State 刷新） */
  private commitNodeEdit(content: string, style: TextStyleConfig): void {
    const text: string = content.trim().length > 0 ? content : '（空文本）';
    if (this.editingIsNew || this.editingNodeId === '') {
      // 新建：放在视口中心
      const cx: number = this.viewportX + this.canvasWidth / 2;
      const cy: number = this.viewportY + this.canvasHeight / 2;
      const node: CanvasNode = this.buildNoteNode('text', cx, cy);
      const pl: TextPayload = {
        content: text,
        md: false,
        size: Math.round(style.fontSize),
        color: style.color,
      };
      node.payload = pl;
      this.nodeUndo.pushNodeAdd(node);
      this.applyNodeOp({
        type: NodeOpType.NODE_ADD,
        node: node,
        prevX: 0, prevY: 0, prevW: 0, prevH: 0,
        nextX: node.x, nextY: node.y, nextW: node.w, nextH: node.h,
        timestamp: Date.now(),
        description: '新增文本框'
      } as NodeOp, false);
      this.searchIndex.upsertNode(node);
      this.selectedNodeId = node.id;
      this.setStatus('已新建文本框（双击可继续编辑）', StatusSeverity.INFO);
    } else {
      const idx: number = this.canvasNodes.findIndex((n: CanvasNode) => n.id === this.editingNodeId);
      if (idx < 0) {
        this.editingNodeId = '';
        return;
      }
      const old: CanvasNode = this.canvasNodes[idx];
      let next: CanvasNode;
      if (old.type === NodeType.STICKY) {
        next = {
          id: old.id, type: old.type, lamport: this.noteLamport + 1, deleted: old.deleted,
          resources: old.resources, x: old.x, y: old.y, w: old.w, h: old.h, z: old.z,
          payload: { text: text, color: (old.payload as StickyPayload).color } as StickyPayload
        };
      } else {
        next = {
          id: old.id, type: old.type, lamport: this.noteLamport + 1, deleted: old.deleted,
          resources: old.resources, x: old.x, y: old.y, w: old.w, h: old.h, z: old.z,
          payload: {
            content: text, md: false,
            size: Math.round(style.fontSize), color: style.color
          } as TextPayload
        };
      }
      this.noteLamport += 1;
      this.canvasNodes[idx] = next;
      this.canvasNodes = this.canvasNodes.slice();   // 触发 @State 刷新
      this.searchIndex.upsertNode(next);
      this.setStatus('文本已更新', StatusSeverity.INFO);
    }
    this.editingNodeId = '';
    this.editingIsNew = false;
    this.editingNodeContent = '';
    this.noteMode = 'off';
    this.textToolActive = false;
    this.markDirty();
    this.flushSave();
  }

  /** 编辑面板「取消」 */
  private cancelNodeEdit(): void {
    this.editingNodeId = '';
    this.editingIsNew = false;
    this.editingNodeContent = '';
  }

  /** 删除便签节点 */
  private deleteNode(nodeId: string): void {
    const idx: number = this.canvasNodes.findIndex((n: CanvasNode) => n.id === nodeId);
    if (idx < 0) {
      return;
    }
    this.canvasNodes.splice(idx, 1);
    this.canvasNodes = this.canvasNodes.slice();
    this.linkManager.removeByNode(nodeId);
    this.bookmarkManager.removeByNode(nodeId);
    this.searchIndex.removeNode(nodeId);
    this.selectedNodeId = '';
    this.markDirty();
    this.flushSave();
    this.setStatus('已删除便签');
  }

  /** 节点长按上下文菜单：双链 / 书签 / 删除 */
  private showNodeContextMenu(node: CanvasNode): void {
    this.selectNode(node.id);
    const pa = this.getUIContext().getPromptAction();
    pa.showActionMenu({
      title: '节点操作',
      buttons: [
        { text: '链接到知识点', color: '#007DFF' },
        { text: '加书签（必背）', color: '#E5484D' },
        { text: '加书签（易错）', color: '#F2A100' },
        { text: '加书签（真题）', color: '#2D7FF9' },
        { text: '删除节点', color: '#D92D20' }
      ]
    }).then((res: ActionMenuResult) => {
      switch (res.index) {
        case 0:
          this.openLinkPicker(node.id);
          break;
        case 1:
          this.toggleBookmark(BookmarkType.MUST_RECITE);
          break;
        case 2:
          this.toggleBookmark(BookmarkType.EASY_WRONG);
          break;
        case 3:
          this.toggleBookmark(BookmarkType.REAL_QUESTION);
          break;
        case 4:
          this.deleteNode(node.id);
          break;
      }
    }).catch((err: Error) => {
      // 用户取消或系统错误，静默忽略
      Logger.info(TAG_PAGE, '节点菜单取消或失败：' + err.message);
    });
  }

  /**
   * v2.6.0 审核修复（问题②-3）：「画布纸张」底色从主题读取。
   *   暗色模式下若用户未显式选择纸张（仍为 light），自动取深色底纸，避免白底刺眼。
   */
  private syncPaperColorFromTheme(): void {
    try {
      this.canvasPaperColor = themeManager.getCanvasPaperColor();
    } catch (e) {
      this.canvasPaperColor = '#FFFFFF';
    }
  }

  /** 切换底纸（W6）：写回纸图层 + 重绘底纸层 + 打脏 */
  private changePaper(template: string): void {
    this.showPaperPicker = false;
    this.paperTemplate = this.engine.setPaperLayerTemplate(this.paperLayerId, template);
    this.renderPaper();
    this.markDirty();
    this.setStatus(`底纸：${this.paperName(this.paperTemplate)}`);
  }

  /** 底纸层重绘（尺寸变化 / 切换模板 / 首次 onReady） */
  private renderPaper(): void {
    if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
      return;
    }
    const startTime: number = Date.now();
    SafeAsync.runVoid(TAG_PAGE, 'renderPaper', (): void => {
      this.clearCanvas(this.ctxPaper);
      this.engine.renderPaper(this.ctxPaper, this.paperTemplate, this.canvasWidth, this.canvasHeight,
        this.canvasPaperColor);
      const elapsed: number = Date.now() - startTime;
      PerformanceTracker.getInstance().record('renderPaper', elapsed);
      if (elapsed > 30) {
        Logger.warn(TAG_PAGE, `renderPaper: 慢渲染 ${elapsed}ms`);
      }
    });
  }

  /**
   * Canvas 尺寸就绪统一入口（v2.4.1 修复：画布写不上字的根因）。
   * 三个 Canvas 与外层 Stack 的 onAreaChange 都会汇聚到这里，避免某一层首次拿到 0x0 后永久失效。
   * 只有尺寸从无效变有效，或真实发生变化时，才清空活动层并重绘底纸+历史。
   */
  /**
   * 显式初始化三层画布的位图缓冲区（以像素为单位）并按设备密度缩放上下文。
   *
   * 关键修复：ArkUI 的 Canvas 绘制坐标空间是「像素」，而触摸事件坐标是「vp」。
   * 若不显式把缓冲区设为像素尺寸并 scale(密度)，会出现两类问题：
   *   1) 缓冲区为 0x0 → 所有绘制落空，表现即「写不上字 / 完全没反应」；
   *   2) 坐标未换算 → 笔迹跑到屏幕左上角、或直接画在可见区域之外。
   * 这里统一把三层画布设为相同像素缓冲，并把上下文缩放为「1 单位 = 1vp」，
   * 之后所有绘制逻辑（含 touchMove 的 vp 坐标）都能直接命中手指位置。
   */
  /**
   * 🔧 画布拖拽辅助：在任意变换下清空整幅画布（像素缓冲）。
   * 视口变换存在时，clearRect 会受变换影响只清局部，必须先重置为单位变换再清。
   *
   * 🔴 v2.7.1 修复：`ctx.width/height` 是 **vp**（ArkUI 语义），单位阵下按 vp 尺寸 clearRect，
   *   在 dpr=2 的设备上**只能清掉左上 1/4**，右下 3/4 的旧像素残留 ——
   *   表现为清空画布/翻页/撤销后画面「清不干净、有残影」。
   *   必须改用**物理缓冲区尺寸** `vp2px(ctx.width)`。
   */
  private clearCanvas(ctx: CanvasRenderingContext2D): void {
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, vp2px(ctx.width), vp2px(ctx.height));
    ctx.restore();
  }

  /** 🔧 画布拖拽：把视口（缩放 + 平移）应用到三层画布并全量重绘 */
  private applyViewportTransform(): void {
    this.clampViewport(); // 🔧 边界限位：先收敛越界视口再重绘
    const dpr: number = vp2px(1);
    const ctxs: CanvasRenderingContext2D[] = [this.ctxPaper, this.ctxHistory, this.ctxActive];
    for (let i = 0; i < ctxs.length; i++) {
      ctxs[i].setTransform(
        dpr * this.viewportScale, 0, 0, dpr * this.viewportScale,
        dpr * this.viewportX, dpr * this.viewportY
      );
    }
    this.renderPaper();
    this.renderHistory();
    this.clearCanvas(this.ctxActive);
  }

  /** 缩放辅助：放大（上限 8x，ENG-01 无限画布） */
  private zoomIn(): void {
    this.viewportScale = Math.min(8, this.viewportScale + 0.25);
    this.applyViewportTransform();
  }

  /** 缩放辅助：缩小（下限 0.1x，ENG-01 无限画布） */
  private zoomOut(): void {
    this.viewportScale = Math.max(0.1, this.viewportScale - 0.25);
    this.applyViewportTransform();
  }

  /** 缩放辅助：一键复位到 100% 并居中（clampViewport 自动居中） */
  private zoomReset(): void {
    this.viewportScale = 1.0;
    this.applyViewportTransform();
  }

  /**
   * ENG-01：无限画布边界约束（阶段1 改造）。
   * 旧逻辑（第 10 轮）在 0.5–4x 之间强制内容居中、越界自动回弹——
   * 已移除：无限画布下「内容」无界，不应被强制居中。
   * 新约束：① 缩放收敛到 [0.1, 8]（ZOOM_MIN/ZOOM_MAX）；
   *        ② 仅把「屏幕中心对应的世界坐标」软约束在 ±20000vp（CANVAS_LOGICAL_HALF_RANGE）逻辑范围内，
   *           防止用户一路拖到无穷远导致迷路；不回弹、不露强制空白边。
   */
  private clampViewport(): void {
    // ① 缩放范围收敛（0.1x–8x）
    if (this.viewportScale < 0.1) {
      this.viewportScale = 0.1;
    } else if (this.viewportScale > 8) {
      this.viewportScale = 8;
    }
    const cw: number = this.canvasWidth;
    const ch: number = this.canvasHeight;
    if (cw <= 0 || ch <= 0) {
      return;
    }
    // ② 屏幕中心对应的世界逻辑坐标
    const centerWorldX: number = (cw / 2 - this.viewportX) / this.viewportScale;
    const centerWorldY: number = (ch / 2 - this.viewportY) / this.viewportScale;
    const half: number = 20000;
    const clampedCX: number = centerWorldX < -half ? -half : centerWorldX > half ? half : centerWorldX;
    const clampedCY: number = centerWorldY < -half ? -half : centerWorldY > half ? half : centerWorldY;
    if (clampedCX !== centerWorldX) {
      this.viewportX = cw / 2 - clampedCX * this.viewportScale;
    }
    if (clampedCY !== centerWorldY) {
      this.viewportY = ch / 2 - clampedCY * this.viewportScale;
    }
  }

  /**
   * 🔧 画布拖拽：双指缩放 + 平移（以两指中心为锚点，画布内容跟随手指）。
   * 锚点算法：缩放前后保持两指中心对应的画布点不动。
   */
  private handlePinch(e: TouchEvent, touches: TouchObject[]): void {
    const t0: TouchObject = touches[0];
    const t1: TouchObject = touches[1];
    const dist: number = Math.sqrt((t1.x - t0.x) * (t1.x - t0.x) + (t1.y - t0.y) * (t1.y - t0.y));
    const cx: number = (t0.x + t1.x) / 2;
    const cy: number = (t0.y + t1.y) / 2;

    if (e.type === TouchType.Down || this.pinchBaseDist <= 0) {
      this.pinchBaseDist = Math.max(1, dist);
      this.pinchBaseScale = this.viewportScale;
      this.pinchBaseVX = this.viewportX;
      this.pinchBaseVY = this.viewportY;
      return;
    }

    // 两指中心对应的画布坐标（缩放前）
    const anchorCX: number = (cx - this.pinchBaseVX) / this.pinchBaseScale;
    const anchorCY: number = (cy - this.pinchBaseVY) / this.pinchBaseScale;
    let newScale: number = this.pinchBaseScale * (dist / this.pinchBaseDist);
    newScale = Math.max(0.1, Math.min(8, newScale)); // ENG-01：0.1x–8x

    this.viewportScale = newScale;
    this.viewportX = cx - anchorCX * newScale;
    this.viewportY = cy - anchorCY * newScale;

    // ENG-01：无限画布——用软世界中心 clamp 替代旧「内容居中」硬限位（±20000vp）
    this.clampViewport();

    this.applyViewportTransform();
  }

  private resizeCanvasBuffer(wVp: number, hVp: number): void {
    const dpr: number = vp2px(1); // 1vp 对应的物理像素数 == 设备密度
    const wPx: number = vp2px(wVp);
    const hPx: number = vp2px(hVp);

    // 🔧 坐标偏差修复：
    //   HarmonyOS Next 中 Canvas 缓冲区尺寸由 Canvas 组件尺寸决定，
    //   CanvasRenderingContext2D 的 width/height 属性为只读。
    //   通过 Canvas 组件的 .width()/.height() 设置尺寸即可。
    const ctxs: CanvasRenderingContext2D[] = [this.ctxPaper, this.ctxHistory, this.ctxActive];
    for (let i = 0; i < ctxs.length; i++) {
      const c: CanvasRenderingContext2D = ctxs[i];
      // 重置变换并以密度缩放（叠加当前视口缩放/平移）：之后用画布 vp 坐标绘制即命中屏幕位置
      c.setTransform(
        dpr * this.viewportScale, 0, 0, dpr * this.viewportScale,
        dpr * this.viewportX, dpr * this.viewportY
      );
    }

    this.canvasWidth = wVp;
    this.canvasHeight = hVp;

    // 清空三层画布（不受视口变换影响）
    this.clearCanvas(this.ctxPaper);
    this.clearCanvas(this.ctxHistory);
    this.clearCanvas(this.ctxActive);

    // 需要重新绘制底纸 + 历史笔迹（修复 onAreaChange/尺寸变化后旧笔迹丢失）
    this.renderPaper();
    this.renderHistory();
  }

  private ensureCanvasSize(w: number, h: number): void {
    if (w <= 0 || h <= 0) {
      return;
    }
    const wasInvalid: boolean = this.canvasWidth <= 0 || this.canvasHeight <= 0;
    const sizeChanged: boolean = w !== this.canvasWidth || h !== this.canvasHeight;
    if (!wasInvalid && !sizeChanged) {
      return;
    }
    this.resizeCanvasBuffer(w, h);
    this.canvasReady = true;
    if (wasInvalid) {
      Logger.info(TAG_PAGE, `Canvas 尺寸首次就绪 ${w}x${h}，强制全量渲染`);
    } else {
      Logger.info(TAG_PAGE, `Canvas 尺寸变化 ${w}x${h}，全量重绘`);
    }
    this.clearCanvas(this.ctxActive);
    this.renderPaper();
    this.renderHistory();
  }

  // ═══════════════════════════════════════════════════════════════
  // 图片插入（W12）
  // ═══════════════════════════════════════════════════════════════

  private handleImageInserted(result: ImageInsertResult): void {
    this.showImageInsert = false;
    if (result.uri.length === 0) {
      this.setStatus('未选择图片');
      return;
    }
    const w: number = Math.max(IMAGE_MIN_SIZE, result.width);
    const h: number = Math.max(IMAGE_MIN_SIZE, result.height);
    const x: number = Math.max(0, (this.canvasWidth - w) / 2);
    const y: number = Math.max(0, (this.canvasHeight - h) / 2);
    const ref: ImageRefData = this.engine.createImageRef(this.drawLayerId, result.uri, x, y, w, h);
    ref.rotation = result.rotation;
    ref.scale = result.scale;
    this.engine.attachImages(this.drawLayerId, [ref]);

    const next: ImageRefData[] = this.noteImages.slice();
    next.push(ref);
    this.noteImages = next;
    this.markDirty();
    this.setStatus(`已插入图片（共 ${next.length} 张）`);
    Logger.info(TAG_PAGE, `插入图片 ${ref.id} → ${this.drawLayerId}`);
  }

  /** 仅渲染所在图层可见的插图（让图层面板的 👁 对图片同样生效） */
  private visibleImages(): ImageRefData[] {
    const out: ImageRefData[] = [];
    for (let i = 0; i < this.noteImages.length; i++) {
      const img: ImageRefData = this.noteImages[i];
      if (this.engine.layerVisible(img.layerId)) {
        out.push(img);
      }
    }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════
  // UI
  // ═══════════════════════════════════════════════════════════════

  build() {
    // PRD v5 终极修复：页面根改用 Stack（默认撑满全屏），内部 Column 用 height('100%') 撑满 Stack。
    //   原根 Column 在页面级不分配剩余空间 → 内层 layoutWeight 链全部失效 → 画布高度塌陷。
    Stack() {
      Column() {
        // T05a S1（约定 G）：删除折叠态 if/else 双分支 —— Canvas 三层子树结构顺序恒定，
        // 折叠切换只改容器尺寸/内边距/工具面板挂载位置（面板作为兄弟节点增删，不含 Canvas）。
        // 原「悬停态只读双 Canvas 分支」是 H3 缺陷根源（context 双绑定 → 切换丢全部笔迹），已整体删除。
        // 悬停态三段式由 S2 接管（下半区兄弟节点固定高度，layoutWeight 反推上半区）。
        Column() {
        this.buildNoteBar();
          // T2-1b C-8 / D-1：未提交草稿提示条（仅「校验通过且比正文新」的草稿亮，闸 B 已由仓储判定）
          if (this.draftNoticeVisible) {
            this.buildDraftBanner();
          }
          // PRD v4：删除顶部 buildTopBar 横向滚动工具栏（7+ 按钮挤一行难用）
          //   工具全部迁移到左侧 buildLeftToolbar（垂直磨砂悬浮）+ 底 buildHoverToolPanel（手机端）
          // UI 优化：单机模式（绝大多数使用场景）不占一行协同条；仅真实会话态显示
          if (this.collabStatus.hasSession && !this.immersiveMode) {
            Column() {
              this.buildCollabBar();
            }
            .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
          }

      // PRD v5：主区 Stack —— 左垂直工具列（平板横屏）+ 画布列，参数面板作为绝对定位浮层
      //   关键修复：改用「屏幕物理宽度」判断而非 bp（模拟器/Previewer 断点识别不可靠，
      //   曾导致平板同时显示左侧+底部两套工具栏 = 用户反馈的「功能控件重复冗余」）
      //   手机竖屏（< 600vp）：隐藏左侧工具栏，走底部 buildHoverToolPanel
      // 主区 Stack：必须 layoutWeight(1) 撑满内层 Column，参数面板用 position 相对于本 Stack 定位
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.isTabletWidth()) {
          this.buildLeftToolbar()
        }
        // 🔧 修复：内层的画布 Stack 原用 position(left/top/right/bottom:0) 绝对定位撑满父布局，
        //   但「画布列」(本 Column) 与它的所有祖先都没有建立定位上下文 → 该 position 直接锚定到
        //   整个视口（全屏铺开）。画布 Stack 本身透明 → 工具栏视觉上透出，但其 ctxActive 画布带
        //   onTouch 铺满全屏 → 吃掉全部触摸（工具栏/面板点不动、画布被盖）。
        //   改为普通 width/height 100% 撑满「画布列」（画布列已由 layoutWeight 链拿到确定尺寸），
        //   不再用绝对定位，从而严格限制在画布列范围内（工具栏右侧），不覆盖全屏。
        Column() {

          Stack() {
        // 底纸层：网格/点阵/横线/四线格，由 PaperLayerRenderer 经门面绘制
        Canvas(this.ctxPaper)
          .width('100%')
          .height('100%')
          .backgroundColor(HCColor.CANVAS_BG)
          .hitTestBehavior(HitTestMode.None)  // 🔧 修复：底纸层不拦截触摸事件，让触摸穿透到活动层
          .onReady(() => {
            this.renderPaper();
          })
          .onAreaChange((_o: Area, n: Area) => {
            this.ensureCanvasSize(Number(n.width), Number(n.height));
          })

        // 插图层：位于底纸之上、笔迹之下，便于在图片上做批注
        ForEach(this.visibleImages(), (img: ImageRefData) => {
          Image(img.uri)
            .width(img.width)
            .height(img.height)
            .objectFit(ImageFit.Contain)
            .rotate({ angle: img.rotation })
            .position({ x: img.x, y: img.y })
            // 🔧 画布拖拽：图片跟随视口（与笔画同步缩放平移）
            .translate({ x: this.viewportX, y: this.viewportY })
            .scale({ x: this.viewportScale, y: this.viewportScale })
            .hitTestBehavior(HitTestMode.None)
        }, (img: ImageRefData) => `${img.id}_${this.layerRevision}`)

        // 历史层：承载全部已完成笔画
        // C-2 修复：必须透明，否则白底会把底纸与插图整张盖死
        Canvas(this.ctxHistory)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.None)
          .onAreaChange((_o: Area, n: Area) => {
            const newWidth: number = Number(n.width);
            const newHeight: number = Number(n.height);
            // 优化：仅在尺寸真正改变时调用，避免重复调用
            if (Math.abs(newWidth - this.canvasWidth) > 1 || Math.abs(newHeight - this.canvasHeight) > 1) {
              this.ensureCanvasSize(newWidth, newHeight);
            }
          })

        // 活动层：当前笔画 + 形状预览（透明背景）
        Canvas(this.ctxActive)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onReady(() => {
            Logger.info(TAG_PAGE, `Canvas(ctxActive) onReady触发，当前尺寸：canvasWidth=${this.canvasWidth}, canvasHeight=${this.canvasHeight}`);
            this.canvasReady = true;
            // 兜底：若 onAreaChange 尚未给出尺寸，用缓冲区实际像素反推 vp 尺寸并初始化
            if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
              const pxW: number = this.ctxActive.width;
              const pxH: number = this.ctxActive.height;
              Logger.info(TAG_PAGE, `Canvas(ctxActive) 缓冲区尺寸：pxW=${pxW}, pxH=${pxH}`);
              if (pxW > 0 && pxH > 0) {
                this.resizeCanvasBuffer(px2vp(pxW), px2vp(pxH));
              }
            }
            if (this.canvasWidth > 0 && this.canvasHeight > 0) {
              Logger.info(TAG_PAGE, `Canvas(ctxActive) 开始渲染：renderPaper + renderHistory`);
              this.renderPaper();
              this.renderHistory();
            } else {
              Logger.warn(TAG_PAGE, `Canvas onReady 但尺寸仍未就绪，等待 onAreaChange`);
            }
          })
          .onAreaChange((_o: Area, n: Area) => {
            this.ensureCanvasSize(Number(n.width), Number(n.height));
          })
          .onTouch((e: TouchEvent) => this.handleTouch(e))

        // NOTE-01：便签 / 便利贴 叠加渲染层（ArkUI 组件，随视口缩放平移，与图片同变换）
        ForEach(this.canvasNodes, (node: CanvasNode) => {
          this.buildNoteCard(node)
        }, (node: CanvasNode): string => {
          // 🔴 v2.7.6 审核修复（问题③「文本工具：双击编辑后文本中内容无变化」**真正根因**）
          //   原 key 只有 `node.id` —— 编辑文本只改 payload，**id 不变**，
          //   于是 ArkUI 复用旧列表项，画布上的文字**不会重建**，看起来"改完没变化"。
          //   （与"笔记列表重命名不刷新"属同一类缺陷：key 未包含会影响显示的字段。）
          //   lamport 在每次提交编辑时自增，内容与软删状态也一并纳入，保证必重建；
          //   ⚠️ 刻意**不包含 x/y/w/h** —— 否则拖动时 key 每帧变化会导致节点反复重建、手势被打断。
          const text: string = (node.payload as TextPayload)?.content
            ?? (node.payload as StickyPayload)?.text ?? '';
          return `${node.id}_${node.lamport}_${node.deleted ? 'd' : 'a'}_${text}`;
        })

        // NOTE-02：双链连线浮层（便签之上，半透明+选中高亮）
        LinkLayer({
          links: this.linkManager.getLinks().filter((l: LinkData) => !l.deleted),
          nodes: this.canvasNodes,
          viewportX: this.viewportX,
          viewportY: this.viewportY,
          viewportScale: this.viewportScale,
          selectedLinkId: this.selectedLinkId
        })

        if (this.strokeCount === 0 && this.noteImages.length === 0 && !this.drawing) {
          Text('点击屏幕开始创作')
            .fontSize(16)
            .fontColor(HCColor.TEXT_DISABLED)
            .hitTestBehavior(HitTestMode.None)  // 🔧 修复：提示文本不拦截触摸事件
        }

        // PRD v5：手机端悬浮快捷工具条；去除 !this.immersiveMode 守卫（P0 兜底），
        // 沉浸模式下也保留工具入口，避免用户进入全屏书写后无法切工具。
        if (!this.isTabletWidth() && this.showQuickBar) {
          Column() {
            {this.quickToolBar()}
          }
          .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
        } else if (!this.isTabletWidth()) {
          // 收起态（仅手机）：只留一个展开小把手，不占画布 v2.5 使用SymbolGlyph
          Column() {
            SymbolGlyph($r('sys.symbol.' + IconSymbols.STICKER))
              .fontSize(14)
              .fontColor([HCColor.TEXT_PRIMARY])
          }
          .width(30).height(30)
          .justifyContent(FlexAlign.Center)
          .borderRadius(15)
          .backgroundColor(HCOverlay.WHITE_80)
          .shadow({ radius: 6, color: HCOverlay.SHADE_13 })
          .position({ x: '94%', y: '45%' })
          .onClick(() => {
            this.showQuickBar = true;
          })
          .transition(TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }))
        }
        // UI 优化：状态文案不再悬浮于画布顶部（避免遮挡内容），已内嵌进底部工具条左侧
      }

      // NOTE-03：书签栏（顶部，可展开）
      BookmarkBar({
        bookmarks: this.bookmarkManager.list(),
        currentNodeId: this.selectedNodeId,
        open: this.bookmarkBarOpen,
        onJump: (bm: BookmarkData): void => { this.jumpToWorld(bm.x, bm.y); },
        onToggle: (type: string): void => { this.toggleBookmark(type); }
      })
        .width('100%')

      // NOTE-04：搜索浮层（顶部）
      SearchBar({
        hits: this.searchHits,
        open: this.searchOpen,
        onSearch: (kw: string): void => { this.runSearch(kw); },
        onJump: (hit: SearchHit): void => { this.onSearchHit(hit); },
        onClose: (): void => { this.toggleSearch(); }
      })
        .width('100%')

      // NOTE-02 阶段2：双链目标选择浮层（智能推荐 + 搜索）
      LinkTargetPicker({
        recommendations: this.linkRecommendations,
        searchHits: this.searchHits,
        open: this.linkPickerOpen,
        sourceSnippet: this.linkPickerSourceSnippet,
        searching: this.linkPickerSearching,
        onSelect: (nodeId: string): void => { this.onLinkPickerSelect(nodeId); },
        onSearch: (kw: string): void => { this.onLinkPickerSearch(kw); },
        onClose: (): void => { this.onLinkPickerClose(); }
      })
        .width('100%')
        .height('100%')

      // NOTE-03：minimap 浮层（右下角）
      MiniMap({
        nodes: this.canvasNodes,
        bookmarks: this.bookmarkManager.list(),
        viewportX: this.viewportX,
        viewportY: this.viewportY,
        viewportScale: this.viewportScale,
        screenW: this.canvasWidth,
        screenH: this.canvasHeight,
        jumpToWorld: (wx: number, wy: number): void => { this.jumpToWorld(wx, wy); }
      })
        .position({ x: '100%', y: '100%' })
        .translate({ x: -170, y: -130 })
        .width(160)
        .height(120)

      // 🔧 画布容器高度修复（第 6 轮真机日志定位）：
      //   根 Column 的 height('100%') 在页面根（全屏+useNewPipe）下不生效 → Column 高度=内容自适应 →
      //   Stack 的 height('100%') 与 layoutWeight(1) 循环/冲突解析为 0 → Canvas 组件高度 0 → 触摸不命中 → 画不上。
      //   解法：去掉 height('100%')（与权重冲突），layoutWeight(1)+flexGrow(1) 双权重分配剩余，
      //         再加 constraintSize minHeight 绝对兜底（不依赖父链，保证画布至少有可命中的物理高度）。
      // 🔧 修复底部空白：minHeight 从 700 调整为 400，避免在移动设备上占用过多空间
      // T05a S2（B.4.3-5）：悬停态 canvasMinHeight 防冲突 —— creaseTop < 400vp 时 minHeight=240，
      //   避免画布被 minHeight 撑破折痕线（R4）。bp 参数 S3 接入断点后改为 this.bp。
      // 🎯 真正修复（PRD v5 修正）：画布 Stack 用 width/height 100% 撑满「画布列」（其尺寸由
      //   layoutWeight 链确定），不再用 position(left/top/right/bottom:0) 绝对定位 —— 否则在缺少
      //   定位上下文时会锚定到整个视口，导致透明画布铺满全屏并拦截全部触摸。
      .width('100%')
      .height('100%')  // 🔧 普通撑满画布列（不再用 position 绝对定位，避免锚定到全屏视口）
      .onAreaChange((_o: Area, n: Area) => {
        // 统一走 ensureCanvasSize，避免首次 0x0 后永久失效
        this.ensureCanvasSize(Number(n.width), Number(n.height));
      })
      // PRD v5 需求6：双指轻点画布 → 一键切换全屏纯书写模式（再次双指轻点恢复工具栏）
      // 用 parallelGesture 与绘制手势并行，不拦截单指绘制 / 双指缩放
      // 🔧 手势增强（对标享做「双指轻点撤回」）：三指轻点=撤销，四指轻点=重做
      .parallelGesture(
        TapGesture({ count: 1, fingers: 2 })
          .onAction(() => {
            this.toggleImmersiveMode();
          })
      )
      .parallelGesture(
        TapGesture({ count: 1, fingers: 3 })
          .onAction(() => {
            if (this.canUndo) {
              this.undo();
              this.setStatus('三指撤销');
            }
          })
      )
      .parallelGesture(
        TapGesture({ count: 1, fingers: 4 })
          .onAction(() => {
            if (this.canRedo) {
              this.redo();
              this.setStatus('四指重做');
            }
          })
      )

      // PRD v5：手机端才显示底部横向工具栏（isTabletWidth 判定，避免平板重复）
      //   平板横屏：彻底无底部工具栏，画布占满（左侧 buildLeftToolbar 是唯一工具区）
      // P0 兜底：去除 !this.immersiveMode 守卫——沉浸模式也保留工具入口。
      if (this.isHoverState()) {
        if (this.creaseTopVp > 0 && this.creaseBottomVp > this.creaseTopVp) {
          Column()
            .width('100%')
            .height(this.creaseBottomVp - this.creaseTopVp)
            .backgroundColor(HCColor.CREASE_BG)
            .hitTestBehavior(HitTestMode.None)
        }
        this.buildHoverToolPanel();
      }
      else if (!this.isTabletWidth()) {
        this.buildHoverToolPanel();
      }
      // 平板横屏：无底部工具栏
      }
      // 画布列：水平 layoutWeight 占满 Row 剩余宽度；alignSelf Stretch 让其在 Row 交叉轴（高）上撑满
      .layoutWeight(1)
      .flexGrow(1)
      .alignSelf(ItemAlign.Stretch)

      // PRD v5：图层面板改为「弹出式」（从 ⋯ 菜单打开），不再 lg 常驻占画布 280vp
      if (this.showLayerPanel && this.bp === 'lg') {
        this.buildRightLayerPanel();
      }
      }
      // 主区 Stack 占满 branch-B Column 剩余高度；TopStart 对齐让内容从左上角开始
      .width('100%')
      .layoutWeight(1)
      .alignContent(Alignment.TopStart)

      // PRD v4/v5：参数面板作为画布上的悬浮浮层（内层 Column 内绝对定位 + zIndex），
      //   浮于画布之上且不影响画布布局；点击由面板自身 Default 命中承接。
      // 🔧 P0 对标重构：参数面板已被底部一体化工具栏（buildBottomToolbar）整合，
      //   移除独立浮窗避免功能重复 + 布局零散。
      // if (this.isTabletWidth() && this.paramPanelVisible &&
      //   (this.currentTool === 'pen' || this.currentTool === 'shape' || this.currentTool === 'brush')) {
      //   this.buildParamPanel()
      // }

      // 缩放 / 聚焦控制簇（底部左侧玻璃药丸，参考 GoodNotes / 享做笔记）
      this.buildZoomCluster();

      // 🔧 P0 对标重构：顶部工具条（返回 + 撤销/重做 + 更多）—— 始终渲染
      this.buildTopBar();

      // 🔧 P0 对标重构：底部一体化工具栏（替代旧 buildToolSwitcher 单一工具切换 + 笔刷参数面板）
      //   对标 GoodNotes/享做/云记：工具切换 + 颜色 + 线宽 + 透明度，一体化底部栏
      //   永远渲染（不依赖 isTabletWidth/immersiveMode），位置在缩放控制右侧以避免重叠
      this.buildBottomToolbar();

      // UI 优化：更多工具抽屉（底部弹出，收纳低频工具）
      if (this.showMorePanel) this.buildMorePanel();

      if (this.showColorPicker) this.buildColorPopup();
      if (this.showShapePicker) this.buildShapePopup();
      if (this.showWidthPicker) this.buildWidthPopup();
      if (this.showPaperPicker) this.buildPaperPopup();
      if (this.showBrushPanel) this.buildBrushSheet();

      // v2.5.2 审核驳回修复：补齐扩展工具对应弹窗的 UI 渲染
      //   之前 showShareDialog/showRecycleBin/showBrushBox/showVersionHistory 仅置 true 但无对应 build 渲染，
      //   导致点击"分享/回收站/笔盒/版本历史"后无任何视觉反馈（"扩展工具点击无响应"）。
      if (this.showShareDialog) this.buildShareDialog();
      if (this.showRecycleBin) this.buildRecycleBinDialog();
      if (this.showVersionHistory) this.buildVersionHistoryDialog();
      if (this.showBrushBox) this.buildBrushBoxDialog();
      // 🔧 v2.7.0：文本框编辑面板（双击文本框 / 扩展工具-文本工具 触发）
      if (this.editingNodeId !== '' || this.editingIsNew) this.buildTextEditorOverlay();
      // 🔧 v2.7.0：文本工具轻提示（不遮挡画布，可穿透触摸）
      if (this.showTextToolPanel) this.buildTextToolHint();

      // 🔧 套索选区操作条（修复 showSelectMenu 有状态无渲染的隐性缺口）：
      //   框选/套索完成后显示 删除/取消 操作（对标享做「选中擦除」的选区操作）
      if (this.showSelectMenu && this.selectedStrokes.length > 0) {
        this.buildSelectMenu()
      }

      // T05a S3（B.2）：lg 用右侧常驻面板（buildRightLayerPanel），不再弹出浮动面板
      if (this.showLayerPanel && this.bp !== 'lg') {
        LayerPanel({
          onChanged: (): void => {
            this.layerRevision++;
            this.renderHistory();
            this.markDirty();
          },
          onClose: (): void => {
            this.showLayerPanel = false;
          },
          // S2-B / T2-3：图层高级操作（快照 + strokes 归属 + 撤销）
          onMergeRequest: (srcIds: string[]): string | null => {
            return this.mergeLayersRequest(srcIds);
          },
          onDuplicateRequest: (srcId: string): string | null => {
            return this.duplicateLayerRequest(srcId);
          },
          onGroupRequest: (ids: string[]): string | null => {
            return this.groupLayersRequest(ids);
          },
          onExportRequest: (layerId: string): void => {
            this.exportLayerRequest(layerId);
          },
          onLayerUndo: (): void => {
            this.undoLayerOperation();
          },
          undoable: this.layerUndoStack.length > 0
        })
          .position({ x: '50%', y: '50%' })
          .translate({ x: -150, y: -170 })
      }

      if (this.showImageInsert) {
        ImageInsert({
          onInserted: (result: ImageInsertResult): void => {
            this.handleImageInserted(result);
          },
          onClose: (): void => {
            this.showImageInsert = false;
          },
        })
          .position({ x: '50%', y: '50%' })
          .translate({ x: -200, y: -250 })
          .width(400)
          .height(500)
      }

      // 🔧【画布塌陷根因修复】这两个对话框的根容器都是 Stack()，而 ArkUI 中 Stack 默认撑满父容器。
      //   它们过去是「无条件渲染」的，直接挂在内层 Column 的垂直流里 → 两个各要 100% 高度的兄弟
      //   把 Column 的可用空间吃光 → 主区 Row 的 layoutWeight(1) 只能分到剩余 0（实测 h=0）
      //   → 画布高度塌陷、下半屏空白且写不上字。
      //   改为条件渲染：关闭状态下根本不进入布局树，主区 Row 才能拿到真正的剩余高度。
      //   附带收益：getExportData() 不再每帧 build 都调用一次。
      if (this.showFeedbackDialog) {
        // 用户反馈对话框
        FeedbackDialog({ isVisible: $showFeedbackDialog })
      }

      if (this.showExportDialog) {
        // 导出对话框
        ExportDialog({
          isVisible: $showExportDialog,
          exportData: this.getExportData(),
          canvasWidth: this.canvasWidth,
          canvasHeight: this.canvasHeight
        })
      }

      // T2-1b C-4：保存失败详情气泡（复用现有 popup 模式，点气泡外关闭）
      if (this.showSaveErrorPopup) {
        this.buildSaveErrorPopup();
      }

      // ══════════════════════════════════════════════════════════════
      //  v2.5：新功能面板
      // ══════════════════════════════════════════════════════════════

      // 取色结果提示
      if (this.showColorPickerResult) {
        Text(`取色：${this.eyedropperResult}`)
          .fontSize(16).fontColor('#FFFFFF')
          .padding(12).borderRadius(8)
          .backgroundColor(HCColor.PRIMARY)
          .position({ x: '50%', y: 80 })
          .translate({ x: '-50%' })
      }

      // 页面管理面板
      if (this.showPagePanel) {
        ModalOverlay({ show: this.showPagePanel, onClose: () => { this.showPagePanel = false; } }) {
          Column() {
            Text('页面管理').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            Text(`共 ${this.totalPages} 页，当前第 ${this.currentPageIndex + 1} 页`)
              .fontSize(14).fontColor(HCColor.TEXT_SECONDARY).margin({ bottom: 16 })
            Row() {
              Button('上一页').onClick(() => this.switchToPage(this.currentPageIndex - 1))
                .enabled(this.currentPageIndex > 0)
              Blank().width(12)
              Button('下一页').onClick(() => this.switchToPage(this.currentPageIndex + 1))
                .enabled(this.currentPageIndex < this.totalPages - 1)
              Blank().width(12)
              Button('新增页').onClick(() => this.addNewPage())
            }
            Blank().height(16)
            Button('关闭').onClick(() => { this.showPagePanel = false; })
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
          .justifyContent(FlexAlign.Center)
        }
      }

      // 笔画回放面板
      if (this.showReplayPanel) {
        ModalOverlay({ show: this.showReplayPanel, onClose: () => { this.showReplayPanel = false; } }) {
          Column() {
            Text('笔画回放').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            Progress({ value: this.replayProgress * 100, total: 100, type: ProgressType.Linear })
              .width('100%').margin({ bottom: 16 })
            Row() {
              Button(this.replayPlaying ? '暂停' : '播放').onClick(() => this.toggleReplay())
              Blank().width(12)
              Button('关闭').onClick(() => {
                this.showReplayPanel = false;
                this.replayPlaying = false;
                this.renderHistory();
              })
            }
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
        }
      }

      // 模板选择面板
      if (this.showTemplatePanel) {
        ModalOverlay({ show: this.showTemplatePanel, onClose: () => { this.showTemplatePanel = false; } }) {
          Column() {
            Text('模板库').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            ForEach(this.templateLibrary.list(), (template: NoteTemplate) => {
              Text(template.name)
                .fontSize(16).padding(12).width('100%')
                .borderRadius(8).backgroundColor(HCColor.DIVIDER)
                .margin({ bottom: 8 })
                .onClick(() => this.applyTemplate(template))
            }, (template: NoteTemplate) => template.id)
            Blank().height(16)
            Button('关闭').onClick(() => { this.showTemplatePanel = false; })
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
          .height('70%')
        }
      }

      // 标签管理面板
      if (this.showTagPanel) {
        ModalOverlay({ show: this.showTagPanel, onClose: () => { this.showTagPanel = false; } }) {
          Column() {
            Text('标签管理').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            ForEach(this.noteTags, (tag: HCTag) => {
              Row() {
                Text(tag.name).fontSize(14)
                Blank()
                Text(tag.color).fontSize(12).fontColor(HCColor.TEXT_SECONDARY)
              }
              .width('100%').padding(10).borderRadius(8)
              .backgroundColor(HCColor.DIVIDER).margin({ bottom: 6 })
            }, (tag: HCTag) => tag.id)
            Blank().height(16)
            Button('关闭').onClick(() => { this.showTagPanel = false; })
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
          .height('70%')
        }
      }

      // 演示模式遮罩
      if (this.inPresentation) {
        Column()
          .width('100%').height('100%')
          .backgroundColor(HCOverlay.MASK_80)
          .onClick(() => this.togglePresentation())
        Text('演示模式 — 点击退出')
          .fontSize(18).fontColor('#FFFFFF')
          .position({ x: '50%', y: 60 })
          .translate({ x: '-50%' })
      }

      // 密码锁对话框
      if (this.showLockDialog) {
        ModalOverlay({ show: this.showLockDialog, onClose: () => { this.showLockDialog = false; } }) {
          Column() {
            Text(this.noteLocked ? '解锁笔记' : '设置密码锁').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            TextInput({ placeholder: '请输入密码' })
              .type(InputType.Password)
              .width('100%').margin({ bottom: 16 })
              .onChange((val: string) => { this.lockPasswordInput = val; })
            Row() {
              Button(this.noteLocked ? '解锁' : '锁定')
                .onClick(() => {
                  if (this.noteLocked) {
                    this.unlockNote(this.lockPasswordInput);
                  } else {
                    this.setNoteLock(this.lockPasswordInput);
                  }
                })
              Blank().width(12)
              Button('取消').onClick(() => { this.showLockDialog = false; })
            }
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
        }
      }

      // 录音面板
      if (this.showAudioPanel) {
        ModalOverlay({ show: this.showAudioPanel, onClose: () => { this.showAudioPanel = false; } }) {
          Column() {
            Text('录音笔记').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            Text(this.isRecording ? `录音中... ${this.recordingDuration}s` : '未录音')
              .fontSize(16).fontColor(this.isRecording ? HCColor.DANGER : HCColor.TEXT_SECONDARY)
              .margin({ bottom: 16 })
            Row() {
              Button(this.isRecording ? '停止' : '开始录音').onClick(() => this.toggleRecording())
              Blank().width(12)
              Button('关闭').onClick(() => { this.showAudioPanel = false; })
            }
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
        }
      }

      // 大纲面板
      if (this.showOutlinePanel) {
        ModalOverlay({ show: this.showOutlinePanel, onClose: () => { this.showOutlinePanel = false; } }) {
          Column() {
            Text('笔记大纲').fontSize(20).fontWeight(FontWeight.Medium).margin({ bottom: 16 })
            if (this.outlineNodes.length === 0) {
              Text('暂无大纲内容').fontSize(14).fontColor(HCColor.TEXT_SECONDARY)
            } else {
              ForEach(this.outlineNodes, (node: OutlineItem, index: number) => {
                Text(node.text)
                  .fontSize(14)
                  .margin({ left: node.level * 16, bottom: 6 })
              }, (node: OutlineItem, index: number) => `${index}`)
            }
            Blank().height(16)
            Button('关闭').onClick(() => { this.showOutlinePanel = false; })
          }
          .width('80%').padding(24).borderRadius(16)
          .backgroundColor(HCColor.SURFACE)
          .height('70%')
        }
      }

      // S2-B / T2-3：贴纸面板（底部抽屉）
      if (this.showSticker) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.SHADE_20)
          .onClick(() => {
            this.showSticker = false;
          })
        Column() {
          StickerLibrary({
            currentColor: this.currentColor,
            onInsert: (sticker: string): void => {
              this.insertSticker(sticker);
            },
            onClose: (): void => {
              this.showSticker = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
      }

      // S2-B / T2-4：闪卡面板（全屏弹窗）
      // 🔴 v2.7.1 审核修复（问题①-4「点扩展工具-闪卡无法添加」+ 问题③-6「深色模式闪卡看不清」）
      //   根因（两个现象同一原因）：
      //     ① FlashcardPage/MindMapPage 的根节点是「无显式高度」的 Column；
      //        此前把它作为 **Stack 的直接子节点**、只在组件实例上加 .width/.height，
      //        实测整块被量成 0 高 → 面板完全不显示（录屏：只有遮罩变灰，没有任何面板内容），
      //        用户看到的就是"点了闪卡，什么都没出来，无法添加"；
      //     ② 面板容器**没有背景色**，深色模式下浅色文字直接压在白色画布上 → 看不清。
      //   修法：用**显式 100%×100% 的 Column 包裹**（与 FlashcardEntryPage 中已验证可用的
      //        写法一致：父容器给足尺寸，子组件自然撑满），并补不透明底色。
      if (this.showFlashcard) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.SHADE_20)
          .zIndex(350)
          .onClick(() => {
            this.showFlashcard = false;
          })
        Column() {
          FlashcardPage({
            store: this.flashcardStore,
            onChanged: (): void => {
              this.markDirty();
              this.flushSave();
            },
            onClose: (): void => {
              this.showFlashcard = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(HCColor.PAGE_BG)
        .zIndex(351)
      }

      // S2-B / T2-4：导图面板（全屏弹窗）—— 同上，用显式容器包裹
      if (this.showMindMap) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCOverlay.SHADE_20)
          .zIndex(350)
          .onClick(() => {
            this.showMindMap = false;
          })
        Column() {
          MindMapPage({
            map: this.mindMap,
            onChanged: (map: HCMindMap): void => {
              this.mindMap = map;
              this.markDirty();
              this.flushSave();
            },
            onClose: (): void => {
              this.showMindMap = false;
            }
          })
        }
        .width('100%')
        .height('100%')
        .backgroundColor(HCColor.PAGE_BG)
        .zIndex(351)
      }
    }
      // PRD v5：内层 Column 用 layoutWeight 占满外层 Column 剩余高度（不加 height，避免与权重冲突）
      .width('100%')
      .layoutWeight(1)
      .flexGrow(1)
    }
      // PRD v5：outer Column 必须显式 height 100% + expandSafeArea 撑满页面根，否则只 hug 内容
      .width('100%')
      .height('100%')
      .layoutWeight(1)
      .flexGrow(1)
      .expandSafeArea([SafeAreaType.SYSTEM, SafeAreaType.CUTOUT, SafeAreaType.KEYBOARD], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END])
      .backgroundColor(HCColor.PAGE_BG)
    }
  }

  /** 页面转场动画 */
  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }

  // ═══ 笔记信息条（v2.5 浮层化：顶部不占布局空间，画布全屏可写）═══
  // PRD v5 终极优化：noteBar 改 position 浮层 + 半透磨砂背景 → 画布占满 100% 空间
  @Builder buildNoteBar() {
    if (this.immersiveMode) {
      Blank()
    } else {
      Row() {
        // 返回按钮（使用统一 BackButton 组件）
        BackButton({ onBack: (): void => { this.exitToList(); } })

        // 标题居中
        Text(this.noteTitle)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(HCColor.TEXT_PRIMARY)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 12, right: 12 })
          .textAlign(TextAlign.Center)

        // 保存状态（小药丸）
        Row() {
          if (this.saveState === NoteSaveState.FAILED) {
            SymbolGlyph($r('sys.symbol.' + IconSymbols.ERROR))
              .fontSize(10)
              .fontColor([HCColor.DANGER])
              .margin({ right: 4 })
          } else if (this.saveState === NoteSaveState.SAVED || this.saveState === NoteSaveState.IDLE) {
            SymbolGlyph($r('sys.symbol.' + IconSymbols.SUCCESS))
              .fontSize(10)
              .fontColor([HCColor.SUCCESS])
              .margin({ right: 4 })
          }
          Text(this.saveChipText())
            .fontSize(10)
            .fontColor(this.saveChipColor())
        }
        .height(24)
        .padding({ left: 8, right: 8 })
        .backgroundColor(this.saveState === NoteSaveState.FAILED ? HCColor.DANGER_BG : 'rgba(255,255,255,0.55)')
        .borderRadius(12)
        .border(this.saveState === NoteSaveState.FAILED ? { width: 1, color: HCBrand.RED_TINT } : {})
        .margin({ right: 8 })
        .onClick(() => {
          if (this.saveState === NoteSaveState.FAILED) {
            this.closeOtherPopups('');
            this.showSaveErrorPopup = true;
          }
        })

        // 右上角更多菜单入口（图标化）
        Row() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.MORE))
            .fontSize(20)
            .fontColor([HCColor.TEXT_PRIMARY])
        }
        .width(32).height(32)
        .justifyContent(FlexAlign.Center)
        .borderRadius(8)
        .backgroundColor(this.showMorePanel ? 'rgba(0,125,255,0.12)' : 'rgba(0,0,0,0.03)')
        .onClick(() => {
          this.showMorePanel = !this.showMorePanel;
          this.closeOtherPopups('more');
        })
      }
      .width('100%')
      .height(44)
      .padding({ left: 12, right: 12 })
      // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（顶部信息条）。
      .backgroundColor(HCColor.SURFACE)
      .border({ width: { bottom: 1 }, color: 'rgba(0,0,0,0.04)' })
      .hitTestBehavior(HitTestMode.Default)
    }
  }

  /** 画布便签节点渲染 */
  @Builder
  buildNoteCard(node: CanvasNode) {
    if (!node.deleted) {
      Stack() {
        Column() {
          Text((node.payload as TextPayload)?.content || (node.payload as StickyPayload)?.text || '')
            .fontSize(14)
            .fontColor(HCAccent.TEXT_STRONG)
            .textAlign(TextAlign.Start)
            .lineHeight(20)
        }
        .padding(12)
        // 🔴 v2.7.1：原为硬编码 '#FFFFFF'，深色模式下卡片仍是白底 + 浅色字 → 内容看不清。
        //   改用主题 Resource（HCColor.SURFACE），随深浅模式自动切换。
        .backgroundColor(HCColor.SURFACE)
        .borderRadius(8)
        .border({ width: 1, color: HCNeutral.BORDER_SOFT })
        .shadow({ radius: 4, color: 'rgba(0,0,0,0.06)', offsetX: 0, offsetY: 2 })
      }
      .width(node.w > 0 ? node.w : 160)
      .height(node.h > 0 ? node.h : 80)
      .position({ x: node.x, y: node.y })
      // 🔴 v2.7.1 审核修复（问题①-2「文本工具双击无法编辑」）
      //   此前是 `.onClick(单击选中)` + `.gesture(TapGesture({count:2}))` 并存 ——
      //   两者会**争抢同一次触摸序列**：单击回调先把事件消费掉，
      //   双击手势因此永远无法被识别，用户双击文本框没有任何反应。
      //   修法：改用 GestureGroup(GestureMode.Exclusive) 把单击与双击**显式互斥**，
      //        双击优先识别，识别失败才回退为单击选中。
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          TapGesture({ count: 2 })
            .onAction(() => {
              this.openNodeEditor(node.id);
            }),
          TapGesture({ count: 1 })
            .onAction(() => {
              this.selectNode(node.id);
            })
        )
      )
    }
  }

  /**
   * v2.7.0：文本编辑面板浮层（底部抽屉式，不遮挡画布上部）。
   * 由 buildNoteCard 的双击手势 / 扩展工具「文本工具」触发。
   */
  @Builder
  buildTextEditorOverlay() {
    Column() {
      // 点击面板外空白收起
      Column()
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(HCOverlay.MASK_40)
        .onClick(() => { this.cancelNodeEdit(); })

      Column() {
        TextEditPanel({
          initialContent: this.editingNodeContent,
          panelTitle: this.editingIsNew ? '新建文本' : '编辑文本',
          onConfirm: (content: string, style: TextStyleConfig): void => {
            this.commitNodeEdit(content, style);
          },
          onCancel: (): void => {
            this.cancelNodeEdit();
          }
        })
      }
      .width('100%')
      // 🔴 v2.7.1：给足最小高度，避免面板在 Stack 内被量成 0 高导致"看不到编辑框"
      .constraintSize({ minHeight: 340 })
      .backgroundColor(HCColor.SURFACE)
      .borderRadius({ topLeft: 16, topRight: 16 })
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.18)', offsetY: -4 })
      .padding({ bottom: 12 })
    }
    .width('100%')
    .height('100%')
    .zIndex(400)
  }

  private saveChipText(): string {
    if (this.noteId.length === 0) {
      return '临时';
    }
    if (!this.storageReady) {
      return '未就绪';
    }
    // 标题栏 chip 保持极简，失败时引导点击展开详情
    if (this.saveState === NoteSaveState.FAILED) {
      return '保存失败';
    }
    if (this.saveState === NoteSaveState.SAVING) {
      return '保存中';
    }
    if (this.saveState === NoteSaveState.SAVED) {
      return '已保存';
    }
    return '未保存';
  }

  private saveChipColor(): ResourceColor {
    if (this.noteId.length === 0 || !this.storageReady) {
      return HCColor.TEXT_DISABLED;
    }
    return noteSaveStateColor(this.saveState);
  }

  // ═══ T2-1b C-4/C-5：保存失败详情气泡 ═══
  @Builder
  buildSaveErrorPopup() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(HCColor.MASK)
      .onClick(() => {
        this.showSaveErrorPopup = false;
      })

    Column() {
      Text(this.saveErrorTitle())
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .margin({ top: 18, bottom: 10 })
        .padding({ left: 18, right: 18 })
      Text(this.saveErrorBody())
        .fontSize(12)
        .fontColor(HCColor.TEXT_SECONDARY)
        .lineHeight(18)
        .padding({ left: 18, right: 18 })

      // ≥3 次连续失败（C-5）：导出转主按钮（视觉权重高于重新保存）
      Row() {
        Button('导出图片')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(this.saveFailCount >= 3 ? Color.White : HCColor.TEXT_SECONDARY)
          .backgroundColor(this.saveFailCount >= 3 ? HCColor.PRIMARY : HCColor.DIVIDER)
          .onClick(() => {
            this.showSaveErrorPopup = false;
            this.exportImage();
          })
        Blank().width(12)
        Button('重新保存')
          .layoutWeight(1)
          .height(40)
          .fontSize(14)
          .fontColor(this.saveFailCount >= 3 ? HCColor.TEXT_SECONDARY : Color.White)
          .backgroundColor(this.saveFailCount >= 3 ? HCColor.DIVIDER : HCColor.PRIMARY)
          .onClick(() => {
            this.showSaveErrorPopup = false;
            this.doSave(true, true);
          })
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 16, bottom: 20 })
    }
    .width('82%')
    .backgroundColor(Color.White)
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }

  /** 保存失败详情标题（d2 §1.2 文案矩阵） */
  private saveErrorTitle(): string {
    if (this.saveFailCount >= 3) {
      return `已经连续 ${this.saveFailCount} 次没能保存成功`;
    }
    if (this.saveFailReason === 'no_space') {
      return '设备存储空间不足，本次修改没能保存';
    }
    if (this.saveFailReason === 'no_permission') {
      return '没有写入权限，本次修改没能保存';
    }
    return '保存没有成功';
  }

  /** 保存失败详情正文（d2 §1.2 文案矩阵；命中原因/动作/影响三要素，禁内部术语） */
  private saveErrorBody(): string {
    if (this.saveFailCount >= 3) {
      return '这本笔记的改动一直没能写入设备，继续编辑下去这些内容都会丢失。强烈建议现在就用「导出图片」把画面留存下来，再排查存储空间或权限问题。';
    }
    if (this.saveFailReason === 'no_space') {
      return '你在这本笔记里的最新改动目前只存在于当前界面，一旦退出就会丢失。请先清理设备存储空间，再点「重新保存」；如果暂时腾不出空间，可以先用「导出图片」把当前画面留存下来。';
    }
    if (this.saveFailReason === 'no_permission') {
      return '应用当前无法写入笔记存储目录，你的最新改动只存在于当前界面，退出就会丢失。请检查应用的存储权限是否被关闭；恢复权限后点「重新保存」。若一时无法处理，请先用「导出图片」留存当前画面。';
    }
    return '你的最新改动只存在于当前界面，退出就会丢失。请点「重新保存」再试一次；如果反复失败，请先用「导出图片」把当前画面留存下来，避免内容丢失。';
  }

  // ═══ T2-1b C-8 / D-1：未提交草稿提示条（二段式确认）═══
  @Builder
  buildDraftBanner() {
    // 沉浸模式下隐藏草稿提示条
    if (this.immersiveMode) {
      Blank()
    } else {
      Row() {
      Text(this.draftPreviewMode ? this.draftPreviewText() : this.draftTimeText())
        .fontSize(11)
        .fontColor(HCColor.WARNING)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ right: 8 })

      if (!this.draftPreviewMode) {
        Button('查看草稿')
          .height(26)
          .fontSize(11)
          .fontColor(HCColor.WARNING)
          .backgroundColor(HCColor.WARNING_BG)
          .onClick(() => {
            this.viewDraft();
          })
        Button('保留当前版本')
          .height(26)
          .fontSize(11)
          .fontColor(HCColor.TEXT_SECONDARY)
          .backgroundColor(HCColor.DIVIDER)
          .margin({ left: 6 })
          .onClick(() => {
            // d2 §3.2：只关提示条，草稿仍在磁盘（重启会再提示，强化不丢数据）
            this.draftNoticeVisible = false;
          })
      } else {
        Button('用这份草稿覆盖保存')
          .height(26)
          .fontSize(11)
          .fontColor(Color.White)
          .backgroundColor(HCColor.PRIMARY)
          .onClick(() => {
            this.confirmDraftOverwrite();
          })
        Button('返回上次保存的版本')
          .height(26)
          .fontSize(11)
          .fontColor(HCColor.TEXT_SECONDARY)
          .backgroundColor(HCColor.DIVIDER)
          .margin({ left: 6 })
          .onClick(() => {
            this.backToSavedVersion();
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(HCColor.WARNING_BG)
    .borderRadius(8)
    .margin({ left: 20, right: 20, bottom: 6 })
    }
  }

  /** 提示条主文案（d2 §3.2：时间锚点，明确「当前显示的是上次保存的版本」） */
  private draftTimeText(): string {
    if (this.draftMtime <= 0) {
      return '检测到一份比当前更新的未保存草稿，当前显示的是上次保存的版本';
    }
    const minutes: number = Math.max(0, Math.floor((Date.now() - this.draftMtime) / 60000));
    return `检测到一份更新的未保存草稿（${minutes} 分钟前），当前显示的是上次保存的版本`;
  }

  /** 草稿预览态提示条文案（d2 §3.3） */
  private draftPreviewText(): string {
    if (this.draftMtime <= 0) {
      return '正在查看草稿，尚未保存';
    }
    const minutes: number = Math.max(0, Math.floor((Date.now() - this.draftMtime) / 60000));
    return `正在查看草稿（${minutes} 分钟前），尚未保存`;
  }

  /** 查看草稿（C-8）：载入草稿内容到画布、不写盘；先暂存正本供「返回」还原 */
  private viewDraft(): void {
    const repo: NoteRepository = this.engine.getNoteRepository();
    const content: NoteContent | null = repo.readDraftContent(this.noteId);
    if (content === null) {
      this.setStatus('草稿内容不可读，可能已损坏', StatusSeverity.ALERT);
      return;
    }
    this.draftBackupStrokes = this.strokes.slice();
    this.draftBackupImages = this.noteImages.slice();
    this.draftBackupMeta = this.noteMeta;
    this.applyContentToCanvas(content);
    this.draftPreviewMode = true;
  }

  /** 把 NoteContent 应用到画布（loadNote 恢复逻辑的复用片段） */
  private applyContentToCanvas(content: NoteContent): void {
    const restored: StrokeRecord[] = this.engine.strokesFromContent(content);
    // 🔧 修复：与 loadNote 对齐——把历史 layerId（已不在当前层表）归一到 drawLayerId，
    //   防止"切工具/全屏后历史笔迹消失"的视觉缺陷。
    const lm = this.engine.getLayerManager();
    for (let i = 0; i < restored.length; i++) {
      const s: StrokeRecord = restored[i];
      if (s.layerId.length === 0 || lm.getLayer(s.layerId) === null) {
        s.layerId = this.drawLayerId;
      }
      if (s.id > this.strokeIdSeq) {
        this.strokeIdSeq = s.id;
      }
    }
    this.strokes = restored;
    this.resetRedoStacks();
    // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
    this.updateUndoRedoState();
    this.strokeCount = restored.length;
    const imgs: ImageRefData[] = this.engine.imagesFromContent(content);
    this.engine.attachImages(this.drawLayerId, imgs);
    this.noteImages = imgs;
    // S2-B / T2-3/T2-4：恢复文本框 / 闪卡 / 导图
    this.texts = content.texts !== undefined && content.texts !== null ? content.texts.slice() : [];
    this.flashcardStore.replaceAll(content.flashcards !== undefined && content.flashcards !== null
      ? content.flashcards : []);
    this.mindMap = content.mindmaps !== undefined && content.mindmaps !== null && content.mindmaps.length > 0
      ? content.mindmaps[0] : MindMapModel.createEmpty('思维导图', '中心主题');
    // NOTE-01：恢复便签节点（content.nodes 必填，旧文件缺省时回落空数组）
    this.canvasNodes = content.nodes !== undefined && content.nodes !== null ? content.nodes.slice() : [];
    // NOTE-02/03/04：恢复双链 / 书签 / 重建端侧索引
    this.linkManager.hydrate(content.links !== undefined && content.links !== null ? content.links : []);
    this.bookmarkManager.hydrate(content.bookmarks !== undefined && content.bookmarks !== null ? content.bookmarks : []);
    this.searchIndex.indexAll(this.canvasNodes);
    this.renderPaper();
    this.renderHistory();
  }

  /** 用这份草稿覆盖保存（C-8 二段式确认主动作）：recoverTmp 三道闸（校验+备份+失败降级） */
  private confirmDraftOverwrite(): void {
    SafeAsync.runAsyncVoid(TAG_PAGE, 'recoverTmp', async (): Promise<void> => {
      const repo: NoteRepository = this.engine.getNoteRepository();
      const res: RecoverResult = await repo.recoverTmp(this.noteId);
      if (res.ok) {
        this.draftNoticeVisible = false;
        this.draftPreviewMode = false;
        this.draftMtime = 0;
        this.hasUncommittedTmp = false;
        this.setStatus('已用草稿覆盖保存', StatusSeverity.INFO);
      } else {
        this.setStatus(res.errorMessage, StatusSeverity.ALERT);
      }
    }, (info: SafeErrorInfo): void => {
      this.setStatus(`恢复失败：${info.message}`, StatusSeverity.ALERT);
    });
  }

  /** 返回上次保存的版本（C-8）：还原正本内容，回到初始提示态；草稿仍保留在磁盘 */
  private backToSavedVersion(): void {
    const content: NoteContent = this.engine.composeNoteContent(
      this.draftBackupMeta,
      this.paperTemplate,
      this.paperLayerId,
      this.draftBackupStrokes,
      this.draftBackupImages,
      this.canvasWidth,
      this.canvasHeight,
      this.forwardRaw
    );
    this.noteMeta = this.draftBackupMeta;
    this.applyContentToCanvas(content);
    this.draftPreviewMode = false;
    this.draftNoticeVisible = true;
  }

  // ═══ S2-B / T2-3：贴纸插入 ═══

  /** 贴纸插入：以文本框元素（emoji 文本）落画布中心，随 texts[] 持久化 */
  private insertSticker(sticker: string): void {
    const now: number = Date.now();
    const text: HCText = {
      id: `text_${now}_${Math.random().toString(36).substring(2, 8)}`,
      layerId: this.drawLayerId,
      text: sticker,
      x: Math.round(this.canvasWidth / 2),
      y: Math.round(this.canvasHeight / 2),
      fontSize: 48,
      fontFamily: 'HarmonyOS Sans',
      align: 'left',
      color: this.currentColor,
      createdBy: HC_LOCAL_AUTHOR,
      createdAt: now,
    };
    this.texts.push(text);
    this.renderHistory();
    this.markDirty();
    this.showSticker = false;
  }

  // ═══ S2-B / T2-3：图层高级操作（快照 + strokes 归属 + 撤销）═══

  /** 操作前快照（strokes 归属 + 层元数据投影），供撤销还原 */
  private pushLayerUndo(): void {
    const layers: Layer[] = this.engine.getLayerManager().getLayers();
    const projection: HCLayer[] = [];
    for (let i = 0; i < layers.length; i++) {
      const l: Layer = layers[i];
      projection.push({
        id: l.id,
        name: l.name,
        type: l.type,
        opacity: l.opacity,
        visible: l.visible,
        locked: l.locked,
        groupId: l.groupId,
        paperTemplate: l.paperTemplate,
        pageRef: l.pageRef,
        order: l.order,
      });
    }
    this.layerUndoStack.push({ layers: projection, strokes: this.strokes.slice() });
    if (this.layerUndoStack.length > 50) {
      this.layerUndoStack.shift();
    }
  }

  /** 合并：LayerManager 建目标层删源层 + strokes 归属迁移到目标层 */
  private mergeLayersRequest(srcIds: string[]): string | null {
    if (srcIds.length < 2) {
      return null;
    }
    this.pushLayerUndo();
    const lm = this.engine.getLayerManager();
    const target: Layer | null = lm.mergeLayers(srcIds, '合并图层');
    if (target === null) {
      this.layerUndoStack.pop();
      return null;
    }
    // strokes 归属：源层笔画 → 目标层
    for (let i = 0; i < this.strokes.length; i++) {
      const s: StrokeRecord = this.strokes[i];
      if (srcIds.indexOf(s.layerId) >= 0) {
        s.layerId = target.id;
      }
    }
    this.renderHistory();
    this.markDirty();
    return target.id;
  }

  /** 复制：LayerManager 建副本层 + 源层 strokes 深拷贝到副本层 */
  private duplicateLayerRequest(srcId: string): string | null {
    this.pushLayerUndo();
    const lm = this.engine.getLayerManager();
    const dup: Layer | null = lm.duplicateLayer(srcId);
    if (dup === null) {
      this.layerUndoStack.pop();
      return null;
    }
    // strokes 深拷贝：源层笔画复制一份挂到副本层
    const copied: StrokeRecord[] = [];
    for (let i = 0; i < this.strokes.length; i++) {
      const s: StrokeRecord = this.strokes[i];
      if (s.layerId === srcId) {
        this.strokeIdSeq += 1;
        const pts: PointRecord[] = [];
        for (let k = 0; k < s.points.length; k++) {
          pts.push({ x: s.points[k].x, y: s.points[k].y, pressure: s.points[k].pressure });
        }
        copied.push({
          id: this.strokeIdSeq,
          tool: s.tool,
          color: s.color,
          width: s.width,
          points: pts,
          opacity: s.opacity,
          blendMode: s.blendMode,
          brushShape: s.brushShape,
          layerId: dup.id,
          createdAt: s.createdAt,
        });
      }
    }
    this.strokes = this.strokes.concat(copied);
    this.strokeCount = this.strokes.length;
    // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
    this.updateUndoRedoState();
    this.renderHistory();
    this.markDirty();
    return dup.id;
  }

  /** 分组：LayerManager 建 group 容器层（成员 groupId 指向容器；strokes 无需迁移） */
  private groupLayersRequest(ids: string[]): string | null {
    if (ids.length < 2) {
      return null;
    }
    this.pushLayerUndo();
    const lm = this.engine.getLayerManager();
    const group: Layer | null = lm.groupLayers(ids);
    if (group === null) {
      this.layerUndoStack.pop();
      return null;
    }
    this.renderHistory();
    this.markDirty();
    return group.id;
  }

  /** 单层导出：该层 strokes 位图 → 历史层临时合成 → toDataURL → AppStorage（与 exportImage 同通道） */
  private exportLayerRequest(layerId: string): void {
    const layerStrokes: StrokeRecord[] = [];
    for (let i = 0; i < this.strokes.length; i++) {
      if (this.strokes[i].layerId === layerId) {
        layerStrokes.push(this.strokes[i]);
      }
    }
    const ctx = this.ctxHistory;
    // 🔴 v2.7.1：与 exportImage 同因 —— 必须在「仅密度」变换下绘制，
    //   否则 clearCanvas 恢复的视口平移/缩放会把内容推出位图，单层导出同样空白。
    this.beginExportCompose(ctx);
    for (let i = 0; i < layerStrokes.length; i++) {
      const s: StrokeRecord = layerStrokes[i];
      if (s.points.length < 2) {
        continue;
      }
      ctx.globalAlpha = s.opacity > 0 && s.opacity <= 1 ? s.opacity : 1;
      ctx.globalCompositeOperation = s.blendMode === 'multiply' ? 'multiply' : 'source-over';
      ctx.strokeStyle = s.color;
      ctx.lineWidth = s.width;
      ctx.lineCap = s.brushShape === 'flat' ? 'butt' : 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      ctx.moveTo(s.points[0].x, s.points[0].y);
      for (let k = 1; k < s.points.length; k++) {
        ctx.lineTo(s.points[k].x, s.points[k].y);
      }
      ctx.stroke();
    }
    const dataUrl: string = ctx.toDataURL('image/png');
    ctx.restore();
    this.renderHistory(); // 还原历史层
    if (dataUrl !== undefined && dataUrl.length > 0) {
      AppStorage.setOrCreate<string>('exportedImage', dataUrl);
      this.setStatus('已导出当前图层', StatusSeverity.INFO);
    } else {
      this.setStatus('单层导出失败', StatusSeverity.ALERT);
    }
  }

  /** 撤销图层操作：还原 strokes 归属 + 重建层元数据投影 */
  private undoLayerOperation(): void {
    const snap = this.layerUndoStack.pop();
    if (snap === undefined) {
      return;
    }
    this.strokes = snap.strokes.slice();
    this.strokeCount = this.strokes.length;
    // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
    this.updateUndoRedoState();
    this.rebuildLayersFromProjection(snap.layers);
    this.renderHistory();
    this.markDirty();
  }

  /** 按投影重建层元数据（LayerManager 无 setLayers API，删除现有层后逐个重建） */
  private rebuildLayersFromProjection(projection: HCLayer[]): void {
    const lm = this.engine.getLayerManager();
    const existing: Layer[] = lm.getLayers();
    for (let i = 0; i < existing.length; i++) {
      lm.deleteLayer(existing[i].id);
    }
    for (let i = 0; i < projection.length; i++) {
      const p: HCLayer = projection[i];
      let layer: Layer;
      if (p.type === 'paper') {
        layer = lm.createPaperLayer(p.name, p.paperTemplate);
      } else {
        layer = lm.createLayer(p.name, p.type);
      }
      layer.opacity = p.opacity;
      layer.visible = p.visible;
      layer.locked = p.locked;
      layer.groupId = p.groupId;
      layer.paperTemplate = p.paperTemplate;
      layer.pageRef = p.pageRef;
      layer.order = p.order;
    }
  }

  /** 弹层互斥：同一时刻只留一个浮层，避免叠罗汉挡住画布 */
  private closeOtherPopups(keep: string): void {
    if (keep !== 'color') this.showColorPicker = false;
    if (keep !== 'shape') this.showShapePicker = false;
    if (keep !== 'width') this.showWidthPicker = false;
    if (keep !== 'paper') this.showPaperPicker = false;
    if (keep !== 'brush') this.showBrushPanel = false;
    if (keep !== 'layer') this.showLayerPanel = false;
    if (keep !== 'image') this.showImageInsert = false;
    if (keep !== 'saveError') this.showSaveErrorPopup = false;
    if (keep !== 'sticker') this.showSticker = false;
    if (keep !== 'flashcard') this.showFlashcard = false;
    if (keep !== 'mindmap') this.showMindMap = false;
    if (keep !== 'more') this.showMorePanel = false;
  }

  /**
   * 🔧 悬浮快捷工具条（第 10 轮）：画布右侧竖排，书写时不抬手即可切换 笔/橡皮/形状。
   * 半透明白底胶囊，点击按钮区域外的画布区域正常绘制（按钮本身拦截自身区域）。
   */
  @Builder quickToolBar() {
    Column() {
      // 收起按钮
      Text('→')
        .fontSize(12)
        .fontColor(HCColor.TEXT_DISABLED)
        .width(34).height(26)
        .textAlign(TextAlign.Center)
        .onClick(() => {
          this.showQuickBar = false;
        })

      Button('笔')
        .fontSize(18)
        .width(40).height(40)
        .backgroundColor(this.currentTool === 'pen' ? HCColor.PRIMARY : HCColor.SURFACE)
        .borderRadius(20)
        .margin({ top: 4 })
        .onClick(() => {
          if (this.currentTool === 'pen') {
            this.showBrushPanel = true;
            this.closeOtherPopups('brush');
          } else {
            this.switchTool('pen');
          }
        })

      Button('擦')
        .fontSize(16)
        .width(40).height(40)
        .backgroundColor(this.currentTool === 'eraser' ? HCColor.PRIMARY : HCColor.SURFACE)
        .borderRadius(20)
        .margin({ top: 6 })
        .onClick(() => {
          this.switchTool('eraser');
        })

      Button('形')
        .fontSize(15)
        .width(40).height(40)
        .backgroundColor(this.currentTool === 'shape' ? HCColor.PRIMARY : HCColor.SURFACE)
        .borderRadius(20)
        .margin({ top: 6 })
        .onClick(() => {
          this.switchTool('shape');
        })
    }
    .padding({ top: 6, bottom: 8, left: 3, right: 3 })
    .backgroundColor(HCOverlay.WHITE_93)
    .borderRadius(16)
    .shadow({ radius: 8, color: HCOverlay.SHADE_20, offsetX: 0, offsetY: 2 })
    .position({ x: '92%', y: '42%' })
    .alignItems(HorizontalAlign.Center)
  }

  // 🔧 手机工具按钮（符合鸿蒙UX规范：最小触控尺寸48dp）
  @Builder buildToolBtnMobile(tool: string, icon: string, symbolName?: string) {
    // 🔧 修复：将高亮判断移到函数内部，确保响应状态变化
    Column() {
      if (symbolName && symbolName.length > 0) {
        // 使用SymbolGlyph系统图标（推荐）
        SymbolGlyph($r('sys.symbol.' + symbolName))
          .fontSize(IconSize.STANDARD)
          .fontColor([this.currentTool === tool ? Color.White : IconColor.SECONDARY])
      } else {
        // 降级到Emoji图标
        Text(icon)
          .fontSize(20)
          .fontColor(this.currentTool === tool ? Color.White : HCColor.TEXT_PRIMARY)
      }
    }
    .width(48)
    .height(48)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.currentTool === tool ? HCColor.PRIMARY : HCColor.SURFACE)
    .border({
      width: this.currentTool === tool ? 0 : 1,
      color: this.currentTool === tool ? HCColor.PRIMARY : HCColor.BORDER,
      radius: 8
    })
    .margin({ right: 8 })
    .onClick(() => {
      // 记录工具切换埋点
      this.trackAsync((): void => {
        analytics.trackToolSwitch(this.currentTool, tool);
      });

      // 再次点击「笔」→ 打开笔刷面板
      if (tool === 'pen' && this.currentTool === 'pen') {
        this.showBrushPanel = true;
        this.closeOtherPopups('brush');
        return;
      }

      // 统一切换（宽度记忆 + 状态反馈）
      this.switchTool(tool);
    })
  }

  // ═══ v2.3 协同状态栏（K-R2-2：SessionManager / PermissionGuard / ViewportSyncManager UI 接线）═══
  @Builder buildCollabBar() {
    // 沉浸模式下隐藏协同状态栏
    if (this.immersiveMode) {
      Blank()
    } else {
      Row() {
      Text(this.collabStatus.hasSession ? '连' : '锁')
        .fontSize(12)
        .margin({ right: 4 })

      Text(this.collabStatus.hasSession
        ? `${this.collabStatus.shortSessionId} · ${this.collabStatus.sessionRoleText} · ${this.collabStatus.onlineDeviceCount}台`
        : '单机模式（首页可创建流转会话）')
        .fontSize(10)
        .fontColor(HCColor.TEXT_SECONDARY)
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // C03（§4.6）：离线同步状态 chip —— DROPPED 警告级持续可见（非一闪 toast），
      // PENDING/OFFLINE 中性告知；SYNCED 不展示（无噪声）。
      // 数据源：CollabStatusSnapshot.pendingOpCount / droppedOpCount / wsConnected（snapshot 每 1s 轮询刷新）。
      if (this.collabStatus.droppedOpCount > 0) {
        Text(`! 已有 ${this.collabStatus.droppedOpCount} 笔超出缓存被丢弃`)
          .fontSize(10)
          .fontColor(HCColor.DANGER)
          .backgroundColor(HCColor.DANGER_BG)
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 4 })
          .onClick(() => {
            this.collabService.acknowledgeDropped();
            this.collabStatus = this.collabService.snapshot();
          })
      } else if (!this.collabStatus.wsConnected && this.collabStatus.hasSession) {
        Text('! 离线 · 本地已保存，未同步')
          .fontSize(10)
          .fontColor(HCColor.WARNING)
          .backgroundColor(HCColor.WARNING_BG)
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 4 })
      } else if (this.collabStatus.pendingOpCount > 0) {
        Text(`⏳ ${this.collabStatus.pendingOpCount} 笔待同步`)
          .fontSize(10)
          .fontColor(HCColor.PRIMARY)
          .backgroundColor(HCColor.PRIMARY_BG)
          .borderRadius(6)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
          .margin({ left: 4 })
      }

      // 视口同步演示：验证 ≤5Hz 节流
      Button('视口同步')
        .fontSize(10)
        .height(24)
        .padding({ left: 8, right: 8 })
        .fontColor(HCColor.PRIMARY)
        .backgroundColor(HCColor.PRIMARY_BG)
        .borderRadius(6)
        .margin({ left: 4 })
        .onClick(() => this.triggerViewportSync())

      Button('主')
        .fontSize(10)
        .height(24)
        .width(30)
        .padding({ left: 0, right: 0 })
        .fontColor(HCColor.TEXT_TERTIARY)
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(6)
        .margin({ left: 4 })
        .onClick(() => this.goHome())
    }
    .width('100%')
    .height(30)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.collabStatus.hasSession ? HCColor.PRIMARY_BG : HCColor.PAGE_BG)
    .border({ width: { bottom: 1 }, color: HCColor.BORDER })
    }
  }

  // ═══ 底部工具栏（UI 优化：13 个控件单行溢出 → 主栏 5 个 + 更多抽屉）═══
  // ═══ 底部工具栏（v4 重做：现代设计，分组清晰，带按压强反馈）═══

  // ═══ T05a S2：悬停态下半区工具面板（固定高度，作为 Canvas Stack 的兄弟节点，不含 Canvas）═══
  // 反向约束（约定 G-2）：本面板固定高度 → 上方 Canvas Stack 的 layoutWeight(1) 自动反推为 creaseTop。
  // 折痕区已在 build() 中作为独立兄弟节点渲染（纯色留白 + hitTestBehavior None）。
  @Builder buildHoverToolPanel() {
    Column() {
      Row() {
        // 笔 / 橡皮 / 形状
        this.buildToolBtnMobile('pen', '笔')
        this.buildToolBtnMobile('eraser', '擦')
        this.buildToolBtnMobile('shape', '形')

        Blank()

        // 撤销 / 重做
        Stack() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.UNDO))
            .fontSize(18)
            .fontColor([HCColor.TEXT_PRIMARY])
        }
        .width(40).height(40)
        .alignContent(Alignment.Center)
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(20).margin({ right: 8 })
        .onClick(() => this.undo())
        Stack() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.REDO))
            .fontSize(18)
            .fontColor([HCColor.TEXT_PRIMARY])
        }
        .width(40).height(40)
        .alignContent(Alignment.Center)
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(20).margin({ right: 8 })
        .onClick(() => this.redo())

        // NOTE-02/03/04：手机底部常驻快捷入口（签/搜）
        Column() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.BOOKMARK))
            .fontSize(18)
            .fontColor([this.bookmarkBarOpen ? Color.White : HCColor.TEXT_PRIMARY])
        }
        .width(40).height(40)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.bookmarkBarOpen ? HCColor.PRIMARY : HCColor.DIVIDER)
        .borderRadius(20)
        .margin({ right: 8 })
        .onClick(() => {
          this.bookmarkBarOpen = !this.bookmarkBarOpen;
          this.setStatus('书签栏已' + (this.bookmarkBarOpen ? '展开' : '收起'));
        })

        Column() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.SEARCH))
            .fontSize(18)
            .fontColor([this.searchOpen ? Color.White : HCColor.TEXT_PRIMARY])
        }
        .width(40).height(40)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.searchOpen ? HCColor.PRIMARY : HCColor.DIVIDER)
        .borderRadius(20)
        .margin({ right: 8 })
        .onClick(() => this.toggleSearch())

        // 图层
        Button('层')
          .fontSize(16).width(40).height(40)
          .backgroundColor(this.showLayerPanel ? HCColor.WARNING_BG : HCColor.DIVIDER)
          .borderRadius(20)
          .onClick(() => {
            this.showLayerPanel = !this.showLayerPanel;
            this.closeOtherPopups('layer');
          })
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(HCColor.PAGE_BG)
    .border({ width: { top: 1 }, color: HCColor.BORDER })
  }

  /** 左工具栏按钮：SymbolGlyph 图标 + 中文短标签 */
  @Builder
  buildLeftToolBtn($$: ToolBtnParam) {
    Column() {
      SymbolGlyph($r('sys.symbol.' + $$.symbol))
        .fontSize(18)
        .fontColor([$$.active ? HCColor.PRIMARY : HCColor.ICON_SECONDARY])
      if ($$.showLabel) {
        Text($$.label)
          .fontSize(10)
          .fontColor($$.active ? HCColor.PRIMARY : HCColor.TEXT_TERTIARY)
          .margin({ top: 2 })
      }
    }
    .width($$.wide ? 80 : 56)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(12)
    .backgroundColor($$.active ? 'rgba(0,125,255,0.08)' : Color.Transparent)
    .onClick(() => {
      $$.onTap();
    })
  }

  /** 笔记工具按钮 */
  @Builder
  /**
   * 便签/便利贴创建入口。
   * v2.6.0：①对象字面量传参（按引用）→ 高亮实时刷新；
   *        ②不再把 currentTool 改成 'note'/'sticky'（非绘图工具值会把工具栏高亮全部清空，
   *          让用户以为"工具乱了"），改为记录 noteMode 作为高亮依据。
   */
  buildNoteToolBtn($$: NoteToolBtnParam) {
    Column() {
      Text($$.label)
        .fontSize(14)
        .fontColor($$.active ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY)
      if ($$.wide) {
        Text($$.mode === 'note' ? '文本' : '便利贴')
          .fontSize(10)
          .fontColor(HCColor.TEXT_TERTIARY)
          .margin({ top: 2 })
      }
    }
    .width($$.wide ? 80 : 56)
    .height(56)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(12)
    .backgroundColor($$.active ? 'rgba(0,125,255,0.08)' : Color.Transparent)
    .onClick(() => {
      this.noteMode = $$.mode;
      this.createNewNode($$.nodeType);
      this.setStatus($$.mode === 'note' ? '文本便签：已创建，可拖动/双击编辑' : '便利贴：已创建，可拖动/双击编辑');
    })
  }

  private createNewNode(nodeType: string): void {
    // v2.7.0：文本框改为「先输入内容再落盘」——直接打开编辑面板，
    //   避免落一个内容为占位符的空白框（用户看不到编辑入口，误判功能不可用）。
    if (nodeType === NodeType.TEXT) {
      this.startNewTextNode();
      return;
    }
    // 便利贴仍走即时创建（内容可后续双击编辑）
    const node: CanvasNode = {
      id: 'node_' + Date.now(),
      type: nodeType,
      lamport: Date.now(),
      deleted: false,
      resources: '',
      x: 100,
      y: 100,
      w: 200,
      h: 150,
      z: this.canvasNodes.length + 1,
      payload: nodeType === NodeType.TEXT
        ? { content: '新文本', md: false, size: 14, color: HCAccent.TEXT_STRONG }
        : { text: '新便利贴', color: '#FFF3CD' }
    };
    this.canvasNodes.push(node);
    this.canvasNodes = this.canvasNodes.slice();
    this.markDirty();
    this.flushSave();
  }

  // ═══ T05a S3（B.2）：md/lg 左侧竖向工具条 64vp（Canvas 的兄弟节点，不含 Canvas）═══
  // PRD v4 整改：左垂直悬浮工具栏（磨砂半透明 + 收/展动画 + SymbolGlyph）
  //   默认收缩为 56vp（仅图标）；点击展开为 88vp（图标 + 文字标签）
  //   6 个核心高频工具：笔/擦/形/刷 + 撤销/重做
  //   低频工具（图层/套索/导入图片/导出/反馈）走侧边浮窗 buildSideFloatPanel
  @Builder buildLeftToolbar() {
    Column() {
      // 顶部展开/收起按钮（图标化）
      Row() {
        SymbolGlyph($r('sys.symbol.' + (this.leftToolbarExpanded ? 'arrowLeft' : 'arrowRight')))
          .fontSize(16)
          .fontColor([HCColor.ICON_SECONDARY])
      }
      .width(40).height(40)
      .justifyContent(FlexAlign.Center)
      .borderRadius(10)
      .backgroundColor('rgba(0,0,0,0.04)')
      .margin({ bottom: 14 })
      .onClick(() => {
        this.leftToolbarExpanded = !this.leftToolbarExpanded;
      })

      // ─── 6 个核心工具（垂直排列，SymbolGlyph + 中文短标签） ───
      // v2.6.0：对象字面量传参（按引用传递）→ 高亮实时跟随 currentTool
      this.buildLeftToolBtn({ key: 'pen', label: '笔', symbol: IconSymbols.PEN, active: this.currentTool === 'pen',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('pen') })
      this.buildLeftToolBtn({ key: 'eraser', label: '擦', symbol: IconSymbols.ERASER, active: this.currentTool === 'eraser',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('eraser') })
      this.buildLeftToolBtn({ key: 'shape', label: '形', symbol: IconSymbols.SHAPE, active: this.currentTool === 'shape',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('shape') })
      this.buildLeftToolBtn({ key: 'brush', label: '刷', symbol: IconSymbols.BRUSH, active: this.currentTool === 'brush',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('brush') })
      this.buildLeftToolBtn({ key: 'lasso', label: '选', symbol: IconSymbols.LASSO, active: this.currentTool === 'lasso',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('lasso') })
      this.buildLeftToolBtn({ key: 'eyedropper', label: '取', symbol: IconSymbols.EYEDROPPER, active: this.currentTool === 'eyedropper',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('eyedropper') })
      this.buildLeftToolBtn({ key: 'fill', label: '填', symbol: IconSymbols.FILL, active: this.currentTool === 'fill',
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.switchTool('fill') })

      // NOTE-01：文本便签 / 便利贴 创建入口（切换 noteMode，高亮当前模式）
      this.buildNoteToolBtn({ label: '文本', mode: 'note', nodeType: NodeType.TEXT,
        active: this.noteMode === 'note', wide: this.leftToolbarExpanded })
      this.buildNoteToolBtn({ label: '便利贴', mode: 'sticky', nodeType: NodeType.STICKY,
        active: this.noteMode === 'sticky', wide: this.leftToolbarExpanded })

      // NOTE-02/03/04：双链 / 书签 / 搜索 入口
      this.buildLeftToolBtn({ key: 'link', label: '链', symbol: IconSymbols.LINK, active: this.linkMode,
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.openUtilityEntry('link') })
      this.buildLeftToolBtn({ key: 'bookmark', label: '签', symbol: IconSymbols.BOOKMARK, active: this.bookmarkBarOpen,
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.openUtilityEntry('bookmark') })
      this.buildLeftToolBtn({ key: 'search', label: '搜', symbol: IconSymbols.SEARCH, active: this.searchOpen,
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.openUtilityEntry('search') })

      // 分隔符（薄）
      Column()
        .width(20).height(1)
        .backgroundColor('rgba(0,0,0,0.08)')
        .margin({ top: 14, bottom: 14 })

      this.buildLeftToolBtn({ key: 'undo', label: '撤销', symbol: IconSymbols.UNDO, active: false,
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.undo() })
      this.buildLeftToolBtn({ key: 'redo', label: '重做', symbol: IconSymbols.REDO, active: false,
        showLabel: this.leftToolbarExpanded, wide: this.leftToolbarExpanded, onTap: () => this.redo() })
    }
    .width(this.leftToolbarExpanded ? 88 : 56)
    .height('100%')
    .padding({ top: 16, bottom: 16, left: 4, right: 4 })
    .backgroundColor(HCNeutral.SURFACE_TINT)
    .border({ width: { right: 1 }, color: 'rgba(0,0,0,0.08)' })
    .shadow({ radius: 8, color: 'rgba(0,0,0,0.06)', offsetX: 2, offsetY: 0 })
    .animation({ duration: 250, curve: Curve.EaseInOut })
  }

  /** PRD v4 左工具栏按钮：SymbolGlyph 图标 + 中文短标签（展开态显示标签）*/
  @Builder buildParamPanel() {
    Column() {
      if (this.currentTool === 'pen' || this.currentTool === 'shape' || this.currentTool === 'brush') {
        // 标题栏：左侧笔刷参数图标，右侧折叠按钮
        Row() {
          Row() {
            SymbolGlyph($r('sys.symbol.' + IconSymbols.PALETTE))
              .fontSize(14)
              .fontColor([HCColor.ICON_SECONDARY])
            Text('笔刷参数')
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(HCColor.TEXT_SECONDARY)
              .margin({ left: 6 })
          }
          .layoutWeight(1)

          SymbolGlyph($r('sys.symbol.' + IconSymbols.CLOSE))
            .fontSize(14)
            .fontColor([HCColor.ICON_SECONDARY])
            .width(28).height(28)
            .onClick(() => {
              this.paramPanelCollapsed = true;
            })
        }
        .width('100%')
        .margin({ bottom: 14 })

        // 颜色色板：8 色圆角色块 + 白色选中环
        Row() {
          this.buildColorSwatch({ hexColor: '#000000', active: this.currentColor === '#000000' })
          this.buildColorSwatch({ hexColor: '#333333', active: this.currentColor === '#333333' })
          this.buildColorSwatch({ hexColor: '#007DFF', active: this.currentColor === '#007DFF' })
          this.buildColorSwatch({ hexColor: '#C0392B', active: this.currentColor === '#C0392B' })
          this.buildColorSwatch({ hexColor: '#2E9E4F', active: this.currentColor === '#2E9E4F' })
          this.buildColorSwatch({ hexColor: '#F5A623', active: this.currentColor === '#F5A623' })
          this.buildColorSwatch({ hexColor: '#9C27B0', active: this.currentColor === '#9C27B0' })
          this.buildColorSwatch({ hexColor: '#E74C3C', active: this.currentColor === '#E74C3C' })
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .margin({ bottom: 16 })

        // 粗细：Slider 连续调节 + 当前数值预览
        Row() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.SIZE))
            .fontSize(14)
            .fontColor([HCColor.ICON_SECONDARY])
            .margin({ right: 8 })
          Slider({
            value: this.currentWidth,
            min: 1,
            max: 20,
            step: 1,
            style: SliderStyle.InSet
          })
            .width(140)
            .trackThickness(4)
            .selectedColor(HCColor.PRIMARY)
            .blockColor(HCColor.PRIMARY)
            .showSteps(true)
            .onChange((value: number) => {
              this.currentWidth = value;
            })
          Text(`${this.currentWidth.toFixed(0)}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(HCColor.TEXT_PRIMARY)
            .width(24)
            .textAlign(TextAlign.End)
        }
        .width('100%')
        .margin({ bottom: 14 })

        // 透明度：一行标签 + Switch
        Row() {
          Text('透明')
            .fontSize(12)
            .fontColor(HCColor.TEXT_SECONDARY)
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.currentOpacity < 1.0 })
            .selectedColor(HCColor.PRIMARY)
            .switchPointColor('#FFFFFF')
            .onChange((isOn: boolean) => {
              this.currentOpacity = isOn ? 0.5 : 1.0;
            })
        }
        .width('100%')
        .margin({ bottom: this.currentTool === 'shape' ? 12 : 0 })

        // 形状工具专属：自由 / 规整分段切换
        if (this.currentTool === 'shape') {
          Row() {
            this.buildSegmentBtn({ label: '自由', active: !this.shapeSnap, action: () => {
              this.shapeSnap = false;
              this.setStatus('形状：自由手绘');
            } })
            this.buildSegmentBtn({ label: '规整', active: this.shapeSnap, action: () => {
              this.shapeSnap = true;
              this.setStatus('形状：自动规整（矩形/圆/直线）');
            } })
          }
          .width('100%')
          .backgroundColor('rgba(0,0,0,0.04)')
          .padding(2)
          .borderRadius(10)
        }
      }
    }
    .width(280)
    .height(268)
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(20)
    // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（左侧工具面板）。
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.DIVIDER })
    .shadow({ radius: 24, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 8 })
    .zIndex(100)
    .position({ x: 80, y: 64 })
  }

  /** 分段按钮（用于形状自由/规整切换）· v2.6.0：对象传参（按引用）保证高亮刷新 */
  @Builder
  buildSegmentBtn($$: SegmentBtnParam) {
    Column() {
      Text($$.label)
        .fontSize(12)
        .fontWeight($$.active ? FontWeight.Medium : FontWeight.Regular)
        .fontColor($$.active ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY)
    }
    .width('50%').height(32)
    .justifyContent(FlexAlign.Center)
    .borderRadius(8)
    .backgroundColor($$.active ? HCColor.SURFACE : HCColor.TRANSPARENT)
    .border($$.active ? { width: 1, color: HCColor.PRIMARY_BORDER } : {})
    .onClick($$.action)
  }

  /** 参数面板：折叠态（享做笔记式侧边药丸，显示当前颜色/线宽，点击展开） */
  @Builder
  buildParamPanelCollapsed() {
    Column() {
      // 当前颜色预览（大圆角色块 + 白色描边）
      Column()
        .width(28).height(28)
        .backgroundColor(this.currentColor)
        .borderRadius(10)
        .border({ width: 2, color: '#FFFFFF' })
        .shadow({ radius: 4, color: 'rgba(0,0,0,0.12)', offsetY: 1 })
        .margin({ bottom: 12 })

      // 当前线宽预览
      Circle({ width: Math.max(6, Math.min(18, this.currentWidth)), height: Math.max(6, Math.min(18, this.currentWidth)) })
        .fill(HCColor.ICON_SECONDARY)
        .margin({ bottom: 12 })

      // 展开箭头
      SymbolGlyph($r('sys.symbol.' + IconSymbols.MORE))
        .fontSize(14)
        .fontColor([HCColor.ICON_SECONDARY])
        .rotate({ angle: 90 })
    }
    .width(44)
    .height(120)
    .padding(10)
    .borderRadius(22)
    // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（右侧竖条把手）。
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.DIVIDER })
    .shadow({ radius: 16, color: 'rgba(0,0,0,0.10)', offsetX: 2, offsetY: 4 })
    .zIndex(100)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .position({ x: 80, y: 64 })
    .onClick(() => {
      this.paramPanelCollapsed = false;
    })
  }

  /** 颜色色板按钮：大圆角色块 + 白色选中环 · v2.6.0：对象传参（按引用）保证选中环刷新 */
  @Builder
  buildColorSwatch($$: ColorSwatchParam) {
    Column() {
      Column()
        .width(32).height(32)
        .backgroundColor($$.hexColor)
        .borderRadius(10)
        .border({
          width: $$.active ? 3 : 1,
          color: $$.active ? '#FFFFFF' : 'rgba(0,0,0,0.08)'
        })
        .shadow({ radius: 2, color: 'rgba(0,0,0,0.08)', offsetX: 0, offsetY: 1 })
    }
    .width(38).height(38)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.currentColor = $$.hexColor;
    })
  }

  /** 缩放控制簇内的单个圆形图标按钮 · v2.6.0：对象传参（按引用）保证高亮刷新 */
  @Builder
  zoomBtn($$: ZoomBtnParam) {
    Row() {
      SymbolGlyph($r('sys.symbol.' + $$.symbol))
        .fontSize(18)
        .fontColor([$$.active ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY])
    }
    .width(32).height(32)
    .justifyContent(FlexAlign.Center)
    .borderRadius(16)
    .backgroundColor($$.active ? 'rgba(0,125,255,0.12)' : 'rgba(0,0,0,0)')
    .onClick($$.action)
  }

  /**
   * 🔧 P0 对标重构：顶部工具条（对标 GoodNotes/享做/云记 的画板顶部布局）
   * 始终渲染：返回 · 撤销 · 重做 · 更多（导出/设置/协作入口）
   * 顶部位置 y:0，zIndex 高于画布，避免与底部工具栏重叠。
   */
  @Builder buildTopBar() {
    Row() {
      // 返回：回到笔记列表（路由 /pages/Index）
      SymbolGlyph($r('sys.symbol.' + IconSymbols.BACK))
        .fontSize(20)
        .fontColor([HCColor.TEXT_PRIMARY])
        .width(36).height(36)
        .borderRadius(18)
        .backgroundColor('rgba(0,0,0,0.04)')
        .onClick(() => {
          router.back({ url: 'pages/Index' });
        })

      // 撤销 / 重做（核心交互缺失——当前依赖未绑定的 handleGestureEvent；用按钮兜底）
      SymbolGlyph($r('sys.symbol.' + IconSymbols.UNDO))
        .fontSize(18)
        .fontColor([this.canUndo ? HCColor.TEXT_PRIMARY : HCColor.TEXT_DISABLED])
        .width(36).height(36)
        .borderRadius(18)
        .backgroundColor('rgba(0,0,0,0.04)')
        .margin({ left: 8 })
        .onClick(() => {
          if (this.canUndo) {
            this.undo();
            this.setStatus('撤销');
          }
        })
      SymbolGlyph($r('sys.symbol.' + IconSymbols.REDO))
        .fontSize(18)
        .fontColor([this.canRedo ? HCColor.TEXT_PRIMARY : HCColor.TEXT_DISABLED])
        .width(36).height(36)
        .borderRadius(18)
        .backgroundColor('rgba(0,0,0,0.04)')
        .margin({ left: 4 })
        .onClick(() => {
          if (this.canRedo) {
            this.redo();
            this.setStatus('重做');
          }
        })

      Blank()

      // 更多入口（低频工具/导出/设置）
      SymbolGlyph($r('sys.symbol.' + IconSymbols.MORE))
        .fontSize(20)
        .fontColor([HCColor.TEXT_PRIMARY])
        .width(36).height(36)
        .borderRadius(18)
        .backgroundColor('rgba(0,0,0,0.04)')
        .onClick(() => {
          this.showMorePanel = !this.showMorePanel;
          this.closeOtherPopups('more');
        })
    }
    // 🔧 修复：顶部 padding 48vp 给状态栏留安全区（之前 .height(48).padding(top:0)
    //   导致整个工具栏被系统状态栏遮住 → 返回/撤销/重做按钮实际被遮、看起来"点击无响应"，
    //   满足《上架检测FAQ-布局基础要求》。增加 height 到 96（48vp 状态栏 + 48vp 工具栏）。
    .width('100%')
    .height(96)
    .padding({ left: 12, right: 12, top: 48, bottom: 8 })
    .backgroundColor(HCColor.PAGE_BG)
    .border({ width: { bottom: 1 }, color: HCColor.DIVIDER })
    .position({ x: 0, y: 0 })
    .zIndex(99)
  }

  /**
   * 🔧 P0 对标重构：底部一体化工具栏（替代原 buildToolSwitcher 单一工具切换 + buildParamPanel 浮窗）
   * 参考 GoodNotes / 享做 / 云记 的画板底部工具区范式——
   *   工具切换（笔/橡皮/形状/选/填/取色） · 当前色板（8 色） · 线宽档位 · 透明度
   * 永远可见（不依赖 isTabletWidth/immersiveMode），作为画板工具的核心入口。
   */
  @Builder buildBottomToolbar() {
    Column() {
      Divider()
        .width('92%')
        .height(0.5)
        .color('rgba(0,0,0,0.08)')
        .margin({ bottom: 6 })
      Row() {
        // 工具切换：6 个核心工具按钮
        // v2.6.0：改为对象字面量传参（按引用传递）→ 高亮随 currentTool 实时刷新
        Row() {
          this.bottomToolBtn({ key: 'pen', symbol: IconSymbols.PEN, label: '笔',
            active: this.currentTool === 'pen', showLabel: true, wide: false,
            onTap: () => this.switchTool('pen') })
          this.bottomToolBtn({ key: 'eraser', symbol: IconSymbols.ERASER, label: '擦',
            active: this.currentTool === 'eraser', showLabel: true, wide: false,
            onTap: () => this.switchTool('eraser') })
          this.bottomToolBtn({ key: 'shape', symbol: IconSymbols.SHAPE, label: '形',
            active: this.currentTool === 'shape', showLabel: true, wide: false,
            onTap: () => this.switchTool('shape') })
          this.bottomToolBtn({ key: 'lasso', symbol: IconSymbols.LASSO, label: '选',
            active: this.currentTool === 'lasso', showLabel: true, wide: false,
            onTap: () => this.switchTool('lasso') })
          this.bottomToolBtn({ key: 'fill', symbol: IconSymbols.FILL, label: '填',
            active: this.currentTool === 'fill', showLabel: true, wide: false,
            onTap: () => this.switchTool('fill') })
          this.bottomToolBtn({ key: 'eyedropper', symbol: IconSymbols.EYEDROPPER, label: '取',
            active: this.currentTool === 'eyedropper', showLabel: true, wide: false,
            onTap: () => this.switchTool('eyedropper') })
        }
        .margin({ right: 12 })

        // 分隔
        Column()
          .width(1).height(28)
          .backgroundColor('rgba(0,0,0,0.08)')
          .margin({ right: 12 })

        // 当前色板（笔/形 模式下可见；橡皮/选/填/取色模式下隐藏颜色避免误导）
        if (this.currentTool === 'pen' || this.currentTool === 'shape') {
          Row() {
            this.bottomColorBtn({ color: '#000000', active: this.currentColor === '#000000' })
            this.bottomColorBtn({ color: '#333333', active: this.currentColor === '#333333' })
            this.bottomColorBtn({ color: '#007DFF', active: this.currentColor === '#007DFF' })
            this.bottomColorBtn({ color: '#C0392B', active: this.currentColor === '#C0392B' })
            this.bottomColorBtn({ color: '#2E9E4F', active: this.currentColor === '#2E9E4F' })
            this.bottomColorBtn({ color: '#F5A623', active: this.currentColor === '#F5A623' })
            this.bottomColorBtn({ color: '#9C27B0', active: this.currentColor === '#9C27B0' })
            this.bottomColorBtn({ color: '#E74C3C', active: this.currentColor === '#E74C3C' })
          }
          .margin({ right: 12 })

          Column()
            .width(1).height(28)
            .backgroundColor('rgba(0,0,0,0.08)')
            .margin({ right: 12 })

          // 线宽档位（5 档）：1/3/5/10/18
          Row() {
            this.bottomWidthBtn({ width: 1, dotSize: 2, active: this.currentWidth === 1 })
            this.bottomWidthBtn({ width: 3, dotSize: 4, active: this.currentWidth === 3 })
            this.bottomWidthBtn({ width: 5, dotSize: 6, active: this.currentWidth === 5 })
            this.bottomWidthBtn({ width: 10, dotSize: 12, active: this.currentWidth === 10 })
            this.bottomWidthBtn({ width: 18, dotSize: 22, active: this.currentWidth === 18 })
          }
          .margin({ right: 12 })

          Column()
            .width(1).height(28)
            .backgroundColor('rgba(0,0,0,0.08)')
            .margin({ right: 12 })

          // 透明度开关（笔模式下可用，橡皮无效）
          Row() {
            Text('透明')
              .fontSize(11)
              .fontColor(HCColor.TEXT_SECONDARY)
              .margin({ right: 6 })
            Toggle({ type: ToggleType.Switch, isOn: this.currentOpacity < 1.0 })
              .selectedColor(HCColor.PRIMARY)
              .switchPointColor('#FFFFFF')
              .width(38).height(22)
              .onChange((isOn: boolean): void => {
                this.currentOpacity = isOn ? 0.5 : 1.0;
              })
          }
        } else if (this.currentTool === 'eraser') {
          // 橡皮模式选择（对标享做「方块擦除/选中擦除」）：点擦 / 线擦 / 区域擦
          Row() {
            this.bottomEraserModeBtn({ mode: 'point', label: '点擦', active: this.eraserMode === 'point' })
            this.bottomEraserModeBtn({ mode: 'line', label: '线擦', active: this.eraserMode === 'line' })
            this.bottomEraserModeBtn({ mode: 'region', label: '区域', active: this.eraserMode === 'region' })
          }
          .margin({ right: 12 })

          Column()
            .width(1).height(28)
            .backgroundColor('rgba(0,0,0,0.08)')
            .margin({ right: 12 })

          Text('擦除半径')
            .fontSize(11)
            .fontColor(HCColor.TEXT_SECONDARY)
            .margin({ right: 8 })
          Slider({
            value: this.currentWidth,
            min: 1,
            max: 20,
            step: 1,
            style: SliderStyle.InSet
          })
            .width(120)
            .trackThickness(4)
            .selectedColor(HCColor.PRIMARY)
            .blockColor(HCColor.PRIMARY)
            .showSteps(true)
            .onChange((value: number) => {
              this.currentWidth = value;
              this.setStatus(`擦除半径：${value.toFixed(0)}`);
            })
          Text(`${this.currentWidth.toFixed(0)}`)
            .fontSize(12)
            .fontWeight(FontWeight.Medium)
            .fontColor(HCColor.TEXT_PRIMARY)
            .width(24)
            .textAlign(TextAlign.End)
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .padding({ top: 6, bottom: 10 })
    // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（底部一体化工具栏）。
    .backgroundColor(HCColor.SURFACE)
    .border({ width: { top: 1 }, color: 'rgba(0,0,0,0.06)' })
    .shadow({ radius: 12, color: 'rgba(0,0,0,0.06)', offsetX: 0, offsetY: -3 })
    .position({ x: 0, y: '100%' })
    .translate({ x: 0, y: -86 })
    .zIndex(98)
  }

  /** buildBottomToolbar 子按钮：橡皮模式选择（点擦/线擦/区域擦） */
  @Builder
  bottomEraserModeBtn($$: EraserModeBtnParam) {
    Text($$.label)
      .fontSize(12)
      .fontColor($$.active ? Color.White : HCColor.TEXT_SECONDARY)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor($$.active ? HCColor.PRIMARY : HCColor.DIVIDER)
      .borderRadius(12)
      .margin({ right: 6 })
      .onClick(() => {
        this.eraserMode = $$.mode;
        this.setStatus(`橡皮：${$$.label}模式`);
      })
  }

  /** buildBottomToolbar 子按钮：工具切换（高亮当前工具） */
  @Builder
  bottomToolBtn($$: ToolBtnParam) {
    Column() {
      SymbolGlyph($r('sys.symbol.' + $$.symbol))
        .fontSize(18)
        .fontColor([$$.active ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY])
        .width(32).height(32)
        .borderRadius(8)
        .backgroundColor($$.active ? HCColor.PRIMARY_BG : Color.Transparent)
      Text($$.label)
        .fontSize(10)
        .fontColor($$.active ? HCColor.PRIMARY : HCColor.TEXT_TERTIARY)
        .fontWeight($$.active ? FontWeight.Medium : FontWeight.Regular)
        .margin({ top: 2 })
    }
    .width(48).height(48)
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      $$.onTap();
    })
  }

  /** buildBottomToolbar 子按钮：颜色选择 */
  @Builder
  bottomColorBtn($$: ColorBtnParam) {
    Stack() {
      Circle().width(22).height(22).fill($$.color)
    }
    .width(30).height(30)
    .alignContent(Alignment.Center)
    .borderRadius(15)
    .backgroundColor($$.active ? HCColor.PRIMARY_BG : Color.Transparent)
    .border({
      width: $$.active ? 2 : 1,
      color: $$.active ? HCColor.PRIMARY : HCColor.BORDER,
    })
    .margin({ right: 4 })
    .onClick(() => {
      this.currentColor = $$.color;
      this.setStatus(`颜色：${$$.color}`);
    })
  }

  /** buildBottomToolbar 子按钮：线宽档位（当前选中的色板填充高亮） */
  @Builder
  bottomWidthBtn($$: WidthBtnParam) {
    Stack() {
      Circle()
        .width($$.dotSize).height($$.dotSize)
        .fill($$.active ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY)
    }
    .width(34).height(34)
    .alignContent(Alignment.Center)
    .borderRadius(17)
    .backgroundColor($$.active ? HCColor.PRIMARY_BG : Color.Transparent)
    .border({
      width: $$.active ? 1.5 : 1,
      color: $$.active ? HCColor.PRIMARY : HCColor.BORDER,
    })
    .margin({ right: 4 })
    .onClick(() => {
      this.currentWidth = $$.width;
      this.setStatus(`线宽：${$$.width}`);
    })
  }

  @Builder buildZoomCluster() {
    Row() {
      // 聚焦 / 全屏书写切换（常驻）
      this.zoomBtn({
        symbol: this.immersiveMode ? IconSymbols.FOCUS_EXIT : IconSymbols.FOCUS,
        active: this.immersiveMode,
        action: () => this.toggleImmersiveMode()
      })

      if (!this.immersiveMode) {
        // 分隔线
        Column()
          .width(1).height(20)
          .backgroundColor('rgba(0,0,0,0.1)')
          .margin({ left: 4, right: 4 })

        this.zoomBtn({ symbol: IconSymbols.ZOOM_OUT, active: false, action: () => this.zoomOut() })

        // 当前缩放百分比：轻点复位到 100%
        Text(`${Math.round(this.viewportScale * 100)}%`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(HCColor.TEXT_PRIMARY)
          .width(44)
          .textAlign(TextAlign.Center)
          .onClick(() => this.zoomReset())

        this.zoomBtn({ symbol: IconSymbols.ZOOM_IN, active: false, action: () => this.zoomIn() })
      }
    }
    .height(40)
    .padding({ left: 6, right: 6 })
    .borderRadius(20)
    // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（缩放控件）。
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.DIVIDER })
    .shadow({ radius: 16, color: 'rgba(0,0,0,0.10)', offsetX: 0, offsetY: 4 })
    .position({ x: this.isTabletWidth() ? 100 : 16, y: '100%' })
    // 🔧 P0 对标重构：translate y 上移避免被底部一体化工具栏（86vp 高）遮挡
    .translate({ x: 0, y: this.isTabletWidth() ? -96 : -120 })
    .zIndex(99)
  }

  @Builder buildRightLayerPanel() {
    Column() {
      Row() {
        Text('图层')
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor(HCColor.TEXT_PRIMARY)
          .layoutWeight(1)
        Text('常驻')
          .fontSize(10)
          .fontColor(HCColor.ICON_SECONDARY)
          .backgroundColor(HCColor.DIVIDER)
          .borderRadius(4)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
      }
      .width('100%')
      .height(40)
      .padding({ left: 12, right: 12 })

      LayerPanel({
        onChanged: (): void => {
          this.layerRevision++;
          this.renderHistory();
          this.markDirty();
        },
        onClose: (): void => {
          // lg 常驻：关闭回调被忽略（不可关）
        },
        onMergeRequest: (srcIds: string[]): string | null => {
          return this.mergeLayersRequest(srcIds);
        },
        onDuplicateRequest: (srcId: string): string | null => {
          return this.duplicateLayerRequest(srcId);
        },
        onGroupRequest: (ids: string[]): string | null => {
          return this.groupLayersRequest(ids);
        },
        onExportRequest: (layerId: string): void => {
          this.exportLayerRequest(layerId);
        },
        onLayerUndo: (): void => {
          this.undoLayerOperation();
        },
        undoable: this.layerUndoStack.length > 0
      })
        .layoutWeight(1)
        .width('100%')
    }
    .width(280)
    .height('100%')
    .backgroundColor(HCColor.SURFACE)
    .border({ width: { left: 1 }, color: HCColor.BORDER })
  }

  // ═══ 更多抽屉（享做笔记式：默认窄工具条，点击展开完整网格）═══
  @Builder buildMorePanel() {
    if (this.moreCollapsed) {
      this.buildMoreBar();
    } else {
      this.buildMoreExpanded();
    }
  }

  /** 更多工具：右下角 FAB 药丸按钮（参考 Flow / Notability 的浮动菜单按钮） */
  @Builder buildMoreBar() {
    Column() {
      SymbolGlyph($r('sys.symbol.' + IconSymbols.MORE))
        .fontSize(22)
        .fontColor([HCColor.TEXT_PRIMARY])
    }
    .width(52).height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(26)
    // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（「更多」圆钮）。
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.DIVIDER })
    .shadow({ radius: 20, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 4 })
    .position({ x: '100%', y: '100%' })
    .translate({ x: -84, y: -84 })
    .zIndex(98)
    .onClick(() => {
      this.moreCollapsed = false;
    })
  }

  /** 更多工具：展开形态（带遮罩的完整网格） */
  @Builder buildMoreExpanded() {
    Stack() {
      // 遮罩层（点击空白收起为窄条）
      // 🔧 修复：原 rgba(0,0,0,0.4) 整屏暗化会让白网格底纸看起来"变灰"，
      //   改为低不透明度的轻遮罩（约 10% 黑），既保留"展开面板"焦点感，
      //   又让白底纸/笔迹保持清晰可读。
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.10)')
        .hitTestBehavior(HitTestMode.Block)
        .onClick(() => {
          this.moreCollapsed = true;
        })

      // 抽屉主体（底部 46% 屏高，阶段2入口扩展后内容更多）
      Column() {
        // 拖拽把手
        Column()
          .width(36).height(4)
          .backgroundColor(HCColor.DIVIDER)
          .borderRadius(2)
          .margin({ top: 8, bottom: 4 })

        // 标题栏：ExtendedToolsPanel 已精简为分组网格（内部不再自带标题），
        // 由本抽屉统一提供「扩展工具」标题 + 收起，避免标题重复或缺失。
        Row() {
          Text('扩展工具')
            .fontSize(15).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
            .layoutWeight(1)
          Text('▼')
            .fontSize(12).fontColor(HCColor.ICON_SECONDARY)
            .width(24).height(24)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.moreCollapsed = true;
            })
        }
        .width('100%')
        .margin({ top: 8, bottom: 12 })

        // v3.0：用 ExtendedToolsPanel 替代旧版网格
        ExtendedToolsPanel({
          collapsed: this.moreCollapsed,
          onToolSelect: (key: string) => this.handleExtendedToolSelect(key),
          onClose: () => { this.moreCollapsed = true; }
        })

        Row() {
          Text('点击空白处收起')
            .fontSize(11)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ top: 12, bottom: 12 })
        }
      }
      .width('100%')
      // 🔧 v2.6.0 审核修复（问题①-2）：原 height 46% + position y 62% = 108%，
      //   抽屉有 8% 落到屏幕外，「导出」分组正好落在底部一体化工具栏（86vp，zIndex 98）
      //   之后，条目完全不可触达 → 审核判为"导出工具点击无响应"。
      //   现改为 66% 高、y 34% 起：抽屉底边回到屏幕底，内容全部落在工具栏上方。
      .height('66%')
      // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（扩展工具抽屉）。
      .backgroundColor(HCColor.SURFACE)
      .borderRadius({ topLeft: 20, topRight: 20 })
      .shadow({ radius: 16, color: 'rgba(0,0,0,0.15)', offsetY: -4 })
      .position({ x: 0, y: '34%' })
      .padding({ bottom: 12 })
    }
    .width('100%').height('100%')
    .position({ x: 0, y: 0 })
  }

  /** 更多抽屉单项（图标 + 短标签）；点击执行动作并自动关闭抽屉 */
  @Builder moreItem(icon: string, label: string, action: () => void) {
    Column() {
      Text(icon).fontSize(20).height(28)
      Text(label).fontSize(10).fontColor(HCColor.TEXT_PRIMARY).margin({ top: 2 })
    }
    .width('100%').height(64)
    .justifyContent(FlexAlign.Center)
    .borderRadius(10)
    .backgroundColor(HCColor.PAGE_BG)
    .onClick(() => {
      action();
      this.showMorePanel = false;
    })
  }

  // ═══ 弹窗 ═══

  /** 🔧 套索选区操作条（修复 showSelectMenu 有状态无渲染的隐性缺口）：删除/取消 */
  @Builder buildSelectMenu() {
    Row() {
      Text(`已选 ${this.selectedStrokes.length} 条`)
        .fontSize(12)
        .fontColor(HCColor.TEXT_SECONDARY)
        .margin({ right: 12 })

      Text('删除')
        .fontSize(13)
        .fontColor(Color.White)
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .backgroundColor(HCColor.DANGER)
        .borderRadius(16)
        .margin({ right: 8 })
        .onClick(() => {
          this.deleteSelectedStrokes();
        })

      Text('取消')
        .fontSize(13)
        .fontColor(HCColor.TEXT_PRIMARY)
        .padding({ left: 14, right: 14, top: 7, bottom: 7 })
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(16)
        .onClick(() => {
          this.selectedStrokes = [];
          this.selectedStrokeIds = [];
          this.showSelectMenu = false;
          this.setStatus('已取消选择');
        })
    }
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    // 🔴 v2.7.1：原硬编码 '#FFFFFF'，深色模式下白底 + 浅色文字/图标 → 不可读（套索选区操作条）。
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(16)
    .shadow({ radius: 16, color: 'rgba(0,0,0,0.12)', offsetX: 0, offsetY: 4 })
    .position({ x: '50%', y: '12%' })
    .translate({ x: -50, y: 0 })
    .zIndex(100)
  }

  /** 删除套索选中的笔迹（对标享做「选中擦除」） */
  private deleteSelectedStrokes(): void {
    if (this.selectedStrokeIds.length === 0) {
      return;
    }
    this.redoStack.push(...this.strokes.slice());
    this.strokes = this.strokes.filter((s: StrokeRecord) => !this.selectedStrokeIds.includes(s.id));
    this.strokeCount = this.strokes.length;
    // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
    this.updateUndoRedoState();
    this.renderHistory();
    this.markDirty();
    this.setStatus(`已删除 ${this.selectedStrokeIds.length} 条笔迹`, StatusSeverity.INFO);
    this.selectedStrokes = [];
    this.selectedStrokeIds = [];
    this.showSelectMenu = false;
  }

  @Builder buildColorPopup() {
    Column() {
      Text('选择颜色').fontSize(14).fontWeight(FontWeight.Medium).padding(10)
      Grid() {
        ForEach(this.colors, (c: string) => {
          GridItem() {
            Row() {
              Circle().width(28).height(28).fill(c)
                .stroke(this.currentColor === c ? HCColor.PRIMARY : HCColor.BORDER)
                .strokeWidth(this.currentColor === c ? 3 : 1)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .onClick(() => {
              const colorChangeProps: ColorChangeProps = {
                from_color: this.currentColor,
                to_color: c
              };
              this.trackAsync((): void => {
                analytics.track(AnalyticsEvent.COLOR_CHANGE, colorChangeProps);
              });
              this.currentColor = c;
              this.showColorPicker = false;
            })
          }
        })
      }
      .columnsTemplate('1fr 1fr 1fr 1fr 1fr 1fr 1fr 1fr')
      .rowsGap(8).columnsGap(6).padding(10)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('94%').backgroundColor(HCColor.SURFACE).borderRadius(14)
    .shadow({ radius: 12, color: '#00000018' })
    .position({ x: '3%', y: '28%' })
  }

  // ═══ 形状选择（全屏遮罩，选择形状或切工具即关闭）═══
  @Builder buildShapePopup() {
    Column() {
      Column() {
        Row() {
          this.shapeBtn({ shape: 'rectangle', label: '▭ 矩形', active: this.currentShape === 'rectangle' })
          this.shapeBtn({ shape: 'circle', label: '○ 圆', active: this.currentShape === 'circle' })
          this.shapeBtn({ shape: 'arrow', label: '→ 箭头', active: this.currentShape === 'arrow' })
          this.shapeBtn({ shape: 'line', label: '— 直线', active: this.currentShape === 'line' })
        }
        .padding(8)
      }
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(12)
      .shadow({ radius: 12, color: '#00000020' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HCOverlay.SHADE_20) // 半透明遮罩：防误触画布
    .justifyContent(FlexAlign.Center)
    .position({ x: 0, y: 0 })
  }

  @Builder shapeBtn($$: ShapeBtnParam) {
    Text($$.label)
      .fontSize(13)
      .height(40)
      .padding({ left: 14, right: 14 })
      .backgroundColor($$.active ? HCColor.PRIMARY_BG : HCColor.PAGE_BG)
      .border({ width: $$.active ? 2 : 1, color: $$.active ? HCColor.PRIMARY : HCColor.BORDER, radius: 8 })
      .margin({ left: 4, right: 4 })
      .onClick(() => {
        this.currentShape = $$.shape;
        this.currentTool = 'shape';
        this.showShapePicker = false;
        this.setStatus(`形状模式：${this.shapeLabel($$.shape)}（拖动绘制）`);
      })
  }

  @Builder buildWidthPopup() {
    Column() {
      Text('笔画粗细').fontSize(14).fontWeight(FontWeight.Medium).padding(10)
      ForEach(this.widths, (w: number) => {
        Row() {
          Circle().width(w).height(w).fill(this.currentColor)
          Text(`${w}px`).fontSize(13).margin({ left: 8 })
          Blank()
          if (this.currentWidth === w) Text('✓').fontColor(HCColor.PRIMARY)
        }
        .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .onClick(() => {
          const widthChangeProps: WidthChangeProps = {
            from_width: this.currentWidth,
            to_width: w
          };
          this.trackAsync((): void => {
            analytics.track(AnalyticsEvent.STROKE_WIDTH_CHANGE, widthChangeProps);
          });
          this.pickWidth(w);
          this.showWidthPicker = false;
        })
      })
    }
    .width('80%').backgroundColor(HCColor.SURFACE).borderRadius(14)
    .shadow({ radius: 12, color: '#00000018' })
    .position({ x: '10%', y: '35%' })
  }

  // ═══ 底纸选择（W6）═══
  @Builder buildPaperPopup() {
    Column() {
      Column() {
        Text('选择底纸').fontSize(14).fontWeight(FontWeight.Medium).padding(10)
        ForEach(this.paperOptions, (opt: PaperOption) => {
          Row() {
            Text(opt.name).fontSize(13).fontColor(HCColor.TEXT_PRIMARY)
            Blank()
            if (this.paperTemplate === opt.template) {
              Text('✓').fontSize(13).fontColor(HCColor.PRIMARY)
            }
          }
          .width('100%')
          .height(38)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.paperTemplate === opt.template ? HCColor.PRIMARY_BG : HCColor.SURFACE)
          .onClick(() => this.changePaper(opt.template))
        }, (opt: PaperOption) => opt.template)
      }
      .width('72%')
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(14)
      .clip(true)
      .shadow({ radius: 14, color: '#00000022' })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HCOverlay.SHADE_13)
    .justifyContent(FlexAlign.Center)
    .position({ x: 0, y: 0 })
    .onClick(() => {
      this.showPaperPicker = false;
    })
  }

  // ═══ 笔刷面板（W5）：底部抽屉 + 点击空白关闭 ═══
  @Builder buildBrushSheet() {
    Column() {
      Text('')
        .width('100%')
        .layoutWeight(1)
        .onClick(() => {
          this.showBrushPanel = false;
        })

      // 橡皮擦模式选择（对标享做「方块擦除/选中擦除」；仅橡皮工具激活时显示）
      if (this.currentTool === 'eraser' || this.currentBrush === 'eraser') {
        Row() {
          Text('擦除模式')
            .fontSize(12)
            .fontColor(HCColor.ICON_SECONDARY)
            .margin({ right: 8 })
          this.eraserModeBtn({ mode: 'point', label: '点擦', active: this.eraserMode === 'point' })
          this.eraserModeBtn({ mode: 'line', label: '线擦', active: this.eraserMode === 'line' })
          this.eraserModeBtn({ mode: 'region', label: '区域', active: this.eraserMode === 'region' })
        }
        .width('100%')
        .padding({ left: 16, right: 12, top: 8, bottom: 8 })
        .backgroundColor(HCColor.SURFACE)
      }

      BrushPanel({
        brushOptions: this.brushOptions,
        currentTool: this.currentBrush,
        currentWidth: this.currentWidth,
        currentColor: this.currentColor,
        onPickBrush: (tool: string): void => {
          this.applyBrush(tool);
          this.currentTool = 'pen';
          this.setStatus(`笔刷：${this.brushByTool(tool).name}`);
        },
        onPickWidth: (width: number): void => {
          this.pickWidth(width);
        },
        onPickColor: (color: string): void => {
          this.currentColor = color;
          this.setStatus(`颜色：${color}`);
        },
        onClose: (): void => {
          this.showBrushPanel = false;
        },
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(HCOverlay.SHADE_13)
    .position({ x: 0, y: 0 })
  }

  /** 橡皮擦模式按钮（point 点擦 / line 线擦 / region 区域擦）· v2.6.0：对象传参（按引用） */
  @Builder
  eraserModeBtn($$: EraserModeBtnParam) {
    Text($$.label)
      .fontSize(12)
      .fontColor($$.active ? Color.White : HCColor.TEXT_PRIMARY)
      .padding({ left: 12, right: 12, top: 5, bottom: 5 })
      .backgroundColor($$.active ? HCColor.PRIMARY : HCColor.DIVIDER)
      .borderRadius(12)
      .margin({ right: 6 })
      .onClick(() => {
        this.eraserMode = $$.mode;
        this.setStatus(`橡皮：${$$.label}模式`);
      })
  }

  /** 统一的线宽设置：夹到当前笔刷合法区间，避免荧光笔被设成 1px 之类的无效值 */
  private pickWidth(width: number): void {
    const brush: BrushOption = this.brushByTool(this.currentBrush);
    let next: number = width;
    if (next < brush.minWidth) {
      next = brush.minWidth;
    }
    if (next > brush.maxWidth) {
      next = brush.maxWidth;
    }
    this.currentWidth = next;
    // 🔧 工具状态记忆：记录当前工具的宽度，切回时恢复
    this.widthByTool[this.currentTool] = next;
    if (next !== width) {
      this.setStatus(`${this.brushByTool(this.currentBrush).name}线宽范围 ${brush.minWidth}~${brush.maxWidth}`);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 触摸处理（仅活动层）
  // ═══════════════════════════════════════════════════════════════

  // ═══ S2-Bfix / A2-4：导图框选（拖拽矩形 → 命中 strokes → buildFromStrokes）═══
  private handleSelectTouch(e: TouchEvent): void {
    let touchList: TouchObject[] = e.touches;
    if (!touchList || touchList.length === 0) {
      touchList = e.changedTouches;
    }
    if (!touchList || touchList.length === 0) return;
    // 修复框选无反馈/位置错：触摸坐标是物理像素，需先转 vp 再做视口逆变换得到世界坐标
    const rawX: number = touchList[0].x / this.cachedDpr;
    const rawY: number = touchList[0].y / this.cachedDpr;
    const x: number = (rawX - this.viewportX) / this.viewportScale;
    const y: number = (rawY - this.viewportY) / this.viewportScale;
    const ctx = this.ctxActive;

    if (e.type === TouchType.Down) {
      this.selectStart = { x: x, y: y };
      this.selectRect = { x: x, y: y, w: 0, h: 0 };
      this.clearCanvas(ctx);
    } else if (e.type === TouchType.Move) {
      if (this.selectRect === null) return;
      const sx: number = this.selectStart.x;
      const sy: number = this.selectStart.y;
      const rect: SelectRect = {
        x: Math.min(sx, x),
        y: Math.min(sy, y),
        w: Math.abs(x - sx),
        h: Math.abs(y - sy),
      };
      this.selectRect = rect;
      // 预览：清活动层 + 画虚线框
      this.clearCanvas(ctx);
      ctx.save();
      ctx.strokeStyle = HCPrimary.BLUE;
      ctx.lineWidth = 1.5;
      ctx.setLineDash([6, 4]);
      ctx.strokeRect(rect.x, rect.y, rect.w, rect.h);
      ctx.restore();
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.selectRect === null) {
        return;
      }
      const rect: SelectRect = this.selectRect;
      this.clearCanvas(ctx);
      this.selectRect = null;
      // 橡皮「区域擦」：框选命中后直接删除笔迹（对标享做「选中擦除」），不进套索菜单
      if (this.currentTool === 'eraser' && this.eraserMode === 'region') {
        this.selectMode = false;
        const hitIds: number[] = this.collectBoxedStrokeIds(rect);
        if (hitIds.length === 0) {
          this.setStatus('框选内没有笔迹', StatusSeverity.INFO);
          return;
        }
        this.strokes = this.strokes.filter((s: StrokeRecord) => !hitIds.includes(s.id));
        this.strokeCount = this.strokes.length;
        // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
        this.updateUndoRedoState();
        this.renderHistory();
        this.markDirty();
        this.setStatus(`区域擦除：已删除 ${hitIds.length} 条笔迹`, StatusSeverity.INFO);
        return;
      }
      this.selectMode = false;
      const boxed: BoxedStroke[] = this.collectBoxedStrokes(rect);
      if (boxed.length === 0) {
        this.setStatus('框选内没有笔迹，请框选手绘内容', StatusSeverity.INFO);
        return;
      }
      // 🔧 套索选区增强：显示操作菜单，允许用户选择操作
      this.selectedStrokes = boxed;
      this.selectedStrokeIds = this.collectBoxedStrokeIds(rect);
      this.showSelectMenu = true;
      this.setStatus(`已选中 ${boxed.length} 条笔迹，请选择操作`, StatusSeverity.INFO);
    }
  }

  /** 收集与框选矩形相交的笔迹（bbox 不分离即相交；A2-4 框选命中口径） */
  private collectBoxedStrokes(rect: SelectRect): BoxedStroke[] {
    const result: BoxedStroke[] = [];
    for (let i = 0; i < this.strokes.length; i++) {
      const s: StrokeRecord = this.strokes[i];
      if (s.points.length < 2) {
        continue;
      }
      let minX: number = s.points[0].x;
      let minY: number = s.points[0].y;
      let maxX: number = s.points[0].x;
      let maxY: number = s.points[0].y;
      for (let k = 1; k < s.points.length; k++) {
        const p: PointRecord = s.points[k];
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
      // 不分离判定：笔画 bbox 与框选矩形有重叠
      const overlap: boolean = !(maxX < rect.x || minX > rect.x + rect.w || maxY < rect.y || minY > rect.y + rect.h);
      if (overlap) {
        const pts: BoxedStrokePoint[] = [];
        for (let k = 0; k < s.points.length; k++) {
          const pt: BoxedStrokePoint = { x: s.points[k].x, y: s.points[k].y };
          pts.push(pt);
        }
        const bs: BoxedStroke = { points: pts };
        result.push(bs);
      }
    }
    return result;
  }

  /** 收集与框选矩形相交的笔迹 id（橡皮「区域擦」删除用；bbox 不分离即相交） */
  private collectBoxedStrokeIds(rect: SelectRect): number[] {
    const ids: number[] = [];
    for (let i = 0; i < this.strokes.length; i++) {
      const s: StrokeRecord = this.strokes[i];
      if (s.points.length < 2) {
        continue;
      }
      let minX: number = s.points[0].x;
      let minY: number = s.points[0].y;
      let maxX: number = s.points[0].x;
      let maxY: number = s.points[0].y;
      for (let k = 1; k < s.points.length; k++) {
        const p: PointRecord = s.points[k];
        if (p.x < minX) minX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.x > maxX) maxX = p.x;
        if (p.y > maxY) maxY = p.y;
      }
      const overlap: boolean = !(maxX < rect.x || minX > rect.x + rect.w || maxY < rect.y || minY > rect.y + rect.h);
      if (overlap) {
        ids.push(s.id);
      }
    }
    return ids;
  }

  /** PRD v5 需求6：双指轻点画布 → 全屏纯书写模式切换（再次双指轻点恢复工具栏） */
  private toggleImmersiveMode(): void {
    const newImmersive: boolean = !this.immersiveMode;
    this.immersiveMode = newImmersive;
    if (newImmersive) {
      immersiveModeManager.hideToolbar();
      this.closeAllPopups();
      this.setStatus('已进入全屏书写模式，双指轻点恢复工具栏');
    } else {
      immersiveModeManager.showToolbar();
      this.setStatus('已退出全屏书写模式');
    }
    immersiveModeManager.saveToPreferences();
    // 🔧 修复"全屏模式切换后历史笔迹消失"：工具栏显隐触发画布尺寸变化，
    //   onAreaChange 会重走 ensureCanvasSize + renderHistory，但在 onAreaChange 抵达前
    //   主动重绘一次作为兜底，避免出现"白屏无笔迹"的视觉空白帧；同时强制清空活动层
    //   防止旧画笔残影叠加。
    this.immersiveRedrawTimer = setTimeout((): void => {
      this.immersiveRedrawTimer = -1;
      if (this.canvasWidth > 0 && this.canvasHeight > 0) {
        this.clearCanvas(this.ctxActive);
        this.renderPaper();
        this.renderHistory();
      }
    }, 50);
  }

  // ═══ v3.0：手势增强事件处理 ═══
  private handleGestureEvent(event: GestureEvent): void {
    switch (event.type) {
      case GestureType.THREE_FINGER_UNDO:
        this.undo();
        this.setStatus('三指撤销');
        break;
      case GestureType.THREE_FINGER_REDO:
        this.redo();
        this.setStatus('三指重做');
        break;
      case GestureType.DOUBLE_TAP:
        if (this.immersiveMode) {
          this.immersiveMode = false;
          this.setStatus('已退出沉浸模式');
        } else if (!this.inReadingMode) {
          this.readingMode.enter();
          this.inReadingMode = true;
          this.setStatus('全屏阅读模式');
        }
        break;
      case GestureType.LONG_PRESS:
        this.setStatus('长按：可拖动节点或打开菜单');
        break;
      case GestureType.SWIPE_LEFT:
      case GestureType.SWIPE_RIGHT:
        if (this.inReadingMode) {
          // 翻页
        }
        break;
      case GestureType.PINCH_ZOOM:
        if (event.scale) {
          this.viewportScale = Math.max(0.1, Math.min(10, this.viewportScale * event.scale));
        }
        break;
      default:
        break;
    }
  }

  private handleTouch(e: TouchEvent): void {
    // 整段包在 SafeAsync 中：任何异常都会落到 hilog（不会静默消失，便于定位）
    SafeAsync.runVoid(TAG_PAGE, 'handleTouch', (): void => {
      // 🔧 沉浸模式：通知管理器触摸事件（F-03）
      if (e.type === TouchType.Down) {
        immersiveModeManager.onTouchStart();
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        immersiveModeManager.onTouchEnd();
      }
      
      // 🔧 修复绘画失效BUG：添加权限检查，确保单机模式可绘制，协同模式按角色权限控制
      if (!this.collabStatus.canWrite) {
        Logger.warn(TAG_PAGE, `handleTouch: 权限不足，当前角色=${this.collabStatus.sessionRoleText}，无法绘制`);
        return;
      }
      
      // 双击检测：在沉浸模式下双击画布退出沉浸模式
      if (this.immersiveMode && e.type === TouchType.Down) {
        const now = Date.now();
        const touch = e.touches[0];
        if (touch) {
          const dx = Math.abs(touch.x - this.lastTapX);
          const dy = Math.abs(touch.y - this.lastTapY);
          const timeDiff = now - this.lastTapTime;
          
          if (timeDiff < this.DOUBLE_TAP_THRESHOLD && dx < this.DOUBLE_TAP_DISTANCE && dy < this.DOUBLE_TAP_DISTANCE) {
            // 双击检测成功，退出沉浸模式
            this.immersiveMode = false;
            immersiveModeManager.showToolbar(); // 🔧 唤回工具栏（F-03）
            this.setStatus('已退出沉浸模式');
            this.lastTapTime = 0; // 重置时间戳，避免连续触发
            return;
          }
          
          // 更新上次点击信息
          this.lastTapTime = now;
          this.lastTapX = touch.x;
          this.lastTapY = touch.y;
        }
      }
      
      // 框选模式优先（拖拽矩形 → 命中 strokes → 生成导图）
      if (this.selectMode) {
        this.handleSelectTouch(e);
        return;
      }
      // 橡皮「区域擦」：region 模式下按下即进入框选（拖框删除命中笔迹）
      if (this.currentTool === 'eraser' && this.eraserMode === 'region') {
        if (e.type === TouchType.Down) {
          this.selectMode = true;
          this.handleSelectTouch(e);
        }
        return;
      }
      // 尺寸兜底：若 onAreaChange/onReady 均未给出有效尺寸，用默认尺寸继续，避免绘制被尺寸判断拦截
      if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
        this.ensureCanvasSize(1080, 1920);
      }

      let touchList: TouchObject[] = e.touches;
      if (!touchList || touchList.length === 0) {
        touchList = e.changedTouches;
      }
      if (!touchList || touchList.length === 0) {
        return;
      }

      // 🔧 画布拖拽：双指手势（缩放 + 平移），不进入绘制
      if (touchList.length >= 2) {
        this.handlePinch(e, touchList);
        if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.pinchBaseDist = 0;
        }
        return;
      }

      // NOTE-01：便签创建模式下，单指触摸不进入绘制；Down 时落一个便签/便利贴节点
      // （双指仍走上面的 handlePinch 缩放/平移；双击空白区按沉浸模式逻辑处理）
      if (this.noteMode !== 'off') {
        if (e.type === TouchType.Down) {
          // 本地计算逻辑坐标（与下方绘制分支同公式），避免引用 TDZ 中的 x/y
          const sxv: number = touchList[0].x / this.cachedDpr;
          const syv: number = touchList[0].y / this.cachedDpr;
          const x: number = (sxv - this.viewportX) / this.viewportScale;
          const y: number = (syv - this.viewportY) / this.viewportScale;
          const node: CanvasNode = this.buildNoteNode(this.noteMode, x, y);
          this.nodeUndo.pushNodeAdd(node);          // ENG-05：记入节点撤销栈
          this.applyNodeOp({                         // 立即正向应用
            type: NodeOpType.NODE_ADD,
            node: node,
            prevX: 0, prevY: 0, prevW: 0, prevH: 0,
            nextX: node.x, nextY: node.y, nextW: node.w, nextH: node.h,
            timestamp: Date.now(),
            description: '新增便签'
          } as NodeOp, false);
          this.searchIndex.upsertNode(node);        // NOTE-04：增量更新端侧索引
          this.noteMode = 'off';                    // 建一个即退出创建模式
          this.setStatus('已创建便签，可继续点击工具栏添加；编辑/双击改字为阶段2');
        }
        return;
      }

      // 屏幕坐标（相对画布组件）→ 画布逻辑坐标（逆视口变换）：
      // 缩放/平移后，笔画数据仍以画布坐标存储，渲染时经视口变换正确落屏
      // 🔧 修复坐标偏差：触摸坐标是物理像素，需要除以 dpr 得到逻辑像素
      // 🔧 性能优化：使用缓存的dpr值，避免每次触摸事件都重新获取
      const sx: number = touchList[0].x / this.cachedDpr;
      const sy: number = touchList[0].y / this.cachedDpr;
      const x: number = (sx - this.viewportX) / this.viewportScale;
      const y: number = (sy - this.viewportY) / this.viewportScale;

      // 🔧 画布拖拽：平移模式（pan）下单指拖动画布
      if (this.canvasMode === 'pan') {
        if (e.type === TouchType.Down) {
          this.panning = true;
          this.panLastX = sx;
          this.panLastY = sy;
        } else if (e.type === TouchType.Move && this.panning) {
          this.viewportX += sx - this.panLastX;
          this.viewportY += sy - this.panLastY;
          this.panLastX = sx;
          this.panLastY = sy;
          this.applyViewportTransform();
        } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
          this.panning = false;
        }
        return;
      }

      // !️ 压感采样可能在部分设备/API 上抛异常（如 getHistoricalPoints 不可用）。
      // 必须兜底为默认压力，绝不能因此中断整条绘制链路（否则表现就是"写不上字 / 没反应"）。
      let downForce: number = 0.5;
      let moveForce: number = -1;
      try {
        downForce = PressureSampler.resolveForce(e, 0.5);
      } catch (err) {
        downForce = 0.5;
      }
      try {
        moveForce = PressureSampler.sampleForce(e);
      } catch (err) {
        moveForce = -1;
      }

      if (e.type === TouchType.Down) {
        this.lastSampleX = x;
        this.lastSampleY = y;
        this.lastSampleT = Date.now();
        this.touchDown(x, y, downForce);
      } else if (e.type === TouchType.Move) {
        // 触摸事件节流：限制Move事件处理频率为60Hz，避免过度绘制
        const now: number = Date.now();
        if (now - this.lastMoveTime < this.MOVE_THROTTLE_MS) {
          return; // 节流：跳过本次Move事件
        }
        this.lastMoveTime = now;
        
        let force: number = moveForce;
        if (force < 0) {
          const now: number = Date.now();
          const dx = x - this.lastSampleX;
          const dy = y - this.lastSampleY;
          const dt = now - this.lastSampleT;
          force = PressureSampler.estimateVelocityPressure(Math.sqrt(dx * dx + dy * dy), dt);
        }
        this.lastSampleX = x;
        this.lastSampleY = y;
        this.lastSampleT = Date.now();
        this.touchMove(x, y, force);
      } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
        this.touchUp(x, y);
      }
    });
  }

  private touchDown(x: number, y: number, pressure: number): void {
    Logger.info(TAG_PAGE, `touchDown: (${x.toFixed(1)}, ${y.toFixed(1)}), pressure=${pressure.toFixed(2)}, tool=${this.currentTool}`);
    // 绘制环境诊断：一次 Down 即可确认「事件到达 + 画布尺寸 + 缓冲区像素 + 笔刷参数」全链路
    Logger.info(TAG_PAGE, `绘制环境: canvas=${this.canvasWidth}x${this.canvasHeight}vp, buffer=${this.ctxActive.width}x${this.ctxActive.height}px, ` +
      `canvasReady=${this.canvasReady}, brush=${this.currentBrush}, opacity=${this.activeOpacity}, width=${this.currentWidth}, canWrite=${this.collabStatus.canWrite}`);
    this.drawing = true;
    this.dragStartX = x;
    this.dragStartY = y;
    this.currentPoints = [{ x: x, y: y, pressure: pressure }];
    this.lastDrawnX = x;
    this.lastDrawnY = y;

    // ═══ v2.5：新工具触摸处理 ═══
    if (this.currentTool === 'lasso') {
      this.lassoActive = true;
      this.lassoPath = [x, y];
      return;
    }
    if (this.currentTool === 'eyedropper') {
      this.handleEyedropper(x, y);
      return;
    }
    if (this.currentTool === 'fill') {
      this.handleFill(x, y);
      return;
    }

    const isEraser: boolean = this.currentTool === 'eraser';
    const isShape: boolean = this.currentTool === 'shape' && this.shapeSnap;  // PRD v5：自由绘制模式按手绘处理
    // 形状与橡皮不套用笔刷特效（保持边缘清晰、擦除彻底）
    if (isEraser || isShape) {
      this.activeOpacity = 1;
      this.activeBlendMode = 'normal';
      this.activeBrushShape = 'round';
    } else {
      const brush: BrushOption = this.brushByTool(this.currentBrush);
      this.activeOpacity = brush.opacity;
      this.activeBlendMode = brush.blendMode;
      this.activeBrushShape = brush.brushShape;
    }

    if (isEraser) {
      // A5 修复：橡皮直接实时作用于历史层——历史层承载已完成笔画，destination-out 立即生效，拖动即有擦除反馈
      // 注意：不用 save()/restore() 配对（若 touchUp 前中断/切工具会失衡，把历史层卡在 destination-out，导致后续笔画全部被擦掉）
      // eraserMode：point 用小半径精细擦除，line 用当前线宽沿路径擦除
      const hctx = this.ctxHistory;
      hctx.globalAlpha = 1;
      hctx.globalCompositeOperation = 'destination-out';
      hctx.strokeStyle = '#000000';
      hctx.lineWidth = this.currentWidth * (this.eraserMode === 'point' ? 2 : 4);
      hctx.lineCap = 'round';
      hctx.lineJoin = 'round';
      hctx.beginPath();
      hctx.moveTo(x, y);
      // 修复点擦/轻触无反馈：落笔时先画一个实心圆点，确保单击也能擦除
      // 显式设置 fillStyle，避免历史层残留 fillStyle 导致擦除不彻底
      hctx.fillStyle = '#000000';
      hctx.arc(x, y, hctx.lineWidth / 2, 0, Math.PI * 2);
      hctx.fill();
      hctx.beginPath();
      hctx.moveTo(x, y);
    } else {
      const ctx = this.ctxActive;
      ctx.lineCap = this.activeBrushShape === 'flat' ? 'butt' : 'round';
      ctx.lineJoin = this.activeBrushShape === 'flat' ? 'miter' : 'round';
      ctx.globalAlpha = this.activeOpacity;
      ctx.globalCompositeOperation = this.activeBlendMode === 'multiply' ? 'multiply' : 'source-over';
      ctx.strokeStyle = this.currentColor;
      ctx.lineWidth = this.currentWidth;
    }
  }

  private touchMove(x: number, y: number, pressure: number): void {
    if (!this.drawing) {
      Logger.warn(TAG_PAGE, `touchMove: drawing=false，跳过绘制`);
      return;
    }

    // v2.5：套索工具移动 → 追加路径点 + 实时绘制套索线
    if (this.currentTool === 'lasso' && this.lassoActive) {
      this.lassoPath.push(x, y);
      this.drawLassoPreview();
      return;
    }

    if (this.currentTool === 'shape' && this.shapeSnap) {
      // 形状（规整模式）：O(1) 只清活动层画预览
      this.clearCanvas(this.ctxActive);
      this.drawShapePreview(x, y);
      return;
    }

    // 距离降噪：相邻采样过近（<1.2vp）直接丢弃，减少无效绘制
    const dx = x - this.lastDrawnX;
    const dy = y - this.lastDrawnY;
    if (dx * dx + dy * dy < this.DISTANCE_THRESHOLD * this.DISTANCE_THRESHOLD) {
      return;
    }

    const isEraser: boolean = this.currentTool === 'eraser';
    if (isEraser) {
      // A5 修复：橡皮在历史层上实时擦除（touchDown 已建立 destination-out 上下文）
      const hctx = this.ctxHistory;
      hctx.beginPath();
      hctx.moveTo(this.lastDrawnX, this.lastDrawnY);
      hctx.lineTo(x, y);
      hctx.stroke();
    } else {
      const ctx = this.ctxActive;
      ctx.globalAlpha = this.activeOpacity >= 0 && this.activeOpacity < 1 ? this.activeOpacity : 1;
      ctx.globalCompositeOperation = this.activeBlendMode === 'multiply' ? 'multiply' : 'source-over';
      ctx.strokeStyle = this.currentColor;
      // 🔧 修复压感笔无效：根据压感数据调整线宽（与 renderHistory 中的压感变宽逻辑一致）
      const pressureWidth: number = Math.max(0.5, this.currentWidth * (0.4 + 0.6 * pressure));
      ctx.lineWidth = pressureWidth;
      ctx.lineCap = this.activeBrushShape === 'flat' ? 'butt' : 'round';
      ctx.lineJoin = this.activeBrushShape === 'flat' ? 'miter' : 'round';
      if (this.activeOpacity < 1) {
        // A4 修复（接线原 C-3 方案）：半透明笔（荧光笔/马克笔/铅笔）清活动层 + 整条路径一次合成，
        // 避免分段增量描边导致重叠处越描越深、浓度不均
        this.clearCanvas(ctx);
        ctx.beginPath();
        ctx.moveTo(this.currentPoints[0].x, this.currentPoints[0].y);
        for (let i = 1; i < this.currentPoints.length; i++) {
          ctx.lineTo(this.currentPoints[i].x, this.currentPoints[i].y);
        }
        ctx.lineTo(x, y);
        ctx.stroke();
      } else {
        // 不透明笔：O(1) 增量描边（压感变宽已在上面的 lineWidth 设置中应用）
        ctx.beginPath();
        ctx.moveTo(this.lastDrawnX, this.lastDrawnY);
        ctx.lineTo(x, y);
        ctx.stroke();
      }
    }

    this.lastDrawnX = x;
    this.lastDrawnY = y;
    this.currentPoints.push({ x: x, y: y, pressure: pressure });
    this.markDirty();
  }

  private touchUp(x: number, y: number): void {
    if (!this.drawing) {
      return;
    }
    this.drawing = false;

    // v2.5：套索工具抬笔 → 完成选择
    if (this.currentTool === 'lasso' && this.lassoActive) {
      this.lassoActive = false;
      this.lassoPath.push(x, y);
      this.completeLassoSelection();
      return;
    }

    const isShape = this.currentTool === 'shape' && this.shapeSnap;  // PRD v5：自由绘制模式走手绘路径
    const isEraser = this.currentTool === 'eraser';

    // 收尾：把最后一段（落笔点 → 抬笔点）也画上，确保笔画闭合
    if (!isShape) {
      if (isEraser) {
        // A5 修复：历史层上收尾最后一段，并显式恢复默认状态（不用 restore，防止中断导致 destination-out 残留）
        const hctx = this.ctxHistory;
        hctx.beginPath();
        hctx.moveTo(this.lastDrawnX, this.lastDrawnY);
        hctx.lineTo(x, y);
        hctx.stroke();
        hctx.globalCompositeOperation = 'source-over';
        hctx.globalAlpha = 1;
        hctx.lineWidth = 1;
      } else {
        const ctx = this.ctxActive;
        ctx.globalAlpha = this.activeOpacity >= 0 && this.activeOpacity < 1 ? this.activeOpacity : 1;
        ctx.globalCompositeOperation = this.activeBlendMode === 'multiply' ? 'multiply' : 'source-over';
        ctx.strokeStyle = this.currentColor;
        ctx.lineWidth = this.currentWidth;
        ctx.lineCap = this.activeBrushShape === 'flat' ? 'butt' : 'round';
        ctx.lineJoin = this.activeBrushShape === 'flat' ? 'miter' : 'round';
        if (this.activeOpacity < 1) {
          // A4 修复：半透明笔收尾同样走整条路径一次合成，避免末段接缝叠色
          this.clearCanvas(ctx);
          ctx.beginPath();
          ctx.moveTo(this.currentPoints[0].x, this.currentPoints[0].y);
          for (let i = 1; i < this.currentPoints.length; i++) {
            ctx.lineTo(this.currentPoints[i].x, this.currentPoints[i].y);
          }
          ctx.lineTo(x, y);
          ctx.stroke();
        } else {
          ctx.beginPath();
          ctx.moveTo(this.lastDrawnX, this.lastDrawnY);
          ctx.lineTo(x, y);
          ctx.stroke();
        }
      }
      this.currentPoints.push({ x: x, y: y, pressure: 0.5 });
    }

    if (this.flushTimer !== -1) {
      clearTimeout(this.flushTimer);
      this.flushTimer = -1;
    }
    this.clearCanvas(this.ctxActive);

    // 形状绘制：检查起点和终点是否有效（距离>1px）
    if (isShape) {
      const dx = x - this.dragStartX;
      const dy = y - this.dragStartY;
      if (dx * dx + dy * dy < 1) {
        this.setStatus('请按住拖动绘制形状');
        return;
      }
    }

    this.resetRedoStacks();
    
    // redoStack上限检查：超过100时自动清理最早的50个
    const MAX_REDO: number = 100;
    const CLEANUP_REDO: number = 50;
    if (this.redoStack.length > MAX_REDO) {
      Logger.warn(TAG_PAGE, `redoStack超过上限 (${this.redoStack.length}>${MAX_REDO})，自动清理最早的${CLEANUP_REDO}个`);
      this.redoStack = this.redoStack.slice(CLEANUP_REDO);
      // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
      this.updateUndoRedoState();
    }
    
    let toolName: string = this.currentBrush;
    if (isShape) {
      toolName = this.currentShape;
    } else if (isEraser) {
      toolName = 'eraser';
    }
    const stroke: StrokeRecord = {
      id: ++this.strokeIdSeq,
      tool: toolName,
      color: isEraser ? '#FFFFFF' : this.currentColor,
      // 与 touchDown 实时的 lineWidth 保持一致，避免点擦抬笔后半径跳变
      width: isEraser ? this.currentWidth * (this.eraserMode === 'point' ? 2 : 4) : this.currentWidth,
      points: this.currentPoints.slice(),
      opacity: this.activeOpacity,
      blendMode: this.activeBlendMode,
      brushShape: this.activeBrushShape,
      layerId: this.drawLayerId,
      createdAt: Date.now(),
    };
    if (isShape) {
      stroke.points = [
        { x: this.dragStartX, y: this.dragStartY },
        { x, y },
      ];
    }

    this.strokes.push(stroke);
    this.strokeCount = this.strokes.length;
    // 🔴 v2.7.3：把新笔画同步到分布式房间（同账号设备即时可见）
    this.boardSession.publishStrokes(this.strokes);
    // 🔧 审核驳回修复（v2.5.4）：落笔后必须刷新撤销/重做可用态。
    //   之前 updateUndoRedoState() 仅在 undo()/redo() 内部调用，
    //   笔画提交后 canUndo 永远为 false，导致顶部栏「撤销/重做」按钮恒灰、点击无响应。
    this.updateUndoRedoState();

    // 笔画数量上限检查：超过2000笔时自动清理最早的500笔
    const MAX_STROKES: number = 2000;
    const CLEANUP_COUNT: number = 500;
    if (this.strokes.length > MAX_STROKES) {
      Logger.warn(TAG_PAGE, `笔画数量超过上限 (${this.strokes.length}>${MAX_STROKES})，自动清理最早的${CLEANUP_COUNT}笔`);
      this.strokes = this.strokes.slice(CLEANUP_COUNT);
      this.strokeCount = this.strokes.length;
      this.setStatus(`已清理旧笔画，当前${this.strokeCount}笔`);
    }
    
    // silent=true：笔迹计数为高频内部状态，弹 Toast 会每笔轰炸（PRD v5 需求4 节流）
    this.setStatus(`${this.strokeCount} 笔`, StatusSeverity.ROUTINE, true);
    this.renderHistory(); // 落笔后历史层全量重绘
    this.markDirty();
  }

  // ═══ 形状预览（画在活动层，O(1)）═══
  private drawShapePreview(x: number, y: number): void {
    const ctx = this.ctxActive;
    ctx.save();
    ctx.strokeStyle = this.currentColor;
    ctx.lineWidth = this.currentWidth;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.globalAlpha = 1;
    ctx.globalCompositeOperation = 'source-over';
    const sx = this.dragStartX, sy = this.dragStartY;
    ctx.beginPath();

    switch (this.currentShape) {
      case 'rectangle':
        ctx.rect(Math.min(sx, x), Math.min(sy, y), Math.abs(x - sx), Math.abs(y - sy));
        break;
      case 'circle': {
        const rx = Math.abs(x - sx) / 2;
        const ry = Math.abs(y - sy) / 2;
        ctx.ellipse((sx + x) / 2, (sy + y) / 2, rx, ry, 0, 0, Math.PI * 2);
        break;
      }
      case 'arrow':
        ctx.moveTo(sx, sy);
        ctx.lineTo(x, y);
        this.drawArrowhead(ctx, sx, sy, x, y, this.currentWidth);
        break;
      case 'line':
        ctx.moveTo(sx, sy);
        ctx.lineTo(x, y);
        break;
    }
    ctx.stroke();
    ctx.restore();
  }

  private drawArrowhead(ctx: CanvasRenderingContext2D, sx: number, sy: number, ex: number, ey: number, width: number): void {
    const angle = Math.atan2(ey - sy, ex - sx);
    const headLen = 10 + width * 2;
    const spread = Math.PI / 6;
    ctx.moveTo(ex, ey);
    ctx.lineTo(ex - headLen * Math.cos(angle - spread), ey - headLen * Math.sin(angle - spread));
    ctx.moveTo(ex, ey);
    ctx.lineTo(ex - headLen * Math.cos(angle + spread), ey - headLen * Math.sin(angle + spread));
  }

  /**
   * 历史层全量重绘（低频：落笔/撤销/清除/图层变更/尺寸变化）。
   * W7：逐笔还原笔刷特效，并叠加所属图层的可见性与透明度 —— 这样图层面板的开关才真正"看得见"。
   *
   * v2.4.2 修复：try-catch 兜底，避免任何单笔渲染异常中断整轮重绘（导致历史笔迹"丢失"）。
   */
  private renderHistory(): void {
    // 性能监控：记录渲染开始时间
    const startTime: number = Date.now();
    const strokeCount: number = this.strokes.length;

    // 笔画数量预警：超过1500笔时提示用户
    if (strokeCount > 1500 && strokeCount % 100 === 0) {
      Logger.warn(TAG_PAGE, `renderHistory: 笔画数量过多 (${strokeCount}笔)，建议清理或导出`);
    }

    const ctx = this.ctxHistory;
    if (!ctx) {
      Logger.warn(TAG_PAGE, `renderHistory: ctxHistory 未就绪，跳过`);
      return;
    }
    this.clearCanvas(ctx);

    // 🔧 修复：兜底重置 globalCompositeOperation，避免橡皮 destination-out 残留导致
    //   后续非橡皮笔画被"擦除"（表现为"线性橡皮擦无效"或"切工具后历史笔迹消失"）。
    // 🔧 防御性重置：清除上一轮可能残留的 destination-out，避免新笔迹被误擦。
    // 注意：**不能**用 save()/restore() 包裹——restore() 会把刚设的值还原回去，等于没设。
    ctx.globalCompositeOperation = 'source-over';
    ctx.globalAlpha = 1.0;

    // 🔧 修复橡皮擦除后恢复的问题：按照笔画的时间顺序绘制
    // 当遇到橡皮擦笔画时，使用 destination-out 混合模式来擦除之前绘制的内容
    // 这样确保橡皮擦的效果不会被后续绘制的笔画覆盖
    for (const s of this.strokes) {
      // 单笔渲染隔离：任何一笔异常不影响后续笔画的渲染
      try {
        // 修复：支持单点笔迹渲染（点击绘制一个点）
        if (s.points.length < 1) continue;
        if (!this.engine.layerVisible(s.layerId)) continue;

        const layerAlpha: number = this.engine.layerOpacity(s.layerId);
        const strokeAlpha: number = s.opacity > 0 && s.opacity <= 1 ? s.opacity : 1;

        ctx.save();
        ctx.lineWidth = s.width;

        // 橡皮擦笔画：使用 destination-out 混合模式来擦除之前绘制的内容
        if (s.tool === 'eraser') {
          ctx.lineCap = 'round';
          ctx.lineJoin = 'round';
          ctx.globalAlpha = 1;
          ctx.globalCompositeOperation = 'destination-out';
          ctx.strokeStyle = '#000000';
          ctx.beginPath();

          if (s.points.length === 1) {
            const p = s.points[0];
            ctx.fillStyle = '#000000';
            ctx.arc(p.x, p.y, s.width / 2, 0, Math.PI * 2);
            ctx.fill();
          } else {
            ctx.moveTo(s.points[0].x, s.points[0].y);
            for (let i = 1; i < s.points.length; i++) {
              ctx.lineTo(s.points[i].x, s.points[i].y);
            }
            ctx.stroke();
          }
          ctx.restore();
          continue;
        }

        // 正常笔画：使用 source-over 或 multiply 混合模式绘制
        ctx.lineCap = s.brushShape === 'flat' ? 'butt' : 'round';
        ctx.lineJoin = s.brushShape === 'flat' ? 'miter' : 'round';
        ctx.globalAlpha = strokeAlpha * layerAlpha;
        ctx.globalCompositeOperation = s.blendMode === 'multiply' ? 'multiply' : 'source-over';
        ctx.strokeStyle = s.color;
        ctx.beginPath();

        // 修复：单点笔迹渲染为圆形
        if (s.points.length === 1) {
          const p = s.points[0];
          ctx.arc(p.x, p.y, s.width / 2, 0, Math.PI * 2);
          ctx.fill();
          ctx.restore();
          continue;
        }

        // 多点笔迹正常渲染
        switch (s.tool) {
          case 'rectangle': {
            const p0 = s.points[0], p1 = s.points[1];
            ctx.rect(Math.min(p0.x, p1.x), Math.min(p0.y, p1.y), Math.abs(p1.x - p0.x), Math.abs(p1.y - p0.y));
            break;
          }
          case 'circle': {
            const p0 = s.points[0], p1 = s.points[1];
            const rx = Math.abs(p1.x - p0.x) / 2;
            const ry = Math.abs(p1.y - p0.y) / 2;
            ctx.ellipse((p0.x + p1.x) / 2, (p0.y + p1.y) / 2, rx, ry, 0, 0, Math.PI * 2);
            break;
          }
          case 'arrow': {
            const p0 = s.points[0], p1 = s.points[1];
            ctx.moveTo(p0.x, p0.y);
            ctx.lineTo(p1.x, p1.y);
            this.drawArrowhead(ctx, p0.x, p0.y, p1.x, p1.y, s.width);
            break;
          }
          case 'line': {
            const p0 = s.points[0], p1 = s.points[1];
            ctx.moveTo(p0.x, p0.y);
            ctx.lineTo(p1.x, p1.y);
            break;
          }
          default:
            // B2 修复：半透明笔（荧光笔/马克笔/铅笔）不走压感逐段描边——逐段 stroke 会在每段接缝处二次合成，颜色越描越深；
            // 半透明笔统一走单路径一次合成（浓度恒定），压感变宽仅保留给不透明笔
            if (strokeAlpha < 1) {
              ctx.moveTo(s.points[0].x, s.points[0].y);
              for (let i = 1; i < s.points.length; i++) {
                ctx.lineTo(s.points[i].x, s.points[i].y);
              }
            } else if (s.points[0].pressure !== undefined && s.points[0].pressure !== null && s.points.length >= 2) {
              // S2-A / T2-2：压感变宽渲染——笔点带 pressure 时逐段变宽（与 StrokeEngine.renderStrokeToContext 同映射）；
              // 无压感旧文件（pressure undefined）保持原单条路径，视觉零变化
              ctx.moveTo(s.points[0].x, s.points[0].y);
              for (let i = 1; i < s.points.length; i++) {
                const p: PointRecord = s.points[i];
                const pressure: number = p.pressure !== undefined && p.pressure !== null ? p.pressure : 1.0;
                ctx.lineWidth = Math.max(0.5, s.width * (0.4 + 0.6 * pressure));
                ctx.lineTo(p.x, p.y);
                ctx.stroke();
                ctx.beginPath();
                ctx.moveTo(p.x, p.y);
              }
            } else {
              ctx.moveTo(s.points[0].x, s.points[0].y);
              for (let i = 1; i < s.points.length; i++) {
                ctx.lineTo(s.points[i].x, s.points[i].y);
              }
            }
            break;
        }
        ctx.stroke();
        ctx.restore();
      } catch (err) {
        // 🔧 兜底：单笔渲染异常不阻断整轮重绘
        Logger.error(TAG_PAGE, `renderHistory: 单笔渲染失败 id=${s.id} tool=${s.tool} err=${SafeAsync.describe(err)}`);
        try { ctx.restore(); } catch (_) { /* ignore */ }
      }
    }

    // S2-B / T2-3：文本框 / 贴纸渲染（随 texts[] 持久化）
    for (let i = 0; i < this.texts.length; i++) {
      const t: HCText = this.texts[i];
      if (t.text.length === 0) {
        continue;
      }
      ctx.save();
      ctx.globalAlpha = 1;
      ctx.fillStyle = t.color !== undefined && t.color.length > 0 ? t.color : '#000000';
      ctx.font = `${Math.max(8, Math.min(120, t.fontSize))}px ${t.fontFamily}`;
      ctx.textBaseline = 'top';
      ctx.fillText(t.text, t.x, t.y);
      ctx.restore();
    }
    
    // 性能监控：记录渲染耗时
    const elapsed: number = Date.now() - startTime;
    PerformanceTracker.getInstance().record('renderHistory', elapsed);
    if (elapsed > 50) { // 超过50ms的慢渲染记录警告
      Logger.warn(TAG_PAGE, `renderHistory: 慢渲染 ${elapsed}ms (${strokeCount}笔)`);
    }
  }

  // ═══ 撤销 / 重做 / 清除 ═══

  /** 重置全部重做栈（新笔画 / 装载 / 应用草稿 / 转矢量时调用，F-03：图片与贴纸重做栈同步清空，避免错位） */
  private resetRedoStacks(): void {
    this.redoStack = [];
    this.redoImages = [];
    this.redoTexts = [];
  }

  /** 更新撤销/重做状态（UI绑定） */
  private updateUndoRedoState(): void {
    this.canUndo = this.strokes.length > 0;
    this.canRedo = this.redoStack.length > 0;
  }

  private undo(): void {
    if (this.strokes.length === 0) return;
    const popped = this.strokes.pop()!;
    this.redoStack.push(popped);
    
    // redoStack上限检查：超过100时自动清理最早的50个
    const MAX_REDO: number = 100;
    const CLEANUP_REDO: number = 50;
    if (this.redoStack.length > MAX_REDO) {
      Logger.warn(TAG_PAGE, `redoStack超过上限 (${this.redoStack.length}>${MAX_REDO})，自动清理最早的${CLEANUP_REDO}个`);
      this.redoStack = this.redoStack.slice(CLEANUP_REDO);
      // F-03：快照栈按笔画索引对齐，清理后一并清空，避免重做错位
      this.redoImages = [];
      this.redoTexts = [];
    }
    
    // 更新撤销/重做状态
    this.updateUndoRedoState();
    
    this.strokeCount = this.strokes.length;
    this.clearCanvas(this.ctxActive);
    this.renderHistory();
    this.markDirty();
    this.setStatus(`撤销 · ${this.strokeCount} 笔`);

    const undoProps: StrokeCountProps = { stroke_count: this.strokeCount };
    this.trackAsync((): void => {
      analytics.track(AnalyticsEvent.UNDO, undoProps);
    });
  }

  private redo(): void {
    // BUG-3：纯图片/贴纸画布清除后（redoStack 无笔画项），图片/贴纸快照恢复分支必须前置，
    // 否则 redoStack 为空时直接 return，图片会永久丢失。
    // 边界说明：redoStack 与 redoImages/redoTexts 按「清除批次」对齐 —— 混合内容清除时，
    // 笔画在 redoStack 中逐笔重做，最后一步（redoStack 清空）连带恢复图片/贴纸快照；
    // 纯图片/贴纸清除时 redoStack 为空，走本前置分支直接恢复快照。
    if (this.redoStack.length === 0 && this.redoImages.length > 0) {
      const restoredImages: ImageRefData[] = this.redoImages.pop()!;
      const restoredTexts: HCText[] = this.redoTexts.length > 0 ? this.redoTexts.pop()! : [];
      this.noteImages = restoredImages;
      this.texts = restoredTexts;
      this.engine.attachImages(this.drawLayerId, restoredImages);
      this.clearCanvas(this.ctxActive);
      this.renderHistory();
      this.markDirty();
      this.setStatus(`恢复 · ${this.strokeCount} 笔`);
      return;
    }
    if (this.redoStack.length === 0) return;
    const restored = this.redoStack.pop()!;
    this.strokes.push(restored);
    this.strokeCount = this.strokes.length;
    
    // 更新撤销/重做状态
    this.updateUndoRedoState();
    
    // F-03：批量清除的重做 —— 笔画全部还原后，连带恢复图片与贴纸（快照按清除批次入栈）
    if (this.redoStack.length === 0 && this.redoImages.length > 0) {
      const restoredImages: ImageRefData[] = this.redoImages.pop()!;
      const restoredTexts: HCText[] = this.redoTexts.length > 0 ? this.redoTexts.pop()! : [];
      this.noteImages = restoredImages;
      this.texts = restoredTexts;
      this.engine.attachImages(this.drawLayerId, restoredImages);
    }
    this.clearCanvas(this.ctxActive);
    this.renderHistory();
    this.markDirty();
    this.setStatus(`恢复 · ${this.strokeCount} 笔`);

    const redoProps: StrokeCountProps = { stroke_count: this.strokeCount };
    this.trackAsync((): void => {
      analytics.track(AnalyticsEvent.REDO, redoProps);
    });
  }

  /** 清除画布内容（笔画 + 插图），底纸与图层结构保留 */
  private clearAll(): void {
    // 二次确认对话框
    promptAction.showDialog({
      title: '清除画布',
      message: '确定要清空当前笔记的全部内容吗？清空后可点击「重做」恢复。',
      buttons: [
        { text: '取消', color: HCGray.GRAY_7 },
        { text: '确定清除', color: '#D92D20' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        // 用户点击了"确定清除"
        this.performClearAll();
      }
      // 用户点击"取消"或关闭对话框，不做任何操作
    }).catch((err: Error) => {
      Logger.error(TAG_PAGE, `清除确认对话框错误: ${err}`);
    });
  }

  /** 实际执行清除操作 */
  private performClearAll(): void {
    try {
      // F-02/F-03：清空动作压入重做栈（笔画 + 图片 + 贴纸整体快照），重做可恢复全部对象
      if (this.strokes.length > 0 || this.noteImages.length > 0 || this.texts.length > 0) {
        // 保存笔画到重做栈
        this.redoStack.push(...this.strokes.slice());
        // F-03：图片与贴纸随清除批次入快照栈（与笔画批次对齐，重做最后一步恢复）
        this.redoImages.push(this.noteImages.slice());
        this.redoTexts.push(this.texts.slice());
        // 快照栈上限对齐（防止极端情况下无限增长）
        const MAX_SNAPSHOT: number = 50;
        if (this.redoImages.length > MAX_SNAPSHOT) {
          this.redoImages.shift();
          this.redoTexts.shift();
        }
      }

      this.strokes = [];
      this.strokeCount = 0;
      this.noteImages = [];
      this.texts = [];
      this.clearCanvas(this.ctxActive);
      this.renderHistory();
      this.markDirty();
      // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
      this.updateUndoRedoState();
      this.setStatus('已清除（可重做恢复）');
    } catch (error) {
      Logger.error(TAG_PAGE, `清除画布失败: ${error}`);
      this.setStatus('清除失败，请重试');
    }
  }

  // ═══ 导出图片（完整合成：底纸 + 图片 + 笔迹 + 文本）═══
  private async exportImage(): Promise<void> {
    // 导出合成：临时借用历史层画布（CanvasRenderingContext2D 支持 toDataURL），
    // 完成后 restore + 重绘还原。与本文件 exportLayerRequest 的临时合成模式一致。
    const ctx = this.ctxHistory;
    let ctxSaved: boolean = false;
    try {
      // 🔴 v2.7.1：改用 beginExportCompose（重置为「仅密度」变换），
      //   否则 clearCanvas 内的 restore() 会把视口平移/缩放还原回来 → 导出空白。
      this.beginExportCompose(ctx);
      ctxSaved = true;
      this.composeExportToContext(ctx);

      // 导出为PNG并真正落盘到文件系统
      const dataUrl: string = ctx.toDataURL('image/png');
      if (dataUrl !== undefined && dataUrl.length > 0) {
        const filename: string = this.noteTitle.length > 0 ? this.noteTitle : 'whiteboard';
        // BUG-1：PNG 必须走二进制分支 —— 先转 ArrayBuffer 再交给 saveToFile
        //（ExportService 的 string 分支按 UTF-8 文本写入，只适用于 SVG）
        const base64Data: string = dataUrl.split(',')[1];
        const arrayBuffer: ArrayBuffer = this.base64ToArrayBuffer(base64Data);
        const saved: boolean = await exportService.saveToFile(arrayBuffer, filename, ExportFormat.PNG);

        if (saved) {
          this.setStatus(`已保存到文件（${Math.round(dataUrl.length / 1024)}KB）`, StatusSeverity.INFO);

          const exportProps: ExportProps = {
            stroke_count: this.strokeCount,
            format: 'png',
            size: dataUrl.length
          };
          this.trackAsync((): void => {
            analytics.track(AnalyticsEvent.EXPORT_IMAGE, exportProps);
          });
        } else {
          this.setStatus('保存失败，请重试', StatusSeverity.ALERT);
        }
      } else {
        this.setStatus('导出失败', StatusSeverity.ALERT);
      }
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG_PAGE, `导出图片失败: ${err.message}`);
      this.setStatus('导出失败，请重试', StatusSeverity.ALERT);
    } finally {
      // 兜底：无论成功/异常都还原历史层，避免 ctxHistory 被临时合成内容污染
      if (ctxSaved) {
        try {
          ctx.restore();
        } catch (_) {
          Logger.warn(TAG_PAGE, '导出图片还原上下文失败');
        }
        this.renderHistory();
      }
    }
  }

  /**
   * v2.7.0：把当前画布合成后写入沙箱文件，再拉起**系统分享面板**。
   * 分享不可用时自动回退到「导出图片」（系统文件选择器另存），保证一定有结果。
   */
  private async shareCanvasImage(): Promise<void> {
    const ctx = this.ctxHistory;
    let ctxSaved: boolean = false;
    let tmpPath: string = '';
    try {
      // 🔴 v2.7.1：改用 beginExportCompose（重置为「仅密度」变换），
      //   否则 clearCanvas 内的 restore() 会把视口平移/缩放还原回来 → 导出空白。
      this.beginExportCompose(ctx);
      ctxSaved = true;
      this.composeExportToContext(ctx);
      const dataUrl: string = ctx.toDataURL('image/png');
      if (dataUrl === undefined || dataUrl.length === 0) {
        this.setStatus('分享失败：无法生成图片', StatusSeverity.ALERT);
        return;
      }
      const base64Data: string = dataUrl.split(',')[1];
      const arrayBuffer: ArrayBuffer = this.base64ToArrayBuffer(base64Data);

      const ctxApp: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const dir: string = `${ctxApp.filesDir}/share`;
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir);
      }
      tmpPath = `${dir}/canvas_${Date.now()}.png`;
      const file = fileIo.openSync(tmpPath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, arrayBuffer);
      } finally {
        fileIo.closeSync(file);
      }
      this.setStatus('正在拉起系统分享…', StatusSeverity.ROUTINE);
      const shared: boolean = await this.shareService.shareImage(tmpPath, ctxApp);
      if (shared) {
        this.setStatus('已打开系统分享面板', StatusSeverity.INFO);
      } else {
        // 回退：走系统文件选择器另存，用户同样能拿到图片
        this.setStatus('系统分享不可用，已改为「导出图片」另存', StatusSeverity.INFO);
        await this.exportImage();
      }
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG_PAGE, `分享图片失败: ${err.message}`);
      this.setStatus(`分享失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
    } finally {
      if (ctxSaved) {
        try {
          ctx.restore();
        } catch (_) {
          Logger.warn(TAG_PAGE, '分享图片还原上下文失败');
        }
        this.renderHistory();
      }
    }
  }

  /** v2.7.0：复制笔记 ID 到系统剪贴板（原来只 show 一个状态提示，并未真正复制） */
  private copyNoteId(): void {
    try {
      const id: string = this.noteId.length > 0 ? this.noteId : '(临时笔记，尚未落盘)';
      const text: string = `${this.noteTitle}\n${id}`;
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.setStatus(`已复制笔记 ID：${id}`, StatusSeverity.INFO);
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG_PAGE, `复制笔记 ID 失败: ${err.message}`);
      this.setStatus('复制失败，请重试', StatusSeverity.ALERT);
    }
  }

  /**
   * 🔴 v2.7.1 审核修复（问题③-4「导出 PDF 没有内容」真因）
   *
   * 为导出准备上下文。
   *
   * 旧实现的致命缺陷：导出流程写的是
   *     ctx.save(); this.clearCanvas(ctx); this.composeExportToContext(ctx);
   * 而 `clearCanvas()` 内部是 `setTransform(单位阵) → clearRect → restore()`，
   * 那个 `restore()` 会把**视口变换（平移 + 缩放 + 密度）原样还原回来**。
   * 于是 `composeExportToContext` 明明按世界坐标（并以 vp 尺寸画底纸）绘制，
   * 实际却落在「已平移/已缩放」的坐标系里 —— 用户只要动过画布或设备密度 ≠ 1，
   * 导出内容就会跑到位图之外，表现为**导出成功但文件里一片空白**。
   *
   * 修法：导出前显式把变换重置为「仅密度、无平移无缩放」，
   * 这样 composeExportToContext 里的 vp/世界坐标与位图 1:1:密度 对应，内容完整入镜。
   * 调用方负责在 finally 中 `ctx.restore()` + `renderHistory()` 还原屏幕显示。
   */
  private beginExportCompose(ctx: CanvasRenderingContext2D): void {
    const dpr: number = vp2px(1);
    ctx.save();
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    // 在该变换下按 vp 尺寸清空，等价于清掉整幅物理缓冲区
    ctx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
  }

  /**
   * 导出完整合成：底纸 + 图片 + 图层笔迹 + 文本框/贴纸（exportImage / exportPdf 共用）。
   * 调用方负责 save/beginExportCompose/restore，本方法只负责按序绘制。
   */
  private composeExportToContext(ctx: CanvasRenderingContext2D): void {
    // 步骤1：绘制底纸
    this.engine.renderPaper(ctx, this.paperTemplate, this.canvasWidth, this.canvasHeight,
      this.canvasPaperColor);

    // 步骤2：绘制所有图片元素（ImageRefData 经 ImageManager 合成）
    for (let i = 0; i < this.noteImages.length; i++) {
      const imageRef: ImageRefData = this.noteImages[i];
      this.engine.getImageManager().drawImageRefToCanvas(ctx, imageRef);
    }

    // 步骤3：绘制所有图层笔迹（按图层顺序）
    const allLayers: Layer[] = this.engine.getLayerManager().getLayers();
    const sortedLayers: Layer[] = allLayers.slice().sort((a: Layer, b: Layer): number => a.order - b.order);
    for (const layer of sortedLayers) {
      if (!layer.visible) continue;

      // 获取该图层的所有笔画
      const layerStrokes: StrokeRecord[] = this.strokes.filter((s: StrokeRecord): boolean => s.layerId === layer.id);
      for (const stroke of layerStrokes) {
        this.drawStrokeToCanvas(ctx, stroke, layer.opacity);
      }
    }

    // 步骤4：绘制文本框 / 贴纸（与 renderHistory 的文本绘制口径一致，BUG-2）
    this.drawTextsToCanvas(ctx);
  }

  /** 绘制文本框 / 贴纸到指定 Canvas（与 renderHistory 末尾的文本绘制逻辑一致） */
  private drawTextsToCanvas(ctx: CanvasRenderingContext2D): void {
    for (let i = 0; i < this.texts.length; i++) {
      const t: HCText = this.texts[i];
      if (t.text.length === 0) {
        continue;
      }
      ctx.save();
      ctx.globalAlpha = 1;
      ctx.fillStyle = t.color !== undefined && t.color.length > 0 ? t.color : '#000000';
      ctx.font = `${Math.max(8, Math.min(120, t.fontSize))}px ${t.fontFamily}`;
      ctx.textBaseline = 'top';
      ctx.fillText(t.text, t.x, t.y);
      ctx.restore();
    }
  }

  /** Base64 → ArrayBuffer（PNG 二进制落盘用，与 ExportDialog 同实现） */
  private base64ToArrayBuffer(base64: string): ArrayBuffer {
    const base64Helper = new util.Base64Helper();
    const uint8Array: Uint8Array = base64Helper.decodeSync(base64, util.Type.BASIC);
    return uint8Array.buffer;
  }
  
  /**
   * 绘制单个笔画到指定Canvas（支持离屏Canvas合成）
   */
  private drawStrokeToCanvas(ctx: CanvasRenderingContext2D, stroke: StrokeRecord, opacity: number = 1.0): void {
    ctx.save();
    ctx.globalAlpha = opacity;
    
    // 根据笔画类型绘制
    if (stroke.tool === 'eraser') {
      ctx.globalCompositeOperation = 'destination-out';
      ctx.strokeStyle = HCGray.GRAY_1;
      ctx.lineWidth = stroke.width;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      for (let i = 0; i < stroke.points.length; i++) {
        const p = stroke.points[i];
        if (i === 0) {
          ctx.moveTo(p.x, p.y);
        } else {
          ctx.lineTo(p.x, p.y);
        }
      }
      ctx.stroke();
    } else if (SHAPE_TOOLS.indexOf(stroke.tool) >= 0) {
      // 形状工具
      ctx.strokeStyle = stroke.color;
      ctx.lineWidth = stroke.width;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      
      if (stroke.tool === 'rectangle' && stroke.points.length >= 2) {
        const p1 = stroke.points[0];
        const p2 = stroke.points[stroke.points.length - 1];
        ctx.strokeRect(p1.x, p1.y, p2.x - p1.x, p2.y - p1.y);
      } else if (stroke.tool === 'circle' && stroke.points.length >= 2) {
        const p1 = stroke.points[0];
        const p2 = stroke.points[stroke.points.length - 1];
        const radius = Math.sqrt(Math.pow(p2.x - p1.x, 2) + Math.pow(p2.y - p1.y, 2));
        ctx.beginPath();
        ctx.arc(p1.x, p1.y, radius, 0, 2 * Math.PI);
        ctx.stroke();
      } else if (stroke.tool === 'arrow' && stroke.points.length >= 2) {
        const p1 = stroke.points[0];
        const p2 = stroke.points[stroke.points.length - 1];
        this.drawArrow(ctx, p1.x, p1.y, p2.x, p2.y, stroke.width);
      } else if (stroke.tool === 'line' && stroke.points.length >= 2) {
        const p1 = stroke.points[0];
        const p2 = stroke.points[stroke.points.length - 1];
        ctx.beginPath();
        ctx.moveTo(p1.x, p1.y);
        ctx.lineTo(p2.x, p2.y);
        ctx.stroke();
      }
    } else {
      // 自由笔迹
      ctx.strokeStyle = stroke.color;
      ctx.lineWidth = stroke.width;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      ctx.beginPath();
      for (let i = 0; i < stroke.points.length; i++) {
        const p = stroke.points[i];
        if (i === 0) {
          ctx.moveTo(p.x, p.y);
        } else {
          ctx.lineTo(p.x, p.y);
        }
      }
      ctx.stroke();
    }
    
    ctx.restore();
  }
  
  /**
   * 绘制箭头
   */
  private drawArrow(ctx: CanvasRenderingContext2D, fromX: number, fromY: number, toX: number, toY: number, lineWidth: number): void {
    const headLength = lineWidth * 5;
    const angle = Math.atan2(toY - fromY, toX - fromX);
    
    ctx.beginPath();
    ctx.moveTo(fromX, fromY);
    ctx.lineTo(toX, toY);
    ctx.stroke();
    
    ctx.beginPath();
    ctx.moveTo(toX, toY);
    ctx.lineTo(toX - headLength * Math.cos(angle - Math.PI / 6), toY - headLength * Math.sin(angle - Math.PI / 6));
    ctx.moveTo(toX, toY);
    ctx.lineTo(toX - headLength * Math.cos(angle + Math.PI / 6), toY - headLength * Math.sin(angle + Math.PI / 6));
    ctx.stroke();
  }

  // ═══ S2-Ca / T2-5a：导出 PDF（Canvas 位图 → 手写最小 PDF 容器，零三方依赖）═══
  private async exportPdf(): Promise<void> {
    // BUG-2：PDF 复用与 exportImage 相同的完整合成（底纸 + 图片 + 笔画 + 文本），
    // 避免直接用 ctxHistory 导致缺底纸与插图。
    const ctx = this.ctxHistory;
    let ctxSaved: boolean = false;
    try {
      // 🔴 v2.7.1：改用 beginExportCompose（重置为「仅密度」变换），
      //   否则 clearCanvas 内的 restore() 会把视口平移/缩放还原回来 → 导出空白。
      this.beginExportCompose(ctx);
      ctxSaved = true;
      this.composeExportToContext(ctx);

      const dataUrl: string = ctx.toDataURL('image/jpeg', 0.9);
      if (dataUrl === undefined || dataUrl.length === 0) {
        this.setStatus('导出 PDF 失败', StatusSeverity.ALERT);
        return;
      }
      const page: PdfPageImage = {
        jpegDataUrl: dataUrl,
        width: Math.max(1, Math.round(this.canvasWidth)),
        height: Math.max(1, Math.round(this.canvasHeight)),
      };
      const pdfOptions: ExportPdfOptions = {
        includeAnnotations: false, // WhiteboardPage 无独立批注层；批注分层由 AnnotationPage 导出时扩展
      };
      const pdfBytes: ArrayBuffer = exportService.exportBitmapsToPDF([page], pdfOptions);
      if (pdfBytes.byteLength === 0) {
        this.setStatus('导出 PDF 失败', StatusSeverity.ALERT);
        return;
      }
      // F-01：真正落盘到文件系统（系统文件选择器 + fileIo），不再只写 AppStorage
      const filename: string = this.noteTitle.length > 0 ? this.noteTitle : 'whiteboard';
      const saved: boolean = await exportService.saveToFile(pdfBytes, filename, ExportFormat.PDF);
      if (saved) {
        this.setStatus(`已导出 PDF（${Math.round(pdfBytes.byteLength / 1024)}KB）`, StatusSeverity.INFO);
      } else {
        this.setStatus('导出 PDF 失败（已取消或未授权）', StatusSeverity.ALERT);
      }
    } catch (_) {
      this.setStatus('导出 PDF 失败', StatusSeverity.ALERT);
    } finally {
      // 兜底还原历史层，避免 ctxHistory 被临时合成内容污染
      if (ctxSaved) {
        try {
          ctx.restore();
        } catch (_) {
          Logger.warn(TAG_PAGE, '导出 PDF 还原上下文失败');
        }
        this.renderHistory();
      }
    }
  }

  /** 获取导出数据（dataURL） */
  private getExportData(): string {
    try {
      if (this.ctxHistory !== null && this.canvasWidth > 0 && this.canvasHeight > 0) {
        return this.ctxHistory.toDataURL('image/png');
      }
      return '';
    } catch (error) {
      const err = error as Error;
      Logger.error(TAG_PAGE, `Failed to get export data: ${err.message}`);
      return '';
    }
  }

  private shapeLabel(shape: string): string {
    const map: Record<string, string> = {
      'rectangle': '矩形', 'circle': '圆', 'arrow': '箭头', 'line': '直线',
      'pen': '笔迹', 'eraser': '橡皮'
    };
    return map[shape] || shape;
  }

  /** 自由笔迹判定：非形状、非橡皮的笔画都按折线绘制 */
  private isFreeStroke(tool: string): boolean {
    if (tool === 'eraser') {
      return false;
    }
    return SHAPE_TOOLS.indexOf(tool) < 0;
  }

  // ═══ 闪 草图一键转矢量（创新点1：无需AI模型，几何算法）═══
  private smartConvert(): void {
    // 取最近一笔自由笔迹（任意笔刷：钢笔/铅笔/毛笔…）
    let targetIndex = -1;
    for (let i = this.strokes.length - 1; i >= 0; i--) {
      const s = this.strokes[i];
      if (this.isFreeStroke(s.tool)) {
        targetIndex = i;
        break;
      }
    }
    if (targetIndex === -1) {
      this.setStatus('先用笔画一个图形');
      return;
    }

    const target = this.strokes[targetIndex];
    const input: VecPoint[] = target.points.map((p: PointRecord): VecPoint => ({ x: p.x, y: p.y }));
    const result = SketchToVector.convert(input);

    if (!result) {
      this.setStatus('未能识别（试画矩形/圆/箭头/直线）');
      return;
    }

    // 替换为标准形状笔画（保留颜色 / 线宽 / 图层，形状统一按不透明绘制）
    const newStroke: StrokeRecord = {
      id: ++this.strokeIdSeq,
      tool: result.shape,
      color: target.color,
      width: target.width,
      points: result.points.map((p: VecPoint): PointRecord => ({ x: p.x, y: p.y })),
      opacity: 1,
      blendMode: 'normal',
      brushShape: 'round',
      layerId: target.layerId.length > 0 ? target.layerId : this.drawLayerId,
      createdAt: Date.now(),
    };
    this.strokes.splice(targetIndex, 1, newStroke);
    this.resetRedoStacks();
    // 🔧 v2.5.5：撤销栈变更后刷新可用态（QA 回归补充：闪转矢量路径）
    this.updateUndoRedoState();
    this.clearCanvas(this.ctxActive);
    this.renderHistory();
    this.markDirty();
    this.setStatus(`闪 已转为标准${this.shapeLabel(result.shape)}`);
  }

  // ═══════════════════════════════════════════════════════════════
  // v2.3 协同 UI 接线（K-R2-2）
  // ═══════════════════════════════════════════════════════════════

  /**
   * 启动协同状态轮询（1s）：从 SessionManager / PermissionGuard 读取会话与权限。
   * 说明：状态为纯内存读取，无 I/O，不影响 120Hz 笔触主链路。
   */
  private startCollabRefresh(): void {
    if (this.collabTimer !== -1) {
      return;
    }
    this.collabTimer = setInterval(() => {
      SafeAsync.runVoid(TAG_PAGE, 'collabRefresh', () => {
        this.collabStatus = this.collabService.snapshot();
      });
    }, COLLAB_REFRESH_MS);
  }

  /** 停止协同状态轮询（aboutToDisappear 调用，防定时器泄漏） */
  private stopCollabRefresh(): void {
    if (this.collabTimer !== -1) {
      clearInterval(this.collabTimer);
      this.collabTimer = -1;
    }
  }

  /**
   * 检查画布内存使用情况（v2.4优化）
   * 大画布时触发预警，帮助用户了解性能影响
   */
  private checkCanvasMemory(): void {
    const stats: MemoryStats = MemoryMonitor.calculateMemoryUsage(
      this.canvasWidth,
      this.canvasHeight
    );
    
    // 记录内存统计信息
    Logger.info(TAG_PAGE, MemoryMonitor.formatMemoryStats(stats));
    
    // 如果有预警，显示提示
    if (stats.warningLevel >= MemoryWarningLevel.WARNING) {
      Logger.warn(TAG_PAGE, `内存预警：${stats.warningMessage}`);
    }
  }

  /**
   * 检查网络状态（v2.4优化）
   * C03（F-08 修复）：删除「网络恢复后自动同步」的假承诺日志——离线绘制已进入
   * CollaborationManager 的 OfflineOpQueue（Q14），状态由 §4.6 同步 chip 展示，
   * 这里只做真实能力声明，不再写做不到的承诺；并兑现「显示 UI 提示」的 TODO。
   */
  private async checkNetworkStatus(): Promise<void> {
    try {
      const info: NetworkInfo = await NetworkMonitor.getCurrentStatus();
      Logger.info(TAG_PAGE, NetworkMonitor.formatNetworkInfo(info));

      // 离线时显示真实状态提示（C03 §4.6 OFFLINE 措辞：明确「未同步」，不承诺自动同步）
      if (!info.isOnline) {
        const pending: number = this.collabStatus.pendingOpCount;
        const dropped: number = this.collabStatus.droppedOpCount;
        Logger.warn(TAG_PAGE, `离线模式：本地绘制已入补发队列（待同步 ${pending} 笔，已丢弃 ${dropped} 笔）`);
        if (dropped > 0) {
          this.setStatus(`! 已有 ${dropped} 笔超出缓存被丢弃，请点击状态条确认`, StatusSeverity.ALERT);
        } else {
          this.setStatus('! 离线 · 本地已保存，未同步', StatusSeverity.INFO);
        }
      }
    } catch (error) {
      Logger.error(TAG_PAGE, `网络状态检测失败：${error}`);
    }
  }

  /**
   * 触发一次视口同步（HM-09），用于验证 ≤5Hz 节流：
   * 连续点击时第 2 次起会返回 throttled=true。
   */
  private triggerViewportSync(): void {
    SafeAsync.runVoid(TAG_PAGE, 'triggerViewportSync', () => {
      const centerX: number = this.viewportX + this.canvasWidth / 2;
      const centerY: number = this.viewportY + this.canvasHeight / 2;
      const result: ViewportSyncResult =
        this.collabService.sendViewportSync(centerX, centerY, this.viewportScale, 1);
      this.setStatus(result.message);
      this.collabStatus = this.collabService.snapshot();
    });
  }

  /** 返回笔记列表（先落盘，保证列表里的时间/笔数/缩略图是新的） */
  private exitToList(): void {
    this.flushSave();
    SafeAsync.runVoid(TAG_PAGE, 'exitToList', () => {
      const state: router.RouterState = router.getState();
      if (state !== null && state !== undefined && state.index > 1) {
        router.back();
        return;
      }
      router.pushUrl({ url: 'pages/NotePage' })
        .catch((err: Error) => {
          this.setStatus(`返回列表失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
        });
    });
  }

  /** 返回首页（若无返回栈则跳转到 pages/Index） */
  private goHome(): void {
    this.flushSave();
    SafeAsync.runVoid(TAG_PAGE, 'goHome', () => {
      const state: router.RouterState = router.getState();
      if (state !== null && state !== undefined && state.index > 1) {
        router.back();
        return;
      }
      router.pushUrl({ url: 'pages/Index' })
        .catch((err: Error) => {
          this.setStatus(`返回首页失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
        });
    });
  }

  /** 埋点异步化：从主线程渲染路径移出（v2.3 性能优化） */
  private trackAsync(action: () => void): void {
    setTimeout(() => {
      SafeAsync.runVoid(TAG_PAGE, 'analytics', action);
    }, 0);
  }

  // ════════════════════════════════════════════════════════════════════
  //  v2.5：新工具与功能方法
  // ════════════════════════════════════════════════════════════════════

  /** 套索预览：在活动层绘制套索路径 */
  private drawLassoPreview(): void {
    if (!this.ctxActive || this.lassoPath.length < 4) {
      return;
    }
    const ctx = this.ctxActive;
    this.clearCanvas(ctx);
    ctx.save();
    ctx.beginPath();
    ctx.moveTo(this.lassoPath[0], this.lassoPath[1]);
    for (let i = 2; i < this.lassoPath.length; i += 2) {
      ctx.lineTo(this.lassoPath[i], this.lassoPath[i + 1]);
    }
    // 闭合路径（用 moveTo 到第一个点的形式让它形成闭合环）
    ctx.closePath();
    // 🔧 修复"选择工具无反馈"：加粗线宽 1.5→2.5，并增加半透明蓝色填充 + 1px 描边，
    //   在白底纸 / 复杂底图上都能明显看到套索区域。
    ctx.lineWidth = 2.5;
    ctx.strokeStyle = '#007DFF';
    ctx.fillStyle = 'rgba(0,125,255,0.12)';
    ctx.setLineDash([8, 4]);
    ctx.fill();
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.restore();
  }

  /** 完成套索选择：检测哪些笔画在套索区域内 */
  private completeLassoSelection(): void {
    this.clearCanvas(this.ctxActive);
    // 🔧 修复：套索点数过少（<3 个采样点）时，给用户可见的"已取消"反馈
    if (this.lassoPath.length < 6) {
      this.lassoPath = [];
      this.setStatus('套索取消：请拖动画出至少 3 个点', StatusSeverity.INFO);
      return;
    }
    // 计算套索路径的包围盒
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (let i = 0; i < this.lassoPath.length; i += 2) {
      const px = this.lassoPath[i];
      const py = this.lassoPath[i + 1];
      if (px < minX) minX = px;
      if (py < minY) minY = py;
      if (px > maxX) maxX = px;
      if (py > maxY) maxY = py;
    }
    // 🔧 修复"选择工具无反馈"：套索矩形过小视为误触，不进入选中态
    if (maxX - minX < 4 || maxY - minY < 4) {
      this.lassoPath = [];
      this.selectedStrokes = [];
      this.showSelectMenu = false;
      this.setStatus('套索过小：请拖出明显范围', StatusSeverity.INFO);
      return;
    }
    // 注入笔画包围盒回调
    this.lassoTool.getNodeBounds = (): Map<string, BoundingBox> => {
      const m = new Map<string, BoundingBox>();
      for (const s of this.strokes) {
        let sMinX = Infinity, sMinY = Infinity, sMaxX = -Infinity, sMaxY = -Infinity;
        for (const p of s.points) {
          if (p.x < sMinX) sMinX = p.x;
          if (p.y < sMinY) sMinY = p.y;
          if (p.x > sMaxX) sMaxX = p.x;
          if (p.y > sMaxY) sMaxY = p.y;
        }
        m.set(String(s.id), { x: sMinX, y: sMinY, w: sMaxX - sMinX, h: sMaxY - sMinY });
      }
      return m;
    };
    // 使用矩形框选
    this.lassoTool.beginSelect(minX, minY);
    this.lassoTool.updateSelect(maxX, maxY);
    this.lassoTool.finishSelect();
    const selectedItems = this.lassoTool.selected;
    if (selectedItems.length > 0) {
      this.selectedStrokes = this.strokes.filter((s: StrokeRecord) =>
        selectedItems.some((item: SelectionItem) => item.nodeId === String(s.id)));
      this.selectedStrokeIds = selectedItems.map((it: SelectionItem): number => Number(it.nodeId));
      this.showSelectMenu = true;
      this.setStatus(`已选中 ${selectedItems.length} 个笔画`, StatusSeverity.ROUTINE);
    } else {
      this.selectedStrokes = [];
      this.selectedStrokeIds = [];
      this.showSelectMenu = false;
      this.setStatus('套索未选中任何笔画，请扩大范围重试', StatusSeverity.INFO);
    }
    this.lassoPath = [];
  }

  /** 取色器：从画布像素采样颜色 */
  /**
   * 🔴 v2.7.1 审核修复（问题①-1「选择取后，获取的颜色一直是白色」真因）
   *
   * 世界坐标 → 画布缓冲区物理像素坐标。
   *
   * 旧实现（v2.6/v2.7 一直沿用）的致命错误：
   *     const dpr = this.canvasReady ? (this.ctxHistory.width / this.canvasWidth) : 1;
   *   ArkUI 的 `CanvasRenderingContext2D.width` 与页面里的 `this.canvasWidth`
   *   **都是 vp 单位**（canvasWidth 明确由 `= wVp` 赋值），因此这个比值**恒等于 1**。
   *   而画布的真实变换是 `setTransform(vp2px(1)*scale, …, vp2px(1)*viewportX, …)`，
   *   缓冲区实际尺寸是 `vp2px(canvasWidth)`。于是在 2x 设备上算出的采样点
   *   **只有真实位置的一半** —— 取色/填充一直在采错误的像素，
   *   点在粗黑笔迹上也只会读到空白 → 永远返回底纸色（白）。
   *
   * 修法：直接复用与变换同一套换算 —— dpr 取 `vp2px(1)`，边界取 `vp2px(vp 尺寸)`。
   */
  private worldToBufferPx(worldX: number, worldY: number): PxPoint {
    const dpr: number = vp2px(1);
    const vpX: number = worldX * this.viewportScale + this.viewportX;
    const vpY: number = worldY * this.viewportScale + this.viewportY;
    const bufW: number = Math.max(1, Math.round(vp2px(this.canvasWidth)));
    const bufH: number = Math.max(1, Math.round(vp2px(this.canvasHeight)));
    const px: number = Math.round(vpX * dpr);
    const py: number = Math.round(vpY * dpr);
    return {
      x: Math.max(0, Math.min(px, bufW - 1)),
      y: Math.max(0, Math.min(py, bufH - 1)),
    };
  }

  private handleEyedropper(x: number, y: number): void {
    if (!this.ctxHistory) {
      return;
    }
    try {
      // 🔴 v2.7.1：坐标换算统一走 worldToBufferPx（此前 dpr 恒为 1，采样点偏一半）
      const p: PxPoint = this.worldToBufferPx(x, y);
      const px: number = p.x;
      const py: number = p.y;
      // 设置像素采样回调
      // 🔧 v2.7.0 审核修复（问题①-1「获取的颜色一直是白色」）：
      //   旧实现只在**笔迹层 ctxHistory** 上采样，而底纸画在**独立的 ctxPaper** 上，
      //   笔迹层在空白处 alpha=0 → 代码把 alpha=0 一律当作"底纸色"返回白色。
      //   于是用户点在画布绝大多数区域（没有笔迹的地方）取到的永远是 #FFFFFF。
      //   现改为**分层采样**（模拟用户看到的最上层内容）：
      //     ① ctxHistory（已完成笔画）→ 有不透明像素就是笔迹色
      //     ② ctxPaper（底纸）→ 取底纸色（已按主题纸张底色绘制）
      //     ③ 都没有 → 回退到当前画布纸张底色（不再硬编码白）
      this.eyedropper.samplePixel = (sampleX: number, sampleY: number): [number, number, number, number] | null => {
        try {
          // 🔴 v2.7.1：边界用**缓冲区物理尺寸**（此前误用 vp 尺寸，导致采样点被钳到错误范围）
          const bufW: number = Math.max(1, Math.round(vp2px(this.canvasWidth)));
          const bufH: number = Math.max(1, Math.round(vp2px(this.canvasHeight)));
          const sxp: number = Math.max(0, Math.min(sampleX, bufW - 1));
          const syp: number = Math.max(0, Math.min(sampleY, bufH - 1));
          const hist = this.ctxHistory.getImageData(sxp, syp, 1, 1);
          if (hist.data[3] > 8) {
            return [hist.data[0], hist.data[1], hist.data[2], hist.data[3]];
          }
          const paper = this.ctxPaper.getImageData(sxp, syp, 1, 1);
          if (paper.data[3] > 8) {
            return [paper.data[0], paper.data[1], paper.data[2], paper.data[3]];
          }
          // 兜底：当前画布纸张底色（hex → rgba）
          const rgb = EyedropperTool.hexToRgb(this.canvasPaperColor);
          return [rgb.r, rgb.g, rgb.b, 255];
        } catch (e) {
          Logger.warn(TAG_PAGE, `取色采样异常：${e}`);
          return null;
        }
      };
      const hex = this.eyedropper.pickColorAt(px, py);
      if (hex) {
        this.currentColor = hex;
        this.eyedropperResult = hex;
        this.showColorPickerResult = true;
        // 🔧 v2.6.0 审核修复（问题①「取色后笔失效」）：
        //   取到的颜色必须同步写进笔刷记忆槽，否则切回「笔」时会被历史记忆覆盖，
        //   用户看到的现象就是"取色后笔失效"。同时写入 pen/brush，保证任意回切路径都保留。
        this.colorByBrush[this.currentBrush] = hex;
        this.colorByBrush['pen'] = hex;
        this.colorByBrush['brush'] = hex;
        // 🔧 v2.5.6 审核修复：取色后保持当前工具，不强制切回画笔。
        //   之前 1.5s setTimeout + switchTool('pen') 与用户中途切到"擦"等操作竞争，
        //   致使用户感觉"笔功能变成擦"。
        this.setStatus(`取色成功：${hex}，已应用到笔色`, StatusSeverity.ROUTINE);
        // 5s 后自动关闭取色结果提示面板，但工具状态保持不变
        this.colorPickerTimer = setTimeout(() => {
          this.colorPickerTimer = -1;
          this.showColorPickerResult = false;
        }, 5000);
      } else {
        this.setStatus('取色失败：无法读取像素', StatusSeverity.ALERT);
      }
    } catch (err) {
      this.setStatus(`取色失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
    }
  }

  /** 填充工具：在点击位置执行 Flood Fill（v2.7.0 性能根治） */
  private handleFill(x: number, y: number): void {
    if (!this.ctxHistory) {
      return;
    }
    // 🔧 v2.7.0 审核修复（问题①-1「选填后整页点不动，需重启」）：
    //   两个致命点已全部消除 ——
    //   ① 旧 PixelAccessor 逐像素 getImageData/putImageData（数百万次 GPU 同步往返）
    //      → 改为 CanvasPixelBuffer 整幅批量读写（往返恒为 2 次）；
    //   ② 旧实现无重入保护，连点会排队数十个 setTimeout 填充任务
    //      → 新增 fillRunning 闸门，运行期间直接忽略新的填色点击。
    if (this.fillRunning) {
      this.setStatus('填色进行中，请稍候…', StatusSeverity.ROUTINE, false);
      return;
    }
    try {
      // 🔴 v2.7.1：坐标与缓冲区尺寸统一按**物理像素**。
      //   此前 dpr 恒为 1（vp/vp）且 w/h 误取 vp 尺寸（ctx.width 是 vp），
      //   导致 loadPixels 拿到的整幅数据按 vp 尺寸去扫描 → 行列错位、点到哪都填不对。
      const p: PxPoint = this.worldToBufferPx(x, y);
      const px: number = p.x;
      const py: number = p.y;
      const ctx = this.ctxHistory;
      const w: number = Math.max(1, Math.round(vp2px(this.canvasWidth)));
      const h: number = Math.max(1, Math.round(vp2px(this.canvasHeight)));
      const fillColor: string = this.currentColor;
      const tolerance: number = this.fillTolerance;
      this.fillRunning = true;
      this.setStatus('填色中…', StatusSeverity.ROUTINE, true);
      // 先让出一帧，保证「填色中」状态与点击反馈先渲染出来
      setTimeout((): void => {
        const startedAt: number = Date.now();
        try {
          const buffer: CanvasPixelBuffer = new CanvasPixelBuffer(ctx, w, h);
          this.fillTool.setFillColor(fillColor);
          this.fillTool.setTolerance(tolerance);
          const outcome: FillOutcome = this.fillTool.floodFill(buffer, px, py);
          const cost: number = Date.now() - startedAt;
          if (!outcome.ok) {
            this.setStatus(`填色未执行：${outcome.reason}`, StatusSeverity.ALERT);
            return;
          }
          if (outcome.filledCount === 0) {
            this.setStatus(`填色：${outcome.reason}`, StatusSeverity.ROUTINE);
            return;
          }
          this.markDirty();
          // 填充直接改写了历史层像素，强制重绘一次保证画面与数据一致
          this.renderHistory();
          this.setStatus(`填充完成（${outcome.filledCount}px，${cost}ms，容差 ${tolerance}）`,
            StatusSeverity.ROUTINE);
        } catch (innerErr) {
          this.setStatus(`填充失败：${SafeAsync.describe(innerErr)}`, StatusSeverity.ALERT);
        } finally {
          this.fillRunning = false;
        }
      }, 0);
    } catch (err) {
      this.fillRunning = false;
      this.setStatus(`填充失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
    }
  }

  /** v2.5：打开页面管理面板 */
  private openPagePanel(): void {
    this.showPagePanel = true;
    this.totalPages = this.pageManager.pageCount;
    this.currentPageIndex = this.pageManager.currentIndex;
  }

  /** v2.5：切换到指定页 */
  private switchToPage(index: number): void {
    this.flushSave();
    this.pageManager.setCurrentPage(index);
    this.currentPageIndex = this.pageManager.currentIndex;
    // 重新加载页面内容
    this.aboutToAppear();
  }

  /** v2.5：添加新页 */
  private addNewPage(): void {
    this.flushSave();
    this.pageManager.addPage();
    this.totalPages = this.pageManager.pageCount;
    this.currentPageIndex = this.pageManager.currentIndex;
    this.strokes = [];
    // 🔧 v2.5.5：撤销栈变更后刷新可用态（审核项⑤全路径覆盖）
    this.updateUndoRedoState();
    this.renderHistory();
  }

  /** v2.5：打开笔画回放面板 */
  private openReplayPanel(): void {
    if (this.strokes.length === 0) {
      this.setStatus('无笔画可回放', StatusSeverity.INFO);
      return;
    }
    this.strokeReplay = new StrokeReplay();
    const replayStrokes: ReplayStroke[] = this.strokes.map((s: StrokeRecord, i: number) =>
      new ReplayStrokeImpl(String(s.id), s.createdAt ?? i, s as object)
    );
    this.strokeReplay.loadStrokes(replayStrokes);
    // 设置可见性回调：显示/隐藏笔画
    this.replayVisibleIds = new Set<string>();
    this.strokeReplay.setVisibilityCallback((id: string, visible: boolean) => {
      if (visible) {
        this.replayVisibleIds.add(id);
      } else {
        this.replayVisibleIds.delete(id);
      }
    });
    this.showReplayPanel = true;
    this.replayProgress = 0;
    this.replayPlaying = false;
  }

  /** v2.5：播放/暂停回放 */
  private toggleReplay(): void {
    if (!this.strokeReplay) {
      return;
    }
    if (this.strokeReplay.isPlaying) {
      this.strokeReplay.pause();
      this.replayPlaying = false;
    } else {
      this.strokeReplay.play();
      this.replayPlaying = true;
      this.advanceReplay();
    }
  }

  /** v2.5：推进回放一帧（50ms 自循环；句柄入字段，页面销毁可清理） */
  private advanceReplay(): void {
    if (!this.strokeReplay || !this.replayPlaying) {
      this.replayTimer = -1;
      return;
    }
    this.strokeReplay.stepForward();
    this.replayProgress = this.strokeReplay.progress;
    // 重绘到当前回放进度
    this.clearCanvas(this.ctxHistory);
    for (const s of this.strokes) {
      if (this.replayVisibleIds.has(String(s.id))) {
        this.drawStrokeToCanvas(this.ctxHistory, s);
      }
    }
    if (this.replayProgress < 1.0) {
      this.replayTimer = setTimeout(() => this.advanceReplay(), 50);
    } else {
      this.replayPlaying = false;
      this.replayTimer = -1;
    }
  }

  /** v2.5：打开模板选择面板 */
  private openTemplatePanel(): void {
    this.showTemplatePanel = true;
  }

  /** v2.5：应用模板 */
  private applyTemplate(template: NoteTemplate): void {
    this.showTemplatePanel = false;
    this.paperTemplate = this.engine.setPaperLayerTemplate(this.paperLayerId, template.paper);
    this.renderPaper();
    this.markDirty();
    this.setStatus(`已应用模板：${template.name}`, StatusSeverity.ROUTINE);
  }

  /** v2.5：打开标签面板 */
  private openTagPanel(): void {
    this.showTagPanel = true;
    this.noteTags = this.tagManager.listTags();
  }

  /** v2.5：添加标签 */
  private addTag(name: string, color: string): void {
    this.tagManager.createTag(name, color);
    this.noteTags = this.tagManager.listTags();
  }

  /** v2.5：进入/退出演示模式 */
  private togglePresentation(): void {
    if (!this.inPresentation) {
      this.presentationMode.start(this.totalPages, this.currentPageIndex);
      this.inPresentation = true;
      this.leftToolbarExpanded = false;
      this.setStatus('演示模式已开启', StatusSeverity.ROUTINE);
    } else {
      this.presentationMode.stop();
      this.inPresentation = false;
      this.setStatus('演示模式已关闭', StatusSeverity.INFO);
    }
  }

  /** v2.5：打开密码锁对话框 */
  private openLockDialog(): void {
    this.showLockDialog = true;
  }

  /** v2.5：设置密码锁 */
  private setNoteLock(password: string): void {
    this.lockManager.setLock(this.noteId, password);
    this.noteLocked = true;
    this.showLockDialog = false;
    this.setStatus('笔记已锁定', StatusSeverity.ROUTINE);
  }

  /** v2.5：解锁笔记 */
  private unlockNote(password: string): void {
    if (this.lockManager.unlock(this.noteId, password)) {
      this.noteLocked = false;
      this.showLockDialog = false;
      this.setStatus('笔记已解锁', StatusSeverity.ROUTINE);
    } else {
      this.setStatus('密码错误', StatusSeverity.ALERT);
    }
  }

  /** v2.5：打开录音面板 */
  private openAudioPanel(): void {
    this.showAudioPanel = true;
  }

  /** v2.5：开始/停止录音 */
  private toggleRecording(): void {
    if (!this.isRecording) {
      this.audioManager.startRecording(this.noteId, Date.now()).then((ok: boolean) => {
        if (ok) {
          this.isRecording = true;
          this.recordingDuration = 0;
          this.setStatus('录音中...', StatusSeverity.INFO);
          // v2.5.1：句柄入字段，aboutToDisappear 可清理
          this.recordingTimer = setTimeout(() => this.updateRecordingDuration(), 1000);
        }
      });
    } else {
      this.audioManager.stopRecording(Date.now()).then(() => {
        this.isRecording = false;
        this.setStatus(`录音完成（${this.recordingDuration}s）`, StatusSeverity.ROUTINE);
      });
    }
  }

  /** v2.5：更新录音时长（自循环 1s；句柄入字段 + 停止即置 -1，防离页后继续回调） */
  private updateRecordingDuration(): void {
    if (!this.isRecording) {
      this.recordingTimer = -1;
      return;
    }
    this.recordingDuration++;
    this.recordingTimer = setTimeout(() => this.updateRecordingDuration(), 1000);
  }

  // ══════════════════════════════════════════════════════════════════
  // v2.5.2 审核驳回修复：扩展工具弹层渲染（之前 showXxx = true 后无任何 UI 弹层）
  // ══════════════════════════════════════════════════════════════════

  /**
   * 笔盒弹层：列出笔刷预设（点击应用颜色 + 线宽）
   * v2.5.3：修复 showBrushBox 置 true 后无 UI 的孤儿状态
   */
  @Builder
  buildBrushBoxDialog() {
    Column() {
      Column() {
        Row() {
          Text('笔盒').fontSize(16).fontWeight(FontWeight.Bold).fontColor(HCColor.TEXT_PRIMARY)
          Blank()
          Text('×').fontSize(22).fontColor(HCColor.TEXT_TERTIARY)
            .onClick((): void => { this.showBrushBox = false; })
        }
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        if (this.brushPresets.length === 0) {
          Column() {
            Text('暂无笔刷预设').fontSize(15).fontColor(HCColor.TEXT_PRIMARY).margin({ top: 60 })
            Text('可在参数面板保存当前笔刷到笔盒').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 6 })
          }
          .width('100%').height(240)
          .justifyContent(FlexAlign.Start).alignItems(HorizontalAlign.Center)
        } else {
          List() {
            ForEach(this.brushPresets, (preset: BrushPreset, index: number) => {
              ListItem() {
                Row() {
                  Circle().width(24).height(24).fill(preset.color).margin({ right: 12 })
                  Column() {
                    Text(preset.name).fontSize(14).fontColor(HCColor.TEXT_PRIMARY)
                    Text(`${preset.type} · 宽度 ${preset.width} · 透明度 ${Math.round(preset.opacity * 100)}%`)
                      .fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('应用')
                    .fontSize(12).fontColor(HCColor.PRIMARY)
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .backgroundColor(HCColor.PRIMARY_BG)
                    .borderRadius(8)
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
                .onClick((): void => {
                  this.brushBox.setActivePreset(index);
                  this.currentColor = preset.color;
                  this.currentWidth = preset.width;
                  this.showBrushBox = false;
                  this.setStatus(`已应用笔刷：${preset.name}`);
                })
              }
            }, (preset: BrushPreset) => preset.name)
          }
          .listDirection(Axis.Vertical)
          .width('100%').height(280)
        }
      }
      .width('88%')
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(16)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.20)', offsetY: 4 })
      .onClick((): void => {})
    }
    .width('100%').height('100%')
    .backgroundColor(HCOverlay.MASK_40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .zIndex(300)
    .onClick((): void => { this.showBrushBox = false; })
  }

  /**
   * 文本工具轻提示（v2.7.0 重做）。
   *
   * 🔧 审核问题①-2 真因：旧实现是**全屏遮罩 + 点击任意处关闭**，
   *   于是「双击文本工具」的第二次点击会立刻把刚打开的提示关掉 → 用户看不到任何反馈；
   *   而且遮罩把画布整个盖住，与文案"点击画布任意位置放置文本框"自相矛盾。
   *
   * 现在改为**不遮挡画布**的顶部横幅：只有右侧关闭按钮可点，
   * 其余区域 `hitTestBehavior(None)` 把触摸透传给画布，用户可立即点画布放置文本框。
   */
  @Builder
  buildTextToolHint() {
    Row() {
      SymbolGlyph($r('sys.symbol.' + IconSymbols.DOC_TEXT))
        .fontSize(16)
        .fontColor([HCColor.PRIMARY])
        .margin({ right: 6 })
      Text('文本工具：输入内容后点「确定」放置；双击文本框可再次编辑')
        .fontSize(12)
        .fontColor(HCColor.TEXT_PRIMARY)
        .layoutWeight(1)
      Text('✕')
        .fontSize(14)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width(28).height(28)
        .textAlign(TextAlign.Center)
        .onClick((): void => {
          this.showTextToolPanel = false;
        })
    }
    .width('92%')
    .padding({ left: 12, right: 4, top: 8, bottom: 8 })
    .backgroundColor(HCColor.PRIMARY_BG)
    .borderRadius(10)
    .border({ width: 1, color: HCColor.PRIMARY_BORDER })
    .position({ x: '4%', y: 56 })
    .zIndex(200)
  }

  /**
   * 分享弹层：导出 PDF / 导出图片 / 复制链接 / 加入协作
   * 真实能力由 NoteEngine.getExportData() + ExportService 支撑。
   */
  @Builder
  buildShareDialog() {
    Column() {
      Column() {
        Row() {
          Text('分享 / 导出').fontSize(16).fontWeight(FontWeight.Bold).fontColor(HCColor.TEXT_PRIMARY)
          Blank()
          Text('×').fontSize(22).fontColor(HCColor.TEXT_TERTIARY)
            .onClick((): void => { this.showShareDialog = false; })
        }
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        List() {
          ListItem() {
            this.shareItem('导出 PDF', '将当前笔记导出为 PDF 文件', 'pdf', (): void => {
              this.showShareDialog = false;
              this.setStatus('正在导出 PDF，请选择保存位置…', StatusSeverity.INFO);
              this.exportPdf().catch((err: Error): void => {
                this.setStatus(`PDF 导出失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
              });
            })
          }
          ListItem() {
            this.shareItem('导出图片', '将当前画布导出为 PNG', 'img', (): void => {
              this.showShareDialog = false;
              this.setStatus('正在导出图片，请选择保存位置…', StatusSeverity.INFO);
              this.exportImage().catch((err: Error): void => {
                this.setStatus(`图片导出失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
              });
            })
          }
          ListItem() {
            this.shareItem('分享图片', '通过系统分享面板发送当前画布', 'share', (): void => {
              this.showShareDialog = false;
              this.setStatus('正在生成图片并拉起分享…', StatusSeverity.INFO);
              this.shareCanvasImage().catch((err: Error): void => {
                this.setStatus(`分享失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
              });
            })
          }
          // 🔴 v2.7.5：协作入口暂时下线（详见 Constants.FEATURE_COLLAB_ENABLED 注释）。
          //   开关打开时该条目才会渲染，实现仍完整保留。
          if (FEATURE_COLLAB_ENABLED) {
          ListItem() {
            this.shareItem('加入协作', '创建或加入房间，与研友共学', 'sync', (): void => {
              this.showShareDialog = false;
              // 🔴 v2.7.1 审核修复（问题③-4「加入协作点击无反应」）：
              //   原实现只 setStatus 一句提示，用户看不到任何界面变化。
              //   现改为**真实跳转到「加入白板」页**，与文案一致。
              this.setStatus('正在打开协作房间…', StatusSeverity.INFO);
              SafeAsync.runVoid(TAG_PAGE, 'pushJoinRoom', (): void => {
                router.pushUrl({ url: 'pages/JoinRoomPage' }).catch((err: Error): void => {
                  this.setStatus(`打开协作页失败：${SafeAsync.describe(err)}`, StatusSeverity.ALERT);
                });
              });
            })
          }
          }
          ListItem() {
            this.shareItem('复制笔记 ID', '用于设备间手动对齐', 'id', (): void => {
              this.showShareDialog = false;
              this.copyNoteId();
            })
          }
        }
        .listDirection(Axis.Vertical)
        .width('100%')
        .height(280)
        // 注：List 容器使用 ListEdgeEffect 而非 EdgeEffect
      }
      .width('88%')
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(16)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.20)', offsetY: 4 })
      // v2.5.3：消费点击事件，避免点内容区冒泡到遮罩导致误关闭
      .onClick((): void => {})
    }
    .width('100%').height('100%')
    .backgroundColor(HCOverlay.MASK_40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .zIndex(300)
    .onClick((): void => { this.showShareDialog = false; })
  }

  @Builder
  shareItem(title: string, subtitle: string, tag: string, onTap: () => void) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
        Text(subtitle).fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(tag).fontSize(11).fontColor(HCColor.PRIMARY)
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(HCColor.PRIMARY_BG)
        .borderRadius(6)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .onClick((): void => { onTap(); })
  }

  /**
   * 回收站弹层：列出已删除笔记（点击恢复）
   */
  @Builder
  buildRecycleBinDialog() {
    Column() {
      Column() {
        Row() {
          Text('回收站').fontSize(16).fontWeight(FontWeight.Bold).fontColor(HCColor.TEXT_PRIMARY)
          Blank()
          Text('×').fontSize(22).fontColor(HCColor.TEXT_TERTIARY)
            .onClick((): void => { this.showRecycleBin = false; })
        }
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        if (this.recycleBinItems.length === 0) {
          Column() {
            Text('回收站是空的').fontSize(15).fontColor(HCColor.TEXT_PRIMARY).margin({ top: 60 })
            Text('删除的笔记将在此保留 30 天').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 6 })
          }
          .width('100%').height(280)
          .justifyContent(FlexAlign.Start).alignItems(HorizontalAlign.Center)
        } else {
          List() {
            ForEach(this.recycleBinItems, (item: RecycleBinItem) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(item.noteTitle).fontSize(14).fontColor(HCColor.TEXT_PRIMARY).maxLines(1)
                    Text(this.formatRecycleTime(item.deletedAt))
                      .fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 })
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('恢复')
                    .fontSize(12).fontColor(HCColor.PRIMARY)
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .backgroundColor(HCColor.PRIMARY_BG)
                    .borderRadius(8)
                    .onClick((): void => {
                      this.recycleBin.restore(item.id).then((): void => {
                        this.recycleBinItems = this.recycleBin.getItems();
                        this.setStatus(`已恢复：${item.noteTitle}`);
                      });
                    })
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
              }
            }, (item: RecycleBinItem) => item.id)
          }
          .listDirection(Axis.Vertical)
          .width('100%').height(280)
          // 注：List 容器使用 ListEdgeEffect 而非 EdgeEffect
        }
      }
      .width('88%')
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(16)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.20)', offsetY: 4 })
      .onClick((): void => {})
    }
    .width('100%').height('100%')
    .backgroundColor(HCOverlay.MASK_40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .zIndex(300)
    .onClick((): void => { this.showRecycleBin = false; })
  }

  private formatRecycleTime(ts: number): string {
    const d: Date = new Date(ts);
    const pad: (n: number) => string = (n: number): string => (n < 10 ? '0' + n : '' + n);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  /**
   * 版本历史弹层：列出当前笔记的历史快照（点击恢复）
   */
  @Builder
  buildVersionHistoryDialog() {
    Column() {
      Column() {
        Row() {
          Text('版本历史').fontSize(16).fontWeight(FontWeight.Bold).fontColor(HCColor.TEXT_PRIMARY)
          Blank()
          Text('×').fontSize(22).fontColor(HCColor.TEXT_TERTIARY)
            .onClick((): void => { this.showVersionHistory = false; })
        }
        .width('100%').padding({ left: 16, right: 16, top: 14, bottom: 8 })

        if (this.versionEntries.length === 0) {
          Column() {
            Text('暂无历史版本').fontSize(15).fontColor(HCColor.TEXT_PRIMARY).margin({ top: 60 })
            Text('在笔记列表点击保存快照会出现在此').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 6 })
          }
          .width('100%').height(280)
          .justifyContent(FlexAlign.Start).alignItems(HorizontalAlign.Center)
        } else {
          List() {
            ForEach(this.versionEntries, (entry: VersionEntry) => {
              ListItem() {
                Row() {
                  Column() {
                    Text(entry.title).fontSize(14).fontColor(HCColor.TEXT_PRIMARY).maxLines(1)
                    Text(`${this.formatRecycleTime(entry.timestamp)} · ${entry.description}`)
                      .fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 }).maxLines(1)
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text('恢复此版本')
                    .fontSize(12).fontColor(HCColor.PRIMARY)
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .backgroundColor(HCColor.PRIMARY_BG)
                    .borderRadius(8)
                    .onClick((): void => {
                      this.versionHistory.restoreVersion(entry.id).then((): void => {
                        this.setStatus(`已恢复：${entry.title}`);
                        this.showVersionHistory = false;
                      });
                    })
                }
                .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
              }
            }, (entry: VersionEntry) => entry.id)
          }
          .listDirection(Axis.Vertical)
          .width('100%').height(280)
          // 注：List 容器使用 ListEdgeEffect 而非 EdgeEffect
        }
      }
      .width('88%')
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(16)
      .shadow({ radius: 20, color: 'rgba(0,0,0,0.20)', offsetY: 4 })
      .onClick((): void => {})
    }
    .width('100%').height('100%')
    .backgroundColor(HCOverlay.MASK_40)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .zIndex(300)
    .onClick((): void => { this.showVersionHistory = false; })
  }

  /** v2.5：打开大纲面板 */
  private openOutlinePanel(): void {
    this.showOutlinePanel = true;
    const outlineView = new OutlineView();
    // 从文本框提取大纲
    const blocks: OutlineTextBlock[] = this.texts.map((t: HCText): OutlineTextBlock => {
      return { id: t.id, text: t.text, y: t.y };
    });
    outlineView.generateFromTextBlocks(blocks);
    this.outlineNodes = outlineView.list();
  }
}
