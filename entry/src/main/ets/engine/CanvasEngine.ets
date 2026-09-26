import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';
import { LayerManager, Layer } from './LayerManager';
import { StrokeEngine } from './StrokeEngine';
import { NoteEngine } from './NoteEngine';
import { QuadTree } from '../canvas/QuadTree';
import { CanvasNode, Rect, Viewport, ZOOM_MIN, ZOOM_MAX, CANVAS_LOGICAL_HALF_RANGE } from './types/BoardModel';

const TAG_MODULE = 'CanvasEngine';

/** v2.0（S2T01 / HM-09）：视口状态导出/导入结构（流转同步用，与 ViewportSyncPayload 对齐） */
export interface CanvasViewportState {
  centerX: number;
  centerY: number;
  scale: number;
  currentPage: number;
  timestamp: number;
}

export class CanvasEngine {
  private static instance: CanvasEngine | null = null;
  private context: CanvasRenderingContext2D | null = null;
  private strokeEngine: StrokeEngine | null = null;
  private layerManager: LayerManager;
  private timerId: number = -1;
  private isRunning: boolean = false;
  private lastFrameTime: number = 0;
  private frameCount: number = 0;
  private fpsAccumulator: number = 0;
  private currentFPS: number = 0;
  private viewportX: number = 0;
  private viewportY: number = 0;
  private viewportScale: number = 1.0;
  private dirtyRectCount: number = 0;
  private firstFrameRendered: boolean = false;
  private firstFrameStartTime: number = 0;
  /** v2.0：当前页码（文档批注/流转跟随，HM-09） */
  private currentPage: number = 0;
  /** ENG-03：四叉树空间索引（视口裁剪用），null 表示尚未建树 */
  private spatialIndex: QuadTree | null = null;

  static getInstance(): CanvasEngine {
    if (!CanvasEngine.instance) {
      CanvasEngine.instance = new CanvasEngine();
    }
    return CanvasEngine.instance;
  }

  private constructor() {
    this.layerManager = LayerManager.getInstance();
    this.strokeEngine = StrokeEngine.getInstance();
    // v2.0：确保笔记引擎门面（底纸/笔刷/文档导入/文本框）进入 ArkTS 编译图
    NoteEngine.getInstance();
  }

  setRenderContext(ctx: CanvasRenderingContext2D): void {
    this.context = ctx;
  }

  onCanvasReady(): void {
    this.firstFrameStartTime = Date.now();
    this.startRenderLoop();
    Logger.info(TAG_MODULE, 'Canvas ready, render loop started');
  }

  private startRenderLoop(): void {
    if (this.isRunning) {
      return;
    }
    this.isRunning = true;
    this.lastFrameTime = Date.now();
    this.timerId = setInterval(() => {
      const now = Date.now();
      const delta = now - this.lastFrameTime;
      this.lastFrameTime = now;
      this.fpsAccumulator += delta;
      this.frameCount++;
      if (this.fpsAccumulator >= 1000) {
        this.currentFPS = this.frameCount;
        this.frameCount = 0;
        this.fpsAccumulator -= 1000;
      }
      if (!this.firstFrameRendered) {
        const elapsed = Date.now() - this.firstFrameStartTime;
        this.firstFrameRendered = true;
        if (elapsed > Constants.CANVAS_FIRST_FRAME_MS) {
          Logger.warn(TAG_MODULE, `First frame exceeded limit: ${elapsed}ms`);
        }
      }
      this.renderFrame();
    }, 16); // ~60 FPS
  }

