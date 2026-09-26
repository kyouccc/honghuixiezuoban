/**
 * NoteEngine.ets — 笔记引擎门面（v2.0 增量，S1T01~S1T03 汇总入口 / v2.4 阶段一 T1-3 扩展）
 *
 * 聚合单人笔记引擎核心服务：纸图层渲染、笔刷注册表、文档导入、文本框工具、
 * 以及 v2.4 新增的**笔记持久化仓储 / 图层管理 / 图片管理 / 导出服务**。
 *
 * 作用：
 *  1. 页面层（NotePage / WhiteboardPage）通过本门面统一获取引擎能力，避免散落引用；
 *     ——铁律 2：任何页面都不得直接 import NoteRepository / LayerManager 等实现类。
 *  2. 确保新引擎文件（NoteRepository/NoteSerializer/NoteIndexStore/PaperLayerRenderer/…）
 *     进入 ArkTS 编译依赖图，被 CompileArkTS 完整类型校验
 *     （ArkTS 只编译可达模块图，未被引用的 .ets 会被编译器跳过 —— 共识 F-2）。
 *
 * v2.4 阶段一新增：
 *  - initStorage(context)：由 EntryAbility.onCreate 调用，建目录 + 起索引 + fileIo 冒烟自检；
 *  - getNoteRepository / getLayerManager / getImageManager / getExportService / getBrushConfig。
 */

import { PaperLayerRenderer, PaperTemplateInfo } from './PaperLayerRenderer';
import { BrushRegistry, BrushConfig } from './BrushRegistry';
import { DocumentImporter } from './document/DocumentImporter';
import { DocSessionManager } from './document/DocSessionManager';
import { TextBlockTool } from './TextBlockTool';
import { CanvasElementType, ImageRefData, getCanvasElementTypeLabel } from './types/CanvasElement';
import { SessionManager, FlowSessionState } from '../distributed/SessionManager';
import { DistributedBoardSync } from '../distributed/DistributedBoardSync';
import { ViewportSyncManager, ViewportState } from '../distributed/ViewportSyncManager';
import { PermissionGuard, SessionRole } from '../common/services/PermissionGuard';
import { CollaborationManager } from '../common/services/CollaborationManager';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { Layer, LayerManager } from './LayerManager';
import { ImageManager } from './ImageManager';
import { ExportService } from '../common/services/ExportService';
import { NoteRepository } from './NoteRepository';
import { NoteSerializer } from './NoteSerializer';
import { themeManager } from '../common/theme/ThemeManager';
import {
  BrushOption,
  HC_LOCAL_AUTHOR,
  NoteContent,
  NoteMeta,
  PaperOption,
  StrokeRecord,
} from './types/NoteModel';

const TAG_ENGINE = 'NoteEngine';

/** 打开一篇笔记时建立的画布图层骨架（底纸层 + 默认绘制层） */
export interface CanvasLayerSetup {
  paperLayerId: string;
  drawLayerId: string;
}

export class NoteEngine {
  private static instance: NoteEngine | null = null;
  private readonly documentImporter: DocumentImporter;
  private readonly textBlockTool: TextBlockTool;
  // ─── 文档导入会话管理 ───
  private readonly docSessionManager: DocSessionManager = DocSessionManager.getInstance();
  /** v2.0（S2T01/S2T02/S2T03）：分布式协同模块单例，保证进入 ArkTS 编译图 */
  private readonly sessionManager: SessionManager;
  private readonly distributedBoardSync: DistributedBoardSync;
  private readonly viewportSyncManager: ViewportSyncManager;
  private readonly permissionGuard: PermissionGuard;
  private readonly collaborationManager: CollaborationManager;
  /** v2.4 阶段一：持久化与画布资源管理 */
  private readonly noteRepository: NoteRepository;
  private readonly layerManager: LayerManager;
  private readonly imageManager: ImageManager;
  private readonly exportService: ExportService;
  private storageReady: boolean = false;

  private constructor() {
    this.documentImporter = DocumentImporter.getInstance();
    this.textBlockTool = new TextBlockTool();
    // v2.0：实例化分布式协同模块（仅单例创建，无 I/O/渲染/网络副作用）
    this.sessionManager = SessionManager.getInstance();
    this.distributedBoardSync = DistributedBoardSync.getInstance();
    this.viewportSyncManager = ViewportSyncManager.getInstance();
    this.permissionGuard = PermissionGuard.getInstance();
    this.collaborationManager = CollaborationManager.getInstance();
    // v2.4：构造期只做对象创建，真正的目录 / Preferences I/O 延后到 initStorage
    this.noteRepository = new NoteRepository();
    this.layerManager = LayerManager.getInstance();
    this.imageManager = ImageManager.getInstance();
    this.exportService = ExportService.getInstance();
  }

