/**
 * DocSessionManager.ets — 文档导入会话管理（T2-1 阶段二「文档导入与批注页」）
 *
 * 职责（架构 §3.2 / NP-05/06）：
 *  1. 桥接已有的 DocumentImporter.ets（PDF 识别 → 栅格化 → 创建只读 PageLayer）与
 *     PDFRasterizer.ets（白底位图）；**仅接不改**这两个连接器；
 *  2. 维护导入文档会话态：
 *     - docId → DocMeta（页列表 / 页尺寸 / pageRefs）；
 *     - docId → (pageIndex → 批注图层 id) 映射，即「批注笔迹层与 pageIndex 强绑」的运行时保证；
 *     - 当前文档 id 与当前页码（翻页状态）。
 *  3. 向 AnnotationPage 暴露取位图 / 取页图层 / 翻页状态等只读查询，页面层不直接 import
 *     DocumentImporter（铁律 2 / F-1）。
 *
 * 设计要点：
 *  - 位图缓存全部委托给 DocumentImporter（其 docBitmaps 已按 docId 缓存 RasterizedPage），
 *    本类不重复持有位图，避免内存双份；
 *  - 批注图层由 AnnotationPage 经 LayerManager 创建（每页一个 draw 层），此处只记录映射，
 *    翻页切换时由页面层切 activeLayer，从而保证「翻页批注不错位（A2-1）」；
 *  - 所有公开方法对非法 docId / 越界 pageIndex 健壮返回（空串 / null / 0），绝不抛异常。
 *
 * ArkTS 严格模式：无 any/unknown、显式泛型、SafeAsync 包裹归一异常。
 */

import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import { common } from '@kit.AbilityKit';
import { Logger } from '../../common/Logger';
import { SafeAsync } from '../../common/utils/SafeAsync';
import { DocumentImporter, DocMeta } from './DocumentImporter';
import { PDFAnnotationWriter, PageInkVO, InkExportResult } from './PDFAnnotationWriter';

const TAG_MODULE = 'DocSessionManager';

/** 页尺寸结构 */
interface PageSize {
  width: number;
  height: number;
}

/** 页 → 批注图层映射（docId 维度） */
interface PageLayerBindings {
  /** pageIndex → 该页批注图层 id（AnnotationPage 创建） */
  byPageIndex: Map<number, string>;
}

export class DocSessionManager {
  private static instance: DocSessionManager | null = null;

  /** 已导入文档元信息（docId → DocMeta） */
  private readonly docs: Map<string, DocMeta> = new Map();

  /** 文档 → 页批注图层映射 */
  private readonly pageLayers: Map<string, PageLayerBindings> = new Map();

  /** 当前激活文档 id（空串表示无） */
  private currentDocId: string = '';

  /** 当前页码（0 基） */
  private currentPageIndex: number = 0;

  /** 文档导入器桥接（单例，仅持有引用，不改其实现） */
  private readonly importer: DocumentImporter;

  private constructor() {
    // DocumentImporter 为单例，此处仅作桥接持有引用
    this.importer = DocumentImporter.getInstance();
  }

  static getInstance(): DocSessionManager {
    if (DocSessionManager.instance === null) {
      DocSessionManager.instance = new DocSessionManager();
    }
    return DocSessionManager.instance;
  }

  // ═══════════════════════════════════════════════════
  // 一、导入（桥接 DocumentImporter）
  // ═══════════════════════════════════════════════════

  /**
   * 导入一个文档文件（PDF/EPUB/CAJ）。
   * 成功返回 DocMeta；CAJ / EPUB / 不支持格式会抛出 DocumentImportError（A2-2 降级由调用方捕获文案）。
   *
   * @param path     沙箱路径（来自 DocumentViewPicker）
   * @param fileName 文件名（缺省时从 path 提取）
   */
  async importDocument(path: string, fileName?: string): Promise<DocMeta> {
    const meta: DocMeta = await this.importer.import(path, fileName);
    this.docs.set(meta.docId, meta);
    // 初始化页批注图层映射（尚无批注层，待 AnnotationPage 逐页绑定）
    this.pageLayers.set(meta.docId, { byPageIndex: new Map<number, string>() });
    this.currentDocId = meta.docId;
    this.currentPageIndex = 0;
    Logger.info(TAG_MODULE, `导入成功 docId=${meta.docId} pages=${meta.pageCount} file=${meta.fileName}`);
    return meta;
  }

  /** 取已导入文档元信息；不存在返回 null */
  getDocMeta(docId: string): DocMeta | null {
    const m: DocMeta | undefined = this.docs.get(docId);
    return m !== undefined ? m : null;
  }

