
/**
 * AnnotationPage.ets — 文档批注页（T2-1 阶段二「文档导入与批注页」）
 *
 * 能力（架构 §3.2 / NP-05 / NP-06 / A2-1 / A2-2）：
 *  - 导入 PDF：经 NoteEngine 门面 → DocSessionManager → DocumentImporter 创建只读底图 PageLayer；
 *  - 三层画布：ctxPaper（文档底图）/ ctxHistory（已完成批注）/ ctxActive（当前笔迹）；
 *    ⚠️ history 与 active 必须 Color.Transparent（C-2），否则底图被整张盖死；
 *  - 批注笔迹层与 pageIndex **强绑**：每页一个 draw 注解层，翻页只切换 activeLayer + 重渲染当前页，
 *    保证「翻页批注不错位（A2-1）」；
 *  - 翻页条 + 缩略图页码：底部上一页 / 下一页 + 页码指示 + 横排页码缩略（当前页高亮）；
 *  - 降级不崩溃不白屏（A2-2）：CAJ 提示「请转换为 PDF 后导入」、EPUB 明确降级文案；
 *    存储未就绪显示提示而非白屏；导入失败以对话框明示原因。
 *
 * 分层铁律：页面层只经 NoteEngine 门面使用引擎能力，不 import NoteSerializer / LayerManager 等实现类。
 * ArkTS 严格模式：无 any/unknown、无对象展开、显式类型、SafeAsync 包裹异常。
 */

import { router } from '@kit.ArkUI';
import { BackButton } from '../common/components/BackButton';
import picker from '@ohos.file.picker';
import image from '@ohos.multimedia.image';
import { SafeAsync, SafeErrorInfo } from '../common/utils/SafeAsync';
import { Logger } from '../common/Logger';
import { NoteEngine } from '../engine/NoteEngine';
import { NoteRepository, NoteSaveResult } from '../engine/NoteRepository';
import { PageInkVO, InkStrokeVO, InkPointVO, InkExportResult } from '../engine/document/PDFAnnotationWriter';
import { NoteContent, NoteMeta, NoteRouteParams, NoteSaveState, StatusSeverity, StrokeRecord, PointRecord, HCDoc, HCAnnotation, HC_LOCAL_AUTHOR, HC_DEFAULT_PAPER, createNoteMeta, normalizeNoteTitle, noteSaveStateText, statusPalette } from '../engine/types/NoteModel';
import { HCColor, HCGray, HCBrand, HCOverlay } from '../common/theme/DesignTokens';

const TAG_PAGE = 'AnnotationPage';
/** 自动保存脏检查间隔（ms） */
const AUTOSAVE_INTERVAL_MS: number = 2000;
/** 单次导入页上限（与 PDF_FREE_PAGE_LIMIT 对齐，免费版 10 页） */
const MAX_IMPORT_PAGES: number = 10;

@Entry
@Component
struct AnnotationPage {
  // ─── 引擎门面（页面层唯一入口）───
  private engine: NoteEngine = NoteEngine.getInstance();

  // ─── 三层画布 ───
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctxPaper: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ctxHistory: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private ctxActive: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  // ─── 笔记标识与落盘上下文 ───
  @State noteTitle: string = '文档批注';
  @State storageReady: boolean = false;
  @State saveState: string = NoteSaveState.IDLE;
  private noteId: string = '';
  private noteMeta: NoteMeta = createNoteMeta('', '文档批注', HC_DEFAULT_PAPER);
  private forwardRaw: string = '';
  private paperLayerId: string = '';
  private paperTemplate: string = HC_DEFAULT_PAPER;

  // ─── 文档 / 分页态 ───
  @State hasDoc: boolean = false;
  @State pageCount: number = 0;
  @State currentPageIndex: number = 0;
  /** 页码缩略序列（0 基） */
  @State pageIndices: number[] = [];
  /** 已导入文档元信息（每篇一个 HCDoc，落盘 docs[]） */
  private docs: HCDoc[] = [];

  // ─── 批注笔迹：pageIndex → 该页 StrokeRecord[]（强绑核心运行时结构）───
  private pageStrokes: Map<number, StrokeRecord[]> = new Map<number, StrokeRecord[]>();
  private strokeIdSeq: number = 0;

  // ─── 笔刷状态 ───
  private readonly penColors: string[] = ['#000000', '#E53935', '#1E88E5', '#43A047', '#FB8C00'];
  private readonly penWidths: number[] = [2, 4, 8];
  @State currentColorIndex: number = 0;
  @State currentWidthIndex: number = 1;
  @State currentTool: string = 'pen'; // 'pen' | 'eraser'

  // ─── 画布尺寸 ───
  @State canvasReady: boolean = true;
  private canvasWidth: number = 0;
  private canvasHeight: number = 0;

  // ─── 当前绘制状态 ───
  private drawing: boolean = false;
  private currentPoints: PointRecord[] = [];

  // ─── 自动保存 ───
  @State statusText: string = '就绪';
  /** T2-1b C-2：承接 NoteSaveResult.failureKind，chip 文案按分类显示 */
  @State saveFailReason: string = 'unknown';
  private dirty: boolean = false;
  private saving: boolean = false;
  private saveTimer: number = -1;

  // ─── 降级 / 错误提示（A2-2 不静默失败）───
  @State showError: boolean = false;
  @State errorMessage: string = '';

  // ─── F-04：文档导入进行中（防重复点击 + 按钮态）───
  @State importing: boolean = false;
  /** F-04 任务 B：批注写回 PDF 进行中 */
  @State exporting: boolean = false;