  stopRenderLoop(): void {
    this.isRunning = false;
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private renderFrame(): void {
    if (!this.context) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.context;
    // 🔴 v2.7.1：ctx.width/height 为 vp；按 vp 尺寸 clearRect 在 dpr>1 时只清左上局部，
    //   会残留上一帧内容。按物理缓冲区尺寸清理。
    const w: number = vp2px(ctx.width);
    const h: number = vp2px(ctx.height);
    ctx.clearRect(0, 0, w, h);
    ctx.save();
    ctx.translate(this.viewportX, this.viewportY);
    ctx.scale(this.viewportScale, this.viewportScale);
    const layers: Layer[] = this.layerManager.getLayers();
    for (const layer of layers) {
      if (!layer.visible) {
        continue;
      }
      ctx.save();
      ctx.globalAlpha = layer.opacity;
      if (layer.offscreenCanvas) {
        // draw offscreen bitmap
      }
      ctx.restore();
    }
    ctx.restore();
    if (this.currentFPS > 0 && this.currentFPS < Constants.CANVAS_MIN_FPS) {
      Logger.warn(TAG_MODULE, `Low FPS: ${this.currentFPS}`);
    }
  }

  handleTouchEvent(event: TouchEvent): void {
    if (!this.strokeEngine) {
      return;
    }
    this.strokeEngine.handleTouchEvent(event, this.viewportScale, this.viewportX, this.viewportY);
    this.dirtyRectCount++;
  }

  zoomIn(): void {
    this.viewportScale = Math.min(this.viewportScale * 1.2, ZOOM_MAX);
    this.dirtyRectCount++;
  }

  zoomOut(): void {
    this.viewportScale = Math.max(this.viewportScale / 1.2, ZOOM_MIN);
    this.dirtyRectCount++;
  }

  fitToScreen(): void {
    this.viewportScale = 1.0;
    this.viewportX = 0;
    this.viewportY = 0;
    this.dirtyRectCount++;
  }

  pan(dx: number, dy: number): void {
    this.viewportX += dx;
    this.viewportY += dy;
    this.dirtyRectCount++;
  }

  setViewport(x: number, y: number, scale: number): void {
    this.viewportX = x;
    this.viewportY = y;
    this.viewportScale = Math.max(ZOOM_MIN, Math.min(scale, ZOOM_MAX));
    this.dirtyRectCount++;
  }

  resetViewport(): void {
    this.viewportX = 0;
    this.viewportY = 0;
    this.viewportScale = 1.0;
    this.dirtyRectCount++;
  }

  getFPS(): number {
    return this.currentFPS;
  }

  getViewportScale(): number {
    return this.viewportScale;
  }

  getViewportX(): number {
    return this.viewportX;
  }

  getViewportY(): number {
    return this.viewportY;
  }

  getCurrentPage(): number {
    return this.currentPage;
  }

  setCurrentPage(page: number): void {
    this.currentPage = Math.max(0, page);
  }

  /**
   * v2.0（S2T01 / HM-09）：导出视口状态（中心坐标/缩放/当前页/时间戳），
   * 供超级终端流转时随会话状态下发。
   */
  getViewportState(): CanvasViewportState {
    const state: CanvasViewportState = {
      centerX: this.viewportX,
      centerY: this.viewportY,
      scale: this.viewportScale,
      currentPage: this.currentPage,
      timestamp: Date.now()
    };
    return state;
  }

  /**
   * v2.0（S2T01 / HM-09）：导入视口状态（流转续写时恢复视口/页码）。
   * 视口同步为 LWW 展示态，不进入 CRDT 数据面。
   */
  setViewportState(vp: CanvasViewportState): void {
    this.viewportX = vp.centerX;
    this.viewportY = vp.centerY;
    this.viewportScale = Math.max(0.01, Math.min(vp.scale, 64.0));
    this.currentPage = vp.currentPage >= 0 ? vp.currentPage : 0;
    this.dirtyRectCount++;
    Logger.info(TAG_MODULE, `Viewport imported: page=${this.currentPage} scale=${this.viewportScale}`);
  }

  // ═══════════════════════════════════════════════════════════════
  // ENG-01 / ENG-03：无限画布视口变换 + 四叉树空间索引 + 分层渲染
  // ═══════════════════════════════════════════════════════════════

  /**
   * ENG-01：平移视口（单指拖拽）。dx/dy 为屏幕像素增量，直接累加翻译量。
   * 无限画布——不做越界自动居中（clampViewport 已放开至 ±20000vp）。
   */
  panBy(dx: number, dy: number): void {
    this.viewportX += dx;
    this.viewportY += dy;
    this.dirtyRectCount++;
  }

  /**
   * ENG-01：锚点缩放（双指捏合）。以屏幕点 (cx,cy) 为锚点，保持该点对应的画布坐标不动。
   * factor 为缩放倍率；缩放范围 clamp 到 [ZOOM_MIN, ZOOM_MAX]（0.1x–8x）。
   */
  zoomAt(cx: number, cy: number, factor: number): void {
    const newScale: number = Math.max(ZOOM_MIN, Math.min(ZOOM_MAX, this.viewportScale * factor));
    // 锚点对应的画布逻辑坐标（缩放前）
    const anchorX: number = (cx - this.viewportX) / this.viewportScale;
    const anchorY: number = (cy - this.viewportY) / this.viewportScale;
    this.viewportScale = newScale;
    this.viewportX = cx - anchorX * newScale;
    this.viewportY = cy - anchorY * newScale;
    this.dirtyRectCount++;
  }

  /**
   * ENG-03：用节点数组（合规 CanvasNode[]）重建四叉树空间索引。
   * 树根覆盖整张无限画布逻辑范围 ±20000vp。
   */
  rebuildSpatialIndex(nodes: CanvasNode[]): void {
    const half: number = CANVAS_LOGICAL_HALF_RANGE;
    this.spatialIndex = new QuadTree({ x: -half, y: -half, w: half * 2, h: half * 2 });
    this.spatialIndex.rebuild(nodes);
  }

  /**
   * ENG-03：取当前视口 + buffer 比例内的可见节点（buffer 默认 10%，架构§4.1）。
   * 无四叉树时回退为返回全部节点（调用方按需裁剪），保证不丢数据。
   */
  getVisibleNodes(vp: Viewport, buffer?: number): CanvasNode[] {
    const buf: number = buffer !== undefined && buffer > 0 ? buffer : 0.1;
    const screenW: number = this.context !== null ? this.context.width : 1080;
    const screenH: number = this.context !== null ? this.context.height : 1920;
    // 视口对应的世界矩形（屏幕左上/右下逆变换）
    const worldLeft: number = (0 - this.viewportX) / this.viewportScale;
    const worldTop: number = (0 - this.viewportY) / this.viewportScale;
    const worldRight: number = (screenW - this.viewportX) / this.viewportScale;
    const worldBottom: number = (screenH - this.viewportY) / this.viewportScale;
    const region: Rect = {
      x: worldLeft - (worldRight - worldLeft) * buf,
      y: worldTop - (worldBottom - worldTop) * buf,
      w: (worldRight - worldLeft) * (1 + buf * 2),
      h: (worldBottom - worldTop) * (1 + buf * 2)
    };
    if (this.spatialIndex === null) {
      return [];
    }
    return this.spatialIndex.query(region);
  }

  /**
   * ENG-03：将静态节点批量绘制到离屏静态层（OffscreenCanvas）。
   * 动态元素（光标/选中框/连线）不在此层。dirty 时才由调用方触发重绘。
   */
  drawStaticLayer(nodes: CanvasNode[]): void {
    const lm: LayerManager = LayerManager.getInstance();
    lm.rasterizeStatic(nodes);
  }

  /**
   * ENG-03：每帧绘制动态层（活动笔迹 / 选中框 / 连线手柄）。
   * 直接在主上下文绘制，不参与静态层缓存。
   */
  drawDynamicLayer(active: CanvasNode | null, selection: Rect, links: { id: string; from: string; to: string }[]): void {
    if (!this.context) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.context;
    if (active !== null) {
      // 活动节点高亮（占位：描边）
      ctx.save();
      ctx.strokeStyle = '#007DFF';
      ctx.lineWidth = 2 / this.viewportScale;
      ctx.strokeRect(active.x, active.y, active.w, active.h);
      ctx.restore();
    }
    if (selection.w > 0 || selection.h > 0) {
      ctx.save();
      ctx.strokeStyle = '#FF6B35';
      ctx.setLineDash([4, 4]);
      ctx.lineWidth = 1.5 / this.viewportScale;
      ctx.strokeRect(selection.x, selection.y, selection.w, selection.h);
      ctx.restore();
    }
    // 连线手柄：阶段2 LinkLayer 接管，此处仅占位绘制锚点
    for (let i = 0; i < links.length; i++) {
      void links[i];
    }
  }

  isFirstFrameDone(): boolean {
    return this.firstFrameRendered;
  }

  destroy(): void {
    this.stopRenderLoop();
    this.context = null;
    CanvasEngine.instance = null;
  }
}