  static getInstance(): NoteEngine {
    if (!NoteEngine.instance) {
      NoteEngine.instance = new NoteEngine();
    }
    return NoteEngine.instance;
  }

  /** 底纸模板列表（NP-01） */
  getPaperTemplates(): PaperTemplateInfo[] {
    return PaperLayerRenderer.getTemplates();
  }

  /**
   * 渲染底纸图案（NP-01；ctx 由页面持有）。
   * @param bgColor 底纸底色（v2.6.0：由主题设置的「画布纸张」提供，省略则恒白）
   */
  renderPaper(ctx: CanvasRenderingContext2D, template: string, w: number, h: number,
              bgColor?: string): void {
    let bg: string = bgColor !== undefined && bgColor !== null && bgColor.length > 0
      ? bgColor : '#FFFFFF';
    // v2.6.0：暗色模式下若用户未显式指定纸张，底纸自动取深色，避免白底刺眼
    try {
      if (bg === '#FFFFFF' && themeManager.isDarkMode()) {
        bg = themeManager.getCanvasPaperColor();
      }
    } catch (_e) { /* 主题未就绪时保持默认白底 */ }
    PaperLayerRenderer.renderPaper(ctx, template, w, h, bg);
  }

  /** 全部笔刷配置（NP-02） */
  getBrushConfigs(): BrushConfig[] {
    return BrushRegistry.getBrushConfigs();
  }

  /** 单个笔刷配置（未知笔型回退到钢笔，NP-02） */
  getBrushConfig(tool: string): BrushConfig {
    return BrushRegistry.getBrushConfig(tool);
  }

  /**
   * 底纸选项（页面层友好类型）。
   * 页面不直接 import PaperLayerRenderer，避免 UI 与引擎实现耦合（共识 F-1）。
   */
  getPaperOptions(): PaperOption[] {
    const infos: PaperTemplateInfo[] = PaperLayerRenderer.getTemplates();
    const options: PaperOption[] = [];
    for (let i = 0; i < infos.length; i++) {
      options.push({ template: infos[i].template, name: infos[i].name });
    }
    return options;
  }

  /** 笔刷选项（页面层友好类型，供 BrushPanel 直接渲染） */
  getBrushOptions(): BrushOption[] {
    const configs: BrushConfig[] = BrushRegistry.getBrushConfigs();
    const options: BrushOption[] = [];
    for (let i = 0; i < configs.length; i++) {
      const c: BrushConfig = configs[i];
      options.push({
        tool: c.tool,
        name: c.name,
        brushShape: c.brushShape,
        opacity: c.opacity,
        blendMode: c.blendMode,
        minWidth: c.minWidth,
        maxWidth: c.maxWidth,
      });
    }
    return options;
  }

  /** 文档导入门面（NP-05/06） */
  getDocumentImporter(): DocumentImporter {
    return this.documentImporter;
  }

  /** 文档导入会话管理（T2-1 文档批注页，NP-05/06） */
  getDocSessionManager(): DocSessionManager {
    return this.docSessionManager;
  }

  /** 文本框工具（NP-04） */
  getTextBlockTool(): TextBlockTool {
    return this.textBlockTool;
  }

  /** 元素类型中文名（UI 展示用） */
  getElementTypeLabel(elementType: string): string {
    return getCanvasElementTypeLabel(elementType);
  }

  // ═══ v2.0（S2T01/S2T02/S2T03）：分布式协同门面 ═══

  /** 超级终端流转会话（HM-08） */
  getSessionManager(): SessionManager {
    return this.sessionManager;
  }

  /** 板面同步传输适配器（承接视口同步消息转发） */
  getDistributedBoardSync(): DistributedBoardSync {
    return this.distributedBoardSync;
  }

  /** 视口/页码跟随管理器（HM-09） */
  getViewportSyncManager(): ViewportSyncManager {
    return this.viewportSyncManager;
  }

  /** 客户端权限守卫（HM-11） */
  getPermissionGuard(): PermissionGuard {
    return this.permissionGuard;
  }

  /** 协作管理器（权限断言 + 元素联合类型 + 会话） */
  getCollaborationManager(): CollaborationManager {
    return this.collaborationManager;
  }