  // ═══════════════════════════════════════════════════
  // 生命周期
  // ═══════════════════════════════════════════════════

  aboutToAppear(): void {
    this.storageReady = this.engine.isStorageReady();
    this.readRouteParams();
    if (!this.storageReady) {
      this.statusText = '本地存储未就绪，暂不可批注';
      return;
    }
    // 无 noteId 时先新建一篇笔记承载批注，再装载 / 启动自动保存
    SafeAsync.runAsyncVoid(TAG_PAGE, 'ensureNote', async (): Promise<void> => {
      if (this.noteId.length === 0) {
        const repo: NoteRepository = this.engine.getNoteRepository();
        const meta: NoteMeta = await repo.createNote('文档批注', HC_DEFAULT_PAPER);
        this.noteId = meta.id;
        this.noteMeta = meta;
        this.noteTitle = meta.title;
      }
      this.loadNote();
      this.startAutoSave();
    }, (info: SafeErrorInfo): void => {
      this.statusText = `初始化失败：${info.message}`;
      this.saveState = NoteSaveState.FAILED;
    });
  }

  aboutToDisappear(): void {
    this.stopAutoSave();
    // 退出前尽力保存（不阻塞销毁）
    SafeAsync.runVoid(TAG_PAGE, 'exitSave', (): void => {
      this.flushSave();
    });
  }

  /** 读取路由参数（noteId 优先；缺失时由 ensureNote 新建） */
  private readRouteParams(): void {
    SafeAsync.runVoid(TAG_PAGE, 'readRouteParams', (): void => {
      const params: NoteRouteParams = router.getParams() as NoteRouteParams;
      if (params !== null && params !== undefined) {
        const id: string = params.noteId !== undefined && params.noteId !== null ? params.noteId : '';
        if (id.length > 0) {
          this.noteId = id;
          this.noteTitle = normalizeNoteTitle(params.title, '文档批注');
        }
      }
    });
  }

  /** 从磁盘恢复文档 + 批注（永不抛异常，失败时按空处理，S-5） */
  private loadNote(): void {
    if (this.noteId.length === 0) {
      return;
    }
    if (!this.storageReady) {
      return;
    }
    SafeAsync.runAsyncVoid(TAG_PAGE, 'loadNote', async (): Promise<void> => {
      const repo: NoteRepository = this.engine.getNoteRepository();
      const result = await repo.loadNote(this.noteId);
      const content: NoteContent = result.content;
      this.noteMeta = content.meta;
      this.forwardRaw = content.forwardRaw;
      this.paperTemplate = HC_DEFAULT_PAPER;

      // 恢复文档分页（无位图，A2-2 重载后底图以白底兜底，pdf.js 接入后可恢复）
      this.restoreDocs(content.docs);
      // 恢复批注笔迹到对应页
      this.restoreAnnotations(content.annotations);

      this.renderPaper();
      this.renderHistory();
      this.dirty = false;
      this.saveState = NoteSaveState.SAVED;
      if (this.hasDoc) {
        this.statusText = `已恢复 ${this.pageStrokes.size} 页批注`;
      } else {
        this.statusText = '就绪，可点击右上角「导入PDF」开始批注';
      }
      Logger.info(TAG_PAGE, `装载完成 docs=${content.docs.length} annotations=${content.annotations.length}`);
    }, (info: SafeErrorInfo): void => {
      this.statusText = `装载失败：${info.message}`;
      this.saveState = NoteSaveState.FAILED;
    });
  }

  // ═══════════════════════════════════════════════════
  // 文档导入（桥接 DocSessionManager → DocumentImporter）
  // ═══════════════════════════════════════════════════

  /** 导入按钮：拉起文档选择器 → 导入 → 建页批注层 */
  private async onImport(): Promise<void> {
    if (!this.storageReady) {
      this.showErrorDialog('本地存储未就绪，无法导入');
      return;
    }
    if (this.importing) {
      return;
    }
    let uri: string = '';
    try {
      uri = await this.pickDocument();
    } catch (e) {
      // 用户取消或选择器异常：静默返回，不视为失败（A2-2 不白屏）
      Logger.info(TAG_PAGE, `文档选择取消或失败: ${SafeAsync.describe(e as Error)}`);
      return;
    }
    if (uri.length === 0) {
      return;
    }
    const fileName: string = this.extractFileName(uri);
    this.importing = true;
    this.statusText = `正在解析 ${fileName}…`;
    SafeAsync.runAsyncVoid(TAG_PAGE, 'import', async (): Promise<void> => {
      const session = this.engine.getDocSessionManager();
      const meta = await session.importDocument(uri, fileName);
      // 为每一页创建一个批注 draw 层并强绑 pageIndex
      const lm = this.engine.getLayerManager();
      for (let i = 0; i < meta.pageCount; i++) {
        const layer = lm.createLayer(`批注 第${i + 1}页`, 'draw');
        session.bindPageLayer(meta.docId, i, layer.id);
        this.pageStrokes.set(i, []);
      }
      const hcDoc: HCDoc = {
        docId: meta.docId,
        fileName: meta.fileName,
        format: meta.format,
        pageCount: meta.pageCount,
        pageRefs: this.buildPageRefs(meta.docId, meta.pageCount),
        importedAt: Date.now(),
        sourcePath: this.engine.getDocumentImporter().getDocSourcePath(meta.docId),
      };
      this.docs.push(hcDoc);

      session.setCurrentDoc(meta.docId);
      session.setCurrentPageIndex(0);
      this.hasDoc = true;
      this.pageCount = meta.pageCount;
      this.currentPageIndex = 0;
      this.pageIndices = this.rangeArray(meta.pageCount);
      const firstLayer: string = session.getPageLayerId(meta.docId, 0);
      if (firstLayer.length > 0) {
        lm.setActiveLayer(firstLayer);
      }
      this.renderPaper();
      this.renderHistory();
      this.markDirty();
      this.importing = false;
      this.statusText = `已导入 ${meta.fileName}（${meta.pageCount} 页）`;
      Logger.info(TAG_PAGE, `导入完成 docId=${meta.docId} pages=${meta.pageCount}`);
    }, (info: SafeErrorInfo): void => {
      // A2-2：CAJ / EPUB / 不支持格式等由 DocumentImporter 抛出友好文案，直接明示给用户
      this.importing = false;
      this.statusText = '导入失败';
      this.showErrorDialog(info.message.length > 0 ? info.message : '文档导入失败');
    });
  }