  /**
   * 从持久化内容恢复文档会话（重载场景：无位图，仅元信息 + 页数）。
   * 用于 AnnotationPage 打开既有批注笔记时，按 docs[] 重建分页与页图层绑定骨架。
   */
  restoreDoc(docId: string, fileName: string, format: string, pageCount: number, sourcePath: string = ''): void {
    const meta: DocMeta = {
      docId: docId,
      fileName: fileName,
      format: format,
      pageCount: Math.max(0, pageCount),
      pageLayers: [],
      rasterized: false,
    };
    this.docs.set(docId, meta);
    this.pageLayers.set(docId, { byPageIndex: new Map<number, string>() });
    // F-04 任务 B+：把持久化的源 PDF 路径注入导入器，使「杀掉 App 重开」后仍能导出批注
    if (sourcePath.length > 0) {
      this.importer.setDocSourcePath(docId, sourcePath);
    }
    Logger.info(TAG_MODULE, `恢复文档会话 docId=${docId} pages=${meta.pageCount}`);
  }

  /** 列出全部已导入文档（按导入顺序，先入先出） */
  listDocs(): DocMeta[] {
    const result: DocMeta[] = [];
    this.docs.forEach((value: DocMeta): void => {
      result.push(value);
    });
    return result;
  }

  // ═══════════════════════════════════════════════════
  // 二、位图查询（委托 DocumentImporter 缓存）
  // ═══════════════════════════════════════════════════

  /** 取某页位图（只读底图）。无图 / 越界返回 null，页面层据此画白底兜底 */
  getPageBitmap(docId: string, pageIndex: number): image.PixelMap | null {
    return this.importer.getPageBitmap(docId, pageIndex);
  }

  /** 文档页数（越界 / 未知返回 0）。优先用已存 DocMeta.pageCount，避免重载后位图缓存清空导致计数归零 */
  getPageCount(docId: string): number {
    const meta: DocMeta | null = this.getDocMeta(docId);
    if (meta !== null) {
      return meta.pageCount;
    }
    return this.importer.getDocPageCount(docId);
  }

  /** 某文档某页尺寸（用于画布按页适配）；未知返回 0 */
  getPageSize(docId: string, pageIndex: number): PageSize {
    const meta: DocMeta | null = this.getDocMeta(docId);
    if (meta === null) {
      const result: PageSize = { width: 0, height: 0 };
      return result;
    }
    for (let i = 0; i < meta.pageLayers.length; i++) {
      const info = meta.pageLayers[i];
      if (info.pageIndex === pageIndex) {
        const found: PageSize = { width: info.width, height: info.height };
        return found;
      }
    }
    const empty: PageSize = { width: 0, height: 0 };
    return empty;
  }

  // ═══════════════════════════════════════════════════
  // 三、页批注图层绑定（A2-1 强绑核心）
  // ═══════════════════════════════════════════════════

  /** 绑定某页的批注图层 id（AnnotationPage 每页创建一个 draw 层后调用） */
  bindPageLayer(docId: string, pageIndex: number, layerId: string): void {
    let bindings: PageLayerBindings | undefined = this.pageLayers.get(docId);
    if (bindings === undefined) {
      bindings = { byPageIndex: new Map<number, string>() };
      this.pageLayers.set(docId, bindings);
    }
    bindings.byPageIndex.set(pageIndex, layerId);
  }

  /** 取某页批注图层 id；未绑定返回空串 */
  getPageLayerId(docId: string, pageIndex: number): string {
    const bindings: PageLayerBindings | undefined = this.pageLayers.get(docId);
    if (bindings === undefined) {
      return '';
    }
    const id: string | undefined = bindings.byPageIndex.get(pageIndex);
    return id !== undefined ? id : '';
  }

  /** 是否存在已绑定的批注图层 */
  hasPageLayer(docId: string, pageIndex: number): boolean {
    return this.getPageLayerId(docId, pageIndex).length > 0;
  }

  // ═══════════════════════════════════════════════════
  // 四、当前会话（翻页状态）
  // ═══════════════════════════════════════════════════

  /** 设置当前文档（同时把页码夹到合法范围） */
  setCurrentDoc(docId: string): void {
    if (!this.docs.has(docId)) {
      Logger.warn(TAG_MODULE, `setCurrentDoc：未知 docId=${docId}，忽略`);
      return;
    }
    this.currentDocId = docId;
    const count: number = this.getPageCount(docId);
    if (this.currentPageIndex >= count) {
      this.currentPageIndex = count > 0 ? count - 1 : 0;
    }
  }

  getCurrentDocId(): string {
    return this.currentDocId;
  }

  getCurrentPageIndex(): number {
    return this.currentPageIndex;
  }