  /** 设置本地设备 id（流转会话身份，Q-03 设备组） */
  setLocalDeviceId(deviceId: string): void {
    this.sessionManager.setLocalDeviceId(deviceId);
    this.viewportSyncManager.setLocalDeviceId(deviceId);
  }

  /**
   * 创建笔记协作会话（本机 NoteHost）
   */
  createFlowSession(noteId: string, deviceGroupId: string): FlowSessionState {
    return this.distributedBoardSync.attachSession(noteId, deviceGroupId);
  }

  /**
   * 引擎视口变化 → 板面同步（节流后发送 MSG_VIEWPORT_SYNC）
   */
  syncViewportToBoard(centerX: number, centerY: number, scale: number, currentPage: number): void {
    const vp: ViewportState | null = this.distributedBoardSync.syncViewportFromEngine(centerX, centerY, scale, currentPage);
    if (vp !== null) {
      this.collaborationManager.syncViewport(vp);
    }
  }

  // ═══ v2.4 阶段一（T1-3）：持久化与画布资源门面 ═══

  /**
   * 初始化本地存储。**必须**在 EntryAbility.onCreate 中调用一次。
   *
   * 做三件事：
   *  ① 建立 files/notes 与 files/thumbs 目录；
   *  ② 打开 Preferences 索引库并载入内存；
   *  ③ 跑一次 fileIo 最小写读闭环自检（本项目首次真实使用 CoreFileKit，先冒烟再上业务）。
   *
   * 本方法**不抛异常**：失败时 storageReady 保持 false，
   * 页面层据此显示「存储不可用」而不是白屏（S-5）。
   */
  async initStorage(context: common.Context): Promise<boolean> {
    if (this.storageReady) {
      return true;
    }
    const ok: boolean = await this.noteRepository.init(context);
    if (!ok) {
      Logger.error(TAG_ENGINE, '存储初始化失败，笔记功能不可用');
      this.storageReady = false;
      return false;
    }
    const probeError: string = await this.noteRepository.selfTest();
    if (probeError.length > 0) {
      Logger.error(TAG_ENGINE, `fileIo 自检未通过：${probeError}`);
      this.storageReady = false;
      return false;
    }
    this.storageReady = true;
    Logger.info(TAG_ENGINE, '存储初始化完成，笔记读写可用');
    return true;
  }

  /** 存储是否可用（页面层用于降级提示） */
  isStorageReady(): boolean {
    return this.storageReady && this.noteRepository.isReady();
  }

  /** 笔记仓储（列表 / 新建 / 读写 / 删除 / 缩略图） */
  getNoteRepository(): NoteRepository {
    return this.noteRepository;
  }

  /** 图层管理器（页面层唯一获取入口，铁律 2） */
  getLayerManager(): LayerManager {
    return this.layerManager;
  }

  /** 图片管理器（插图缓存与引用） */
  getImageManager(): ImageManager {
    return this.imageManager;
  }

  /** 导出服务（PNG / PDF / 分享） */
  getExportService(): ExportService {
    return this.exportService;
  }

  /**
   * 底纸模板合法性归一（页面层选择器与路由参数校验共用）。
   * 说明：NoteSerializer 为全静态类，通过本委托方法暴露，
   * 既避免页面层 import 具体实现，也确保该模块进入 ArkTS 编译图（F-2）。
   */
  normalizePaperTemplate(template: string): string {
    return NoteSerializer.normalizePaperTemplate(template);
  }

  /** 坐标 2 位量化（页面层做实时预览对齐时可复用，保证与落盘规则一致） */
  quantize(value: number): number {
    return NoteSerializer.quantize(value);
  }

  // ═══ v2.4 阶段一（T1-5）：白板画布 ↔ 笔记文档 组装门面 ═══

  /**
   * 打开一篇笔记时重建画布图层骨架。
   *
   * 顺序：reset() → 复用 reset 自带的默认绘制层（重命名为「图层 1」）→ 追加底纸层 → 底纸下沉到最底。
   * 底纸的实际像素由独立的 ctxPaper 画布绘制，这里建层只为让图层面板层序直观、
   * 并让底纸模板随文档一起落盘（HCLayer.paperTemplate）。
   */
  setupCanvasLayers(paperTemplate: string): CanvasLayerSetup {
    const template: string = NoteSerializer.normalizePaperTemplate(paperTemplate);
    this.layerManager.reset();
    const existing: Layer[] = this.layerManager.getLayers();
    const draw: Layer = existing.length > 0 ? existing[0] : this.layerManager.createLayer('图层 1', 'draw');
    this.layerManager.renameLayer(draw.id, '图层 1');
    const paper: Layer = this.layerManager.createPaperLayer('底纸', template);
    // 新建层被 push 到顶部，下沉一次即位于最底
    this.layerManager.moveDown(paper.id);
    this.layerManager.setActiveLayer(draw.id);
    Logger.info(TAG_ENGINE, `画布图层就绪 paper=${paper.id} draw=${draw.id} template=${template}`);
    return { paperLayerId: paper.id, drawLayerId: draw.id };
  }