  /**
   * F-04 任务 B：把当前文档的全部手写批注以标准 PDF Ink 批注写回，另存为新 PDF。
   * 坐标换算、PDF Kit 细节全部在引擎层（DocSessionManager → PDFAnnotationWriter）完成，
   * 页面层只负责收集「页码 + 画布尺寸 + 笔迹」并展示结果。
   */
  private async onExportAnnotatedPdf(): Promise<void> {
    if (this.exporting) {
      return;
    }
    const session = this.engine.getDocSessionManager();
    const docId: string = session.getCurrentDocId();
    if (docId.length === 0) {
      this.showErrorDialog('请先导入 PDF 再导出批注');
      return;
    }
    if (!session.isInkExportSupported()) {
      this.showErrorDialog('当前设备不支持系统 PDF 服务，无法导出带批注的 PDF');
      return;
    }
    const pages: PageInkVO[] = this.collectPageInk();
    if (pages.length === 0) {
      this.showErrorDialog('当前文档还没有手写批注，无需导出');
      return;
    }
    this.exporting = true;
    this.statusText = '正在把批注写回 PDF…';
    SafeAsync.runAsyncVoid(TAG_PAGE, 'exportAnnotatedPdf', async (): Promise<void> => {
      const result: InkExportResult = await session.exportAnnotatedPdf(docId, pages);
      this.exporting = false;
      if (result.success) {
        this.statusText = result.message;
        Logger.info(TAG_PAGE, `批注导出成功: ${result.outputPath}`);
      } else {
        this.statusText = '批注导出失败';
        this.showErrorDialog(result.message);
      }
    }, (info: SafeErrorInfo): void => {
      this.exporting = false;
      this.statusText = '批注导出失败';
      this.showErrorDialog(info.message.length > 0 ? info.message : '批注导出失败');
    });
  }

  /** 收集各页手写批注为写回 VO（跳过空页；画布尺寸对所有页一致，因底图整幅铺满画布） */
  private collectPageInk(): PageInkVO[] {
    const result: PageInkVO[] = [];
    const cw: number = this.canvasWidth;
    const ch: number = this.canvasHeight;
    if (cw <= 0 || ch <= 0) {
      return result;
    }
    this.pageStrokes.forEach((strokes: StrokeRecord[], pageIndex: number): void => {
      if (strokes.length === 0) {
        return;
      }
      const inkStrokes: InkStrokeVO[] = [];
      for (let i = 0; i < strokes.length; i++) {
        const s: StrokeRecord = strokes[i];
        const src: PointRecord[] = s.points !== undefined && s.points !== null ? s.points : [];
        if (src.length === 0) {
          continue;
        }
        const pts: InkPointVO[] = [];
        for (let j = 0; j < src.length; j++) {
          const p: InkPointVO = { x: src[j].x, y: src[j].y };
          pts.push(p);
        }
        const vo: InkStrokeVO = {
          points: pts,
          color: s.color,
          width: s.width,
          opacity: s.opacity,
        };
        inkStrokes.push(vo);
      }
      if (inkStrokes.length === 0) {
        return;
      }
      const pageVO: PageInkVO = {
        pageIndex: pageIndex,
        canvasWidth: cw,
        canvasHeight: ch,
        strokes: inkStrokes,
      };
      result.push(pageVO);
    });
    return result;
  }