  setCurrentPageIndex(pageIndex: number): void {
    const count: number = this.currentDocId.length > 0 ? this.getPageCount(this.currentDocId) : 0;
    if (count <= 0) {
      this.currentPageIndex = 0;
      return;
    }
    if (pageIndex < 0) {
      this.currentPageIndex = 0;
    } else if (pageIndex >= count) {
      this.currentPageIndex = count - 1;
    } else {
      this.currentPageIndex = pageIndex;
    }
  }

  /** 当前文档页数 */
  getCurrentPageCount(): number {
    return this.currentDocId.length > 0 ? this.getPageCount(this.currentDocId) : 0;
  }

  // ═══════════════════════════════════════════════════
  // 四点五、批注写回 PDF（F-04 任务 B）
  // ═══════════════════════════════════════════════════

  /** 当前设备是否支持"导出带手写批注的 PDF" */
  isInkExportSupported(): boolean {
    return PDFAnnotationWriter.isSupported();
  }

  /**
   * 把手写批注以标准 PDF Ink 批注写回并另存到应用沙箱 files/exports/ 下。
   * 页面层只需传"页码 + 该页画布尺寸 + 笔迹"，路径与 PDF Kit 细节全部封装在引擎层。
   *
   * 任何失败都通过 InkExportResult.success=false + 中文 message 返回，不抛异常。
   */
  async exportAnnotatedPdf(docId: string, pages: PageInkVO[]): Promise<InkExportResult> {
    const meta: DocMeta | null = this.getDocMeta(docId);
    if (meta === null) {
      return DocSessionManager.exportFailure('未找到文档会话，请重新导入后再导出');
    }
    if (meta.format !== 'pdf') {
      return DocSessionManager.exportFailure('仅 PDF 文档支持导出带批注的副本');
    }
    const source: string = this.importer.getDocSourcePath(docId);
    if (source.length === 0) {
      return DocSessionManager.exportFailure('源 PDF 路径丢失（可能是重载后恢复的会话），请重新导入后再导出');
    }
    const outputPath: string = this.buildExportPath(meta.fileName);
    if (outputPath.length === 0) {
      return DocSessionManager.exportFailure('无法创建导出目录，请检查存储空间');
    }
    const writer: PDFAnnotationWriter = new PDFAnnotationWriter();
    const result: InkExportResult = await writer.exportWithInk(source, outputPath, pages);
    Logger.info(TAG_MODULE, `导出带批注 PDF docId=${docId} success=${result.success} msg=${result.message}`);
    return result;
  }

  /** 生成导出目标路径 filesDir/exports/{原名}_批注_{时间戳}.pdf；失败返回空串 */
  private buildExportPath(fileName: string): string {
    try {
      const ctx = getContext() as common.UIAbilityContext;
      if (ctx === undefined || ctx === null || ctx.filesDir === undefined) {
        return '';
      }
      const dir: string = `${ctx.filesDir}/exports`;
      try {
        fs.accessSync(dir);
      } catch (notExist) {
        fs.mkdirSync(dir, true);
      }
      const dot: number = fileName.lastIndexOf('.');
      const base: string = dot > 0 ? fileName.substring(0, dot) : fileName;
      const safeBase: string = base.replace(/[\\/:*?"<>|]/g, '_').substring(0, 60);
      const stem: string = safeBase.length > 0 ? safeBase : 'document';
      return `${dir}/${stem}_annotated_${Date.now()}.pdf`;
    } catch (e) {
      Logger.error(TAG_MODULE, `buildExportPath 失败: ${SafeAsync.describe(e as Error)}`);
      return '';
    }
  }

  private static exportFailure(message: string): InkExportResult {
    const result: InkExportResult = {
      success: false,
      outputPath: '',
      pageCount: 0,
      strokeCount: 0,
      skippedCount: 0,
      message: message,
    };
    return result;
  }

  // ═══════════════════════════════════════════════════
  // 五、清理
  // ═══════════════════════════════════════════════════

  /** 移除单个文档会话（位图缓存一并清除） */
  removeDoc(docId: string): void {
    this.docs.delete(docId);
    this.pageLayers.delete(docId);
    this.importer.clearDoc(docId);
    if (this.currentDocId === docId) {
      this.currentDocId = '';
      this.currentPageIndex = 0;
    }
    Logger.info(TAG_MODULE, `会话移除 docId=${docId}`);
  }

  /** 清空全部会话态（退出批注页时调用） */
  clearSession(): void {
    SafeAsync.runVoid(TAG_MODULE, 'clearSession', (): void => {
      this.docs.forEach((_value: DocMeta, key: string): void => {
        this.importer.clearDoc(key);
      });
      this.docs.clear();
      this.pageLayers.clear();
      this.currentDocId = '';
      this.currentPageIndex = 0;
    });
  }
}