  /** 切换底纸模板（返回归一化后的模板名） */
  setPaperLayerTemplate(paperLayerId: string, template: string): string {
    const normalized: string = NoteSerializer.normalizePaperTemplate(template);
    const layer: Layer | null = this.layerManager.getLayer(paperLayerId);
    if (layer !== null) {
      layer.paperTemplate = normalized;
    }
    return normalized;
  }

  /**
   * 页面内存态 → 可落盘 NoteContent。
   * 页面层的**唯一**组装入口：不直接接触 NoteSerializer，也不自己拼 HCStroke。
   */
  composeNoteContent(
    meta: NoteMeta,
    paperTemplate: string,
    paperLayerId: string,
    records: StrokeRecord[],
    images: ImageRefData[],
    canvasWidth: number,
    canvasHeight: number,
    forwardRaw: string
  ): NoteContent {
    const layers: Layer[] = this.layerManager.getLayers();
    return NoteSerializer.composeContent(
      meta, paperTemplate, paperLayerId, layers, records, images, canvasWidth, canvasHeight, forwardRaw
    );
  }

  /** 落盘笔画 → 页面内存笔画 */
  strokesFromContent(content: NoteContent): StrokeRecord[] {
    return NoteSerializer.hcToStrokeRecords(content.strokes);
  }

  /** 落盘插图 → 页面内存插图 */
  imagesFromContent(content: NoteContent): ImageRefData[] {
    return NoteSerializer.hcToImageRefs(content.images);
  }

  /** 新建一条插图引用（uri-only，U-4：阶段一不做二进制内嵌） */
  createImageRef(layerId: string, uri: string, x: number, y: number, width: number, height: number): ImageRefData {
    const now: number = Date.now();
    return {
      id: `${CanvasElementType.IMAGE_REF}_${now}_${Math.floor(Math.random() * 10000)}`,
      layerId: layerId,
      createdBy: HC_LOCAL_AUTHOR,
      createdAt: now,
      imageHash: '',
      mimeType: 'image/*',
      x: NoteSerializer.quantize(x),
      y: NoteSerializer.quantize(y),
      width: NoteSerializer.quantize(width),
      height: NoteSerializer.quantize(height),
      binaryRef: '',
      uri: uri,
      rotation: 0,
      scale: 1,
    };
  }

  /** 把插图挂回图层（打开笔记时恢复现场） */
  attachImages(layerId: string, images: ImageRefData[]): void {
    for (let i = 0; i < images.length; i++) {
      const ref: ImageRefData = images[i];
      ref.layerId = layerId;
      this.layerManager.addImageRef(layerId, ref);
    }
  }

  /**
   * 图层是否可见（渲染期高频只读查询）。
   * 页面层渲染循环用它决定某笔画/某插图要不要画，从而让图层面板的「👁 可见」真正生效；
   * 通过门面暴露，避免 pages/* 直接 import LayerManager（F-1）。
   * 层不存在时返回 true —— 宁可多画也不要凭空丢用户笔迹。
   */
  layerVisible(layerId: string): boolean {
    if (layerId.length === 0) {
      return true;
    }
    const layer: Layer | null = this.layerManager.getLayer(layerId);
    if (layer === null) {
      return true;
    }
    return layer.visible;
  }

  /**
   * 图层透明度（0~1，渲染期高频只读查询）。
   * 与笔画自身 opacity 相乘后作为最终 globalAlpha，让图层面板的透明度滑块真正生效。
   */
  layerOpacity(layerId: string): number {
    if (layerId.length === 0) {
      return 1;
    }
    const layer: Layer | null = this.layerManager.getLayer(layerId);
    if (layer === null) {
      return 1;
    }
    const value: number = layer.opacity;
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  /** 协同服务初始化 */
  initCollaborationServices(_context: Context): void {
    // 协同服务初始化
  }
}