  /** 拉起文档选择器，返回选中 URI */
  private pickDocument(): Promise<string> {
    return new Promise<string>((resolve: (v: string) => void, reject: (e: Error) => void): void => {
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.pdf', '.epub', '.caj'],
      }).then((uris: Array<string>): void => {
        if (uris.length > 0) {
          resolve(uris[0]);
        } else {
          resolve('');
        }
      }).catch((err: Error): void => {
        reject(err);
      });
    });
  }

  private extractFileName(path: string): string {
    const idx: number = path.lastIndexOf('/');
    if (idx >= 0 && idx < path.length - 1) {
      return path.substring(idx + 1);
    }
    return path;
  }

  private buildPageRefs(docId: string, pageCount: number): string[] {
    const refs: string[] = [];
    for (let i = 0; i < pageCount; i++) {
      refs.push(`${docId}:${i}`);
    }
    return refs;
  }

  private rangeArray(n: number): number[] {
    const arr: number[] = [];
    const limit: number = n > MAX_IMPORT_PAGES ? MAX_IMPORT_PAGES : n;
    for (let i = 0; i < limit; i++) {
      arr.push(i);
    }
    return arr;
  }

  // ═══════════════════════════════════════════════════
  // 恢复（重载既有批注笔记）
  // ═══════════════════════════════════════════════════

  /** 从持久化 docs[] 重建文档会话与每页批注层（无位图，底图以白底兜底） */
  private restoreDocs(docs: HCDoc[]): void {
    if (docs.length === 0) {
      return;
    }
    const session = this.engine.getDocSessionManager();
    const lm = this.engine.getLayerManager();
    for (let d = 0; d < docs.length; d++) {
      const doc: HCDoc = docs[d];
      session.restoreDoc(doc.docId, doc.fileName, doc.format, doc.pageCount, doc.sourcePath);
      this.docs.push(doc);
      for (let i = 0; i < doc.pageCount; i++) {
        const layer = lm.createLayer(`批注 第${i + 1}页`, 'draw');
        session.bindPageLayer(doc.docId, i, layer.id);
        this.pageStrokes.set(i, []);
      }
    }
    const firstDocId: string = docs[0].docId;
    session.setCurrentDoc(firstDocId);
    session.setCurrentPageIndex(0);
    this.hasDoc = true;
    this.pageCount = session.getCurrentPageCount();
    this.currentPageIndex = 0;
    this.pageIndices = this.rangeArray(this.pageCount);
    const firstLayer: string = session.getPageLayerId(firstDocId, 0);
    if (firstLayer.length > 0) {
      lm.setActiveLayer(firstLayer);
    }
  }

  /** 从持久化 annotations[] 按 pageIndex 路由回对应页批注层（layerId 重新绑定到当次新建的页层） */
  private restoreAnnotations(annotations: HCAnnotation[]): void {
    if (annotations.length === 0) {
      return;
    }
    const session = this.engine.getDocSessionManager();
    for (let i = 0; i < annotations.length; i++) {
      const a: HCAnnotation = annotations[i];
      const pts: PointRecord[] = [];
      const flat: number[] = a.points !== undefined && a.points !== null ? a.points : [];
      const pairCount: number = Math.floor(flat.length / 2);
      for (let k = 0; k < pairCount; k++) {
        pts.push({ x: flat[k * 2], y: flat[k * 2 + 1] });
      }
      // 重新绑定到当次 restoreDocs 新建的页层，保证 pageIndex 强绑（A2-1）
      const boundLayerId: string = session.getPageLayerId(a.docId, a.pageIndex);
      const rec: StrokeRecord = {
        id: this.strokeIdSeq++,
        tool: a.tool,
        color: a.color,
        width: a.width,
        points: pts,
        opacity: a.opacity,
        blendMode: 'normal',
        brushShape: 'round',
        layerId: boundLayerId,
        createdAt: a.createdAt,
      };
      const key: number = a.pageIndex;
      let arr: StrokeRecord[] | undefined = this.pageStrokes.get(key);
      if (arr === undefined) {
        arr = [];
        this.pageStrokes.set(key, arr);
      }
      arr.push(rec);
    }
  }

  // ═══════════════════════════════════════════════════
  // 渲染
  // ═══════════════════════════════════════════════════

  /** 底图层：先铺白底，再叠加当前页位图（无图则白底兜底，绝不白屏崩溃） */
  private renderPaper(): void {
    const w: number = this.canvasWidth;
    const h: number = this.canvasHeight;
    if (w <= 0 || h <= 0) {
      return;
    }
    this.ctxPaper.clearRect(0, 0, w, h);
    this.ctxPaper.fillStyle = HCGray.GRAY_1;
    this.ctxPaper.fillRect(0, 0, w, h);
    const session = this.engine.getDocSessionManager();
    const docId: string = session.getCurrentDocId();
    if (docId.length > 0) {
      const bmp: image.PixelMap | null = session.getPageBitmap(docId, session.getCurrentPageIndex());
      if (bmp !== null) {
        this.ctxPaper.drawImage(bmp, 0, 0, w, h);
      }
    }
  }

  /** 历史层：重绘当前页全部已完成批注（透明背景，叠加在底图之上） */
  private renderHistory(): void {
    const w: number = this.canvasWidth;
    const h: number = this.canvasHeight;
    if (w <= 0 || h <= 0) {
      return;
    }
    this.ctxHistory.clearRect(0, 0, w, h);
    const idx: number = this.engine.getDocSessionManager().getCurrentPageIndex();
    const strokes: StrokeRecord[] | undefined = this.pageStrokes.get(idx);
    if (strokes !== undefined) {
      for (let i = 0; i < strokes.length; i++) {
        this.drawStroke(this.ctxHistory, strokes[i]);
      }
    }
  }

  /** 描边一条批注路径 */
  private drawStroke(ctx: CanvasRenderingContext2D, s: StrokeRecord): void {
    const pts: PointRecord[] = s.points !== undefined && s.points !== null ? s.points : [];
    if (pts.length === 0) {
      return;
    }
    ctx.beginPath();
    ctx.lineWidth = s.width;
    ctx.strokeStyle = s.color;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.globalAlpha = s.opacity;
    ctx.moveTo(pts[0].x, pts[0].y);
    if (pts.length === 1) {
      ctx.lineTo(pts[0].x + 0.1, pts[0].y + 0.1);
    } else {
      for (let i = 1; i < pts.length; i++) {
        ctx.lineTo(pts[i].x, pts[i].y);
      }
    }
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  /**
   * A2 修复（移植自 WhiteboardPage）：显式初始化三层画布的位图缓冲区（像素）并按设备密度缩放上下文。
   * ArkUI 的 Canvas 绘制坐标空间是「像素」，而触摸事件坐标是「vp」。
   * 不显式处理会出现两类问题：
   *   1) 缓冲区为 0x0 → 所有绘制落空，批注完全无反应；
   *   2) 坐标未换算 → 笔迹跑到可见区域之外/左上角。
   * 统一把三层画布设为相同像素缓冲，并把上下文缩放为「1 单位 = 1vp」，之后 vp 坐标绘制精准命中手指。
   */
  private resizeCanvasBuffer(wVp: number, hVp: number): void {
    const dpr: number = vp2px(1); // 1vp 对应的物理像素数 == 设备密度
    const wPx: number = vp2px(wVp);
    const hPx: number = vp2px(hVp);
    const ctxs: CanvasRenderingContext2D[] = [this.ctxPaper, this.ctxHistory, this.ctxActive];
    // 设 修复：不要设置Canvas的width/height属性（只读），避免编译报错
    // Canvas组件会自动适配新尺寸，只需更新变换矩阵即可
    for (let i = 0; i < ctxs.length; i++) {
      const c: CanvasRenderingContext2D = ctxs[i];
      // 重置变换并以密度缩放：之后用 vp 坐标绘制即等价于像素
      c.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    this.canvasWidth = wVp;
    this.canvasHeight = hVp;
  }

  /** 尺寸就绪统一入口：只有从无效变有效或真实变化时才初始化缓冲并全量重绘 */
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
    this.ctxActive.clearRect(0, 0, w, h);
    this.renderPaper();
    this.renderHistory();
  }

  // ═══════════════════════════════════════════════════
  // 绘制（触摸）
  // ═══════════════════════════════════════════════════

  private handleTouch(e: TouchEvent): void {
    if (!this.storageReady || !this.hasDoc) {
      return;
    }
    if (this.currentTool === 'eraser') {
      // 橡皮：命中当前页最近笔画则撤销（简单且直观）
      if (e.type === TouchType.Down || e.type === TouchType.Move) {
        const t = e.touches[0];
        if (t !== undefined) {
          this.eraseAt(t.x, t.y);
        }
      }
      return;
    }
    if (e.type === TouchType.Down) {
      const t = e.touches[0];
      if (t !== undefined) {
        this.drawing = true;
        this.currentPoints = [{ x: t.x, y: t.y }];
      }
    } else if (e.type === TouchType.Move && this.drawing) {
      const t = e.touches[0];
      if (t !== undefined) {
        this.currentPoints.push({ x: t.x, y: t.y });
        // C-3：清活动层 + 整条路径一次性重绘，半透明笔浓度恒定
        this.ctxActive.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
        this.drawStroke(this.ctxActive, this.previewRecord());
      }
    } else if (e.type === TouchType.Up || e.type === TouchType.Cancel) {
      if (this.drawing) {
        this.commitStroke();
        this.drawing = false;
      }
    }
  }

  private previewRecord(): StrokeRecord {
    return {
      id: -1,
      tool: 'pen',
      color: this.penColors[this.currentColorIndex],
      width: this.penWidths[this.currentWidthIndex],
      points: this.currentPoints.slice(),
      opacity: 1,
      blendMode: 'normal',
      brushShape: 'round',
      layerId: '',
      createdAt: Date.now(),
    };
  }

  /** 提交当前笔画到当前页批注层 */
  private commitStroke(): void {
    if (this.currentPoints.length === 0) {
      return;
    }
    const session = this.engine.getDocSessionManager();
    const docId: string = session.getCurrentDocId();
    const idx: number = session.getCurrentPageIndex();
    const layerId: string = session.getPageLayerId(docId, idx);
    const rec: StrokeRecord = {
      id: this.strokeIdSeq++,
      tool: 'pen',
      color: this.penColors[this.currentColorIndex],
      width: this.penWidths[this.currentWidthIndex],
      points: this.currentPoints.slice(),
      opacity: 1,
      blendMode: 'normal',
      brushShape: 'round',
      layerId: layerId,
      createdAt: Date.now(),
    };
    let arr: StrokeRecord[] | undefined = this.pageStrokes.get(idx);
    if (arr === undefined) {
      arr = [];
      this.pageStrokes.set(idx, arr);
    }
    arr.push(rec);
    this.markDirty();
    this.renderHistory();
    this.ctxActive.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    this.currentPoints = [];
    this.statusText = `第 ${idx + 1} / ${this.pageCount} 页 · ${arr.length} 笔`;
  }

  /** 橡皮：删除当前页命中点的最后一条笔画 */
  private eraseAt(x: number, y: number): void {
    const idx: number = this.engine.getDocSessionManager().getCurrentPageIndex();
    const arr: StrokeRecord[] | undefined = this.pageStrokes.get(idx);
    if (arr === undefined || arr.length === 0) {
      return;
    }
    for (let i = arr.length - 1; i >= 0; i--) {
      if (this.hitStroke(arr[i], x, y)) {
        arr.splice(i, 1);
        this.markDirty();
        this.renderHistory();
        this.statusText = `第 ${idx + 1} 页 · 已擦除 1 笔`;
        return;
      }
    }
  }

  private hitStroke(s: StrokeRecord, x: number, y: number): boolean {
    const pts: PointRecord[] = s.points !== undefined && s.points !== null ? s.points : [];
    const tol: number = s.width + 8;
    for (let i = 0; i < pts.length; i++) {
      const dx: number = pts[i].x - x;
      const dy: number = pts[i].y - y;
      if (dx * dx + dy * dy <= tol * tol) {
        return true;
      }
    }
    return false;
  }

  // ═══════════════════════════════════════════════════
  // 翻页（A2-1 强绑核心：只切当前页，不串页）
  // ═══════════════════════════════════════════════════

  private goToPage(target: number): void {
    if (!this.storageReady || !this.hasDoc) {
      return;
    }
    const session = this.engine.getDocSessionManager();
    session.setCurrentPageIndex(target);
    const idx: number = session.getCurrentPageIndex();
    this.currentPageIndex = idx;
    const layerId: string = session.getPageLayerId(session.getCurrentDocId(), idx);
    if (layerId.length > 0) {
      this.engine.getLayerManager().setActiveLayer(layerId);
    }
    this.ctxActive.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    this.renderPaper();
    this.renderHistory();
    this.markDirty();
  }

  private prevPage(): void {
    this.goToPage(this.currentPageIndex - 1);
  }

  private nextPage(): void {
    this.goToPage(this.currentPageIndex + 1);
  }

  // ═══════════════════════════════════════════════════
  // 保存
  // ═══════════════════════════════════════════════════

  private startAutoSave(): void {
    if (this.saveTimer !== -1) {
      return;
    }
    this.saveTimer = setInterval((): void => {
      if (this.dirty && !this.saving) {
        this.flushSave();
      }
    }, AUTOSAVE_INTERVAL_MS);
  }

  private stopAutoSave(): void {
    if (this.saveTimer !== -1) {
      clearInterval(this.saveTimer);
      this.saveTimer = -1;
    }
  }

  private markDirty(): void {
    if (this.noteId.length === 0) {
      return;
    }
    this.dirty = true;
    if (this.saveState !== NoteSaveState.SAVING) {
      this.saveState = NoteSaveState.IDLE;
    }
  }

  /** 收集全部批注笔画（落盘的 strokes 投影，供 composeNoteContent 复用） */
  private allRecords(): StrokeRecord[] {
    const result: StrokeRecord[] = [];
    this.pageStrokes.forEach((recs: StrokeRecord[]): void => {
      for (let i = 0; i < recs.length; i++) {
        result.push(recs[i]);
      }
    });
    return result;
  }

  /** 由 pageStrokes 导出强绑 pageIndex 的批注 DTO 列表 */
  private collectAnnotations(): HCAnnotation[] {
    const result: HCAnnotation[] = [];
    const docId: string = this.engine.getDocSessionManager().getCurrentDocId();
    if (docId.length === 0) {
      return result;
    }
    this.pageStrokes.forEach((recs: StrokeRecord[], idx: number): void => {
      for (let i = 0; i < recs.length; i++) {
        const r: StrokeRecord = recs[i];
        const flat: number[] = [];
        const pts: PointRecord[] = r.points !== undefined && r.points !== null ? r.points : [];
        for (let k = 0; k < pts.length; k++) {
          flat.push(pts[k].x);
          flat.push(pts[k].y);
        }
        result.push({
          id: `a_${r.id}`,
          docId: docId,
          pageIndex: idx,
          layerId: r.layerId,
          tool: r.tool,
          color: r.color,
          width: r.width,
          opacity: r.opacity,
          points: flat,
          createdAt: r.createdAt,
          createdBy: HC_LOCAL_AUTHOR,
        });
      }
    });
    return result;
  }

  /** 落盘：compose 出 NoteContent，注入 docs / annotations，调仓储保存 */
  private flushSave(): void {
    if (!this.storageReady || this.noteId.length === 0 || !this.dirty || this.saving) {
      return;
    }
    this.saving = true;
    this.saveState = NoteSaveState.SAVING;
    const repo: NoteRepository = this.engine.getNoteRepository();
    const records: StrokeRecord[] = this.allRecords();
    const content: NoteContent = this.engine.composeNoteContent(
      this.noteMeta, HC_DEFAULT_PAPER, this.paperLayerId, records, [], this.canvasWidth, this.canvasHeight, this.forwardRaw
    );
    // T2-1：注入文档元信息与强绑页的批注列表
    content.docs = this.docs.slice();
    content.annotations = this.collectAnnotations();
    SafeAsync.runAsyncVoid(TAG_PAGE, 'save', async (): Promise<void> => {
      const res: NoteSaveResult = await repo.saveNote(content, true);
      this.saving = false;
      if (res.ok) {
        this.dirty = false;
        this.saveState = NoteSaveState.SAVED;
        this.saveFailReason = 'unknown';
        this.statusText = '已保存批注';
      } else {
        // T2-1b C-6/C-7：失败态只由 chip 承载（移除 statusText 双写——共享行会被后续信息覆盖且底色误导）
        this.saveState = NoteSaveState.FAILED;
        this.saveFailReason = res.failureKind !== null && res.failureKind !== undefined
          ? res.failureKind : 'unknown';
      }
    }, (info: SafeErrorInfo): void => {
      this.saving = false;
      this.saveState = NoteSaveState.FAILED;
      this.saveFailReason = 'unknown';
    });
  }

  private async onBack(): Promise<void> {
    await this.flushSave();
    router.back();
  }

  // ═══════════════════════════════════════════════════
  // 错误提示（A2-2）
  // ═══════════════════════════════════════════════════

  private showErrorDialog(message: string): void {
    this.errorMessage = message;
    this.showError = true;
  }

  // ═══════════════════════════════════════════════════
  // UI
  // ═══════════════════════════════════════════════════

  build() {
    Column() {
      // 顶栏
      Row() {
        BackButton({ onBack: (): void => { this.onBack(); } })
        Text(this.noteTitle)
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.hasDoc) {
          Text(`第 ${this.currentPageIndex + 1}/${this.pageCount} 页`)
            .fontSize(13)
            .fontColor(HCColor.TEXT_TERTIARY)
            .padding({ right: 8 })

          // F-04 任务 B：把手写批注写回 PDF 并另存
          Text(this.exporting ? '导出中…' : '导出批注')
            .fontSize(14)
            .fontColor(this.exporting ? HCColor.ICON_SECONDARY : HCColor.PRIMARY)
            .backgroundColor(HCColor.PRIMARY_BG)
            .borderRadius(8)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .margin({ right: 8 })
            .enabled(!this.exporting)
            .onClick((): void => {
              SafeAsync.runAsyncVoid(TAG_PAGE, 'exportClick', async (): Promise<void> => {
                await this.onExportAnnotatedPdf();
              }, (info: SafeErrorInfo): void => {
                this.exporting = false;
                this.statusText = `导出失败：${info.message}`;
              });
            })
        }

        // F-04：PDF 导入已接入系统 PDF Kit 真实渲染，解除"敬请期待"拦截
        Text(this.importing ? '导入中…' : '导入PDF')
          .fontSize(14)
          .fontColor(this.importing ? HCColor.ICON_SECONDARY : HCColor.SURFACE)
          .backgroundColor(this.importing ? HCColor.BORDER : HCColor.PRIMARY)
          .borderRadius(8)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .margin({ right: 12 })
          .enabled(!this.importing)
          .onClick((): void => {
            SafeAsync.runAsyncVoid(TAG_PAGE, 'importClick', async (): Promise<void> => {
              await this.onImport();
            }, (info: SafeErrorInfo): void => {
              this.importing = false;
              this.statusText = `导入失败：${info.message}`;
            });
          })
      }
      .width('100%')
      .height(48)
      .backgroundColor(HCColor.PAGE_BG)

      // 画布区
      Stack() {
        // 底图层（文档页位图）
        Canvas(this.ctxPaper)
          .width('100%')
          .height('100%')
          .backgroundColor(HCColor.SURFACE)
          .onReady((): void => {
            this.renderPaper();
          })
          .onAreaChange((_o: Area, n: Area): void => {
            this.ensureCanvasSize(Number(n.width), Number(n.height));
          })

        // 历史层（已完成批注）— 必须透明（C-2）
        Canvas(this.ctxHistory)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.None)
          .onAreaChange((_o: Area, n: Area): void => {
            this.ensureCanvasSize(Number(n.width), Number(n.height));
          })

        // 活动层（当前笔迹）— 必须透明（C-2）
        Canvas(this.ctxActive)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Transparent)
          .onReady((): void => {
            this.canvasReady = true;
            // 兜底：若 onAreaChange 尚未给出尺寸，用缓冲区实际像素反推 vp 尺寸并初始化
            if (this.canvasWidth <= 0 || this.canvasHeight <= 0) {
              const pxW: number = this.ctxActive.width;
              const pxH: number = this.ctxActive.height;
              if (pxW > 0 && pxH > 0) {
                this.resizeCanvasBuffer(px2vp(pxW), px2vp(pxH));
              }
            }
            if (this.canvasWidth > 0 && this.canvasHeight > 0) {
              this.renderPaper();
              this.renderHistory();
            }
          })
          .onAreaChange((_o: Area, n: Area): void => {
            this.ensureCanvasSize(Number(n.width), Number(n.height));
          })
          .onTouch((e: TouchEvent): void => {
            this.handleTouch(e);
          })

        // 未导入文档时的引导
        // 🔴 v2.7.6 审核修复（问题③「提示点击右上角导入PDF，但右上角没有该按钮」）
        //   真因：引导文案让用户去"右上角"找按钮，而顶栏在窄屏/状态栏避让下该按钮可能不可见，
        //   用户按提示找不到入口 → 判为功能异常。
        //   修法：把「导入 PDF」做成**页面内正中的大按钮**（不再依赖右上角），
        //   同时解除本区域原先的 `hitTestBehavior(None)`（它会让按钮完全点不动）。
        if (!this.hasDoc) {
          Column() {
            Text('暂无文档')
              .fontSize(18)
              .fontColor(HCColor.ICON_SECONDARY)
            Text(`选择 PDF 文件开始批注（免费版最多 ${MAX_IMPORT_PAGES} 页）`)
              .fontSize(13)
              .fontColor(HCColor.TEXT_DISABLED)
              .margin({ top: 8, bottom: 16 })

            Button(this.importing ? '导入中…' : '导入 PDF')
              .width(180)
              .height(44)
              .fontSize(16)
              .fontColor(HCColor.SURFACE)
              .backgroundColor(this.importing ? HCColor.BORDER : HCColor.PRIMARY)
              .borderRadius(22)
              .enabled(!this.importing)
              .onClick((): void => {
                SafeAsync.runAsyncVoid(TAG_PAGE, 'importClickCenter', async (): Promise<void> => {
                  await this.onImport();
                }, (info: SafeErrorInfo): void => {
                  this.importing = false;
                  this.statusText = `导入失败：${info.message}`;
                });
              })
          }
          // 允许点击（原先为 HitTestMode.None，会导致按钮无法交互）
          .hitTestBehavior(HitTestMode.Default)
        }

        // 状态条（T2-1b C-7：胶囊底色由严重性驱动，FAILED→ALERT 红底白字，不再硬编码绿）
        Row() {
          Text(this.statusText)
            .fontSize(11)
            .fontColor(statusPalette(this.saveState === NoteSaveState.FAILED ? StatusSeverity.ALERT : StatusSeverity.ROUTINE).foreground)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.noteId.length > 0) {
            Text(noteSaveStateText(this.saveState, this.saveState === NoteSaveState.FAILED ? this.saveFailReason : undefined))
              .fontSize(11)
              .fontColor(statusPalette(this.saveState === NoteSaveState.FAILED ? StatusSeverity.ALERT : StatusSeverity.ROUTINE).foreground)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              // C-6：失败态 chip 可点（最低限度补 onClick 重试）
              .onClick(() => {
                if (this.saveState === NoteSaveState.FAILED) {
                  this.flushSave();
                }
              })
          }
        }
        .backgroundColor(statusPalette(this.saveState === NoteSaveState.FAILED ? StatusSeverity.ALERT : StatusSeverity.ROUTINE).background)
        .borderRadius(10)
        .constraintSize({ maxWidth: '70%' })
        .position({ x: '15%', y: 4 })
      }
      .width('100%')
      .layoutWeight(1)
      .flexGrow(1)
      .constraintSize({ minHeight: 500 })
      .clip(true)
      .onAreaChange((_o: Area, n: Area): void => {
        // A2 修复：统一走 ensureCanvasSize，避免首次 0x0 后永久失效
        this.ensureCanvasSize(Number(n.width), Number(n.height));
      })

      // 缩略图页码条
      if (this.hasDoc && this.pageIndices.length > 0) {
        Scroll() {
          Row() {
            ForEach(this.pageIndices, (idx: number): void => {
              Column() {
                Text(`${idx + 1}`)
                  .fontSize(12)
                  .fontColor(idx === this.currentPageIndex ? HCColor.SURFACE : HCColor.TEXT_PRIMARY)
                if (idx === this.currentPageIndex) {
                  Text('●')
                    .fontSize(8)
                    .fontColor(HCColor.PRIMARY)
                    .margin({ top: 2 })
                }
              }
              .width(36)
              .height(44)
              .borderRadius(6)
              .backgroundColor(idx === this.currentPageIndex ? HCColor.PRIMARY : HCColor.DIVIDER)
              .justifyContent(FlexAlign.Center)
              .margin({ right: 6 })
              .onClick((): void => {
                this.goToPage(idx);
              })
            }, (idx: number): string => `${idx}`)
          }
          .padding({ left: 8, right: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
        .height(52)
        .backgroundColor(HCColor.PAGE_BG)
      }

      // 工具栏
      Row() {
        // 上一页 / 下一页
        Text('‹')
          .fontSize(22)
          .fontColor(this.currentPageIndex > 0 ? HCColor.PRIMARY : HCColor.TEXT_DISABLED)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .onClick((): void => {
            this.prevPage();
          })
        Text('›')
          .fontSize(22)
          .fontColor(this.currentPageIndex < this.pageCount - 1 ? HCColor.PRIMARY : HCColor.TEXT_DISABLED)
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .onClick((): void => {
            this.nextPage();
          })

        // 颜色选择
        ForEach(this.penColors, (c: string, ci: number): void => {
          Circle({ width: 24, height: 24 })
            .fill(c)
            .stroke(this.currentColorIndex === ci ? HCColor.PRIMARY : HCColor.BORDER)
            .strokeWidth(2)
            .margin({ left: 6, right: 6 })
            .onClick((): void => {
              this.currentColorIndex = ci;
              this.currentTool = 'pen';
            })
        }, (c: string): string => c)

        // 笔宽
        ForEach(this.penWidths, (w: number, wi: number): void => {
          Text('●')
            .fontSize(w + 4)
            .fontColor(this.currentTool === 'pen' && this.currentWidthIndex === wi ? HCColor.PRIMARY : HCColor.TEXT_TERTIARY)
            .margin({ left: 6, right: 6 })
            .onClick((): void => {
              this.currentWidthIndex = wi;
              this.currentTool = 'pen';
            })
        }, (w: number): string => `w${w}`)

        // 橡皮
        Text('橡皮')
          .fontSize(13)
          .fontColor(this.currentTool === 'eraser' ? HCColor.SURFACE : HCColor.TEXT_TERTIARY)
          .backgroundColor(this.currentTool === 'eraser' ? HCBrand.RED_DEEP : HCColor.DIVIDER)
          .borderRadius(6)
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .margin({ left: 10 })
          .onClick((): void => {
            this.currentTool = this.currentTool === 'eraser' ? 'pen' : 'eraser';
          })
      }
      .width('100%')
      .backgroundColor(HCColor.PAGE_BG)
      .padding({ top: 4, bottom: 4 })

      // 错误对话框（A2-2 不静默失败）
      if (this.showError) {
        Column() {
          Text('提示')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .margin({ bottom: 12 })
          Text(this.errorMessage)
            .fontSize(14)
            .fontColor(HCColor.TEXT_PRIMARY)
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 16 })
          Text('我知道了')
            .fontSize(15)
            .fontColor(HCColor.SURFACE)
            .backgroundColor(HCColor.PRIMARY)
            .borderRadius(8)
            .padding({ left: 20, right: 20, top: 8, bottom: 8 })
            .onClick((): void => {
              this.showError = false;
            })
        }
        .position({ x: '50%', y: '50%' })
        .translate({ x: '-50%', y: '-50%' })
        .backgroundColor(HCColor.SURFACE)
        .borderRadius(12)
        .padding(20)
        .shadow({ radius: 12, color: HCOverlay.SHADE_13 })
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
}
