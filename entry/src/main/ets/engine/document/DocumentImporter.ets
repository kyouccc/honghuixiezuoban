/**
 * DocumentImporter.ets — 文档导入门面（v2.0 增量，S1T02 / NP-05/06）
 *
 * 类型识别（PDF/EPUB/CAJ）→ 选择栅格化器 → 栅格化为位图页面 →
 * 通过 LayerManager 创建只读 PageLayer（type='page'，绑定 pageRef）。
 *
 * 语义（架构 §1.1 / §8.1）：
 *  - 导入页面为只读底图（PageLayer，继承纸图层语义），不参与 CRDT 笔迹收敛；
 *  - 批注笔迹叠加在上层批注图层（AnnotationData.pageIndex 绑定页面号，NP-06）；
 *  - CAJ 降级 P1（Q-01 决策）：端侧提示"请转换为 PDF 后导入"；
 *  - EPUB 栅格化 P1（架构文件列表 EPUBRasterizer 可选），类型识别先行。
 */

import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { common } from '@kit.AbilityKit';
import { Logger } from '../../common/Logger';
import { SafeAsync } from '../../common/utils/SafeAsync';
import { Constants } from '../../common/Constants';
import { LayerManager } from '../LayerManager';
import {
  ITextRasterizer,
  RasterizedPage,
  RasterizeOptions,
  DocumentRasterizeError,
  DOC_RASTERIZE_ERROR_CODE,
} from './ITextRasterizer';
import { PDFRasterizer } from './PDFRasterizer';

const TAG_MODULE = 'DocumentImporter';

export enum DocFormat {
  PDF = 'pdf',
  EPUB = 'epub',
  CAJ = 'caj',
  UNKNOWN = 'unknown',
}

export interface PageLayerInfo {
  pageIndex: number;
  layerId: string;
  width: number;
  height: number;
}

export interface DocMeta {
  docId: string;
  fileName: string;
  format: string;
  pageCount: number;
  pageLayers: PageLayerInfo[];
  rasterized: boolean;
}

/** 文档导入异常（code 对齐 REST 错误码，1105=文档栅格化失败） */
export class DocumentImportError extends Error {
  code: number;
  detail: string;

  constructor(code: number, detail: string) {
    super(detail);
    this.code = code;
    this.detail = detail;
  }
}

export class DocumentImporter {
  private static instance: DocumentImporter | null = null;
  private rasterizers: Map<string, ITextRasterizer> = new Map();
  private docBitmaps: Map<string, RasterizedPage[]> = new Map();
  /** F-04 任务 B：docId → 源文件沙箱路径（批注写回时作为写入源） */
  private docSources: Map<string, string> = new Map();

  static getInstance(): DocumentImporter {
    if (!DocumentImporter.instance) {
      DocumentImporter.instance = new DocumentImporter();
    }
    return DocumentImporter.instance;
  }

  private constructor() {
    this.registerRasterizer(DocFormat.PDF, new PDFRasterizer());
  }

  registerRasterizer(format: string, rasterizer: ITextRasterizer): void {
    this.rasterizers.set(format, rasterizer);
  }

  /** 文件类型识别（PDF/EPUB/CAJ/UNKNOWN） */
  detectFormat(fileName: string): string {
    const lower: string = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return DocFormat.PDF;
    }
    if (lower.endsWith('.epub')) {
      return DocFormat.EPUB;
    }
    if (lower.endsWith('.caj')) {
      return DocFormat.CAJ;
    }
    return DocFormat.UNKNOWN;
  }

  /**
   * 导入文档：识别格式 → 栅格化 → 创建 PageLayer 数组。
   * @param path 文件沙箱路径
   * @param fileName 文件名（缺省时从 path 提取）
   * @param options 栅格化选项（缺省用免费版上限 10 页）
   */
  async import(path: string, fileName?: string, options?: RasterizeOptions): Promise<DocMeta> {
    const name: string = fileName !== undefined && fileName.length > 0 ? fileName : this.extractFileName(path);
    const format: string = this.detectFormat(name);
    if (format === DocFormat.CAJ) {
      throw new DocumentImportError(DOC_RASTERIZE_ERROR_CODE, 'CAJ 格式暂不支持（Q-01 降级），请转换为 PDF 后导入');
    }
    if (format === DocFormat.EPUB) {
      throw new DocumentImportError(DOC_RASTERIZE_ERROR_CODE, 'EPUB 栅格化将在 P1 提供，当前支持 PDF 导入');
    }
    if (format === DocFormat.UNKNOWN) {
      throw new DocumentImportError(DOC_RASTERIZE_ERROR_CODE, '不支持的文档格式（支持 PDF/EPUB/CAJ）');
    }
    const docId: string = `doc_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    // F-04 任务 B+：先把源 PDF 持久化到 filesDir/docs/{docId}/source.pdf，
    // 该副本在「杀掉 App 重开」后仍然存在，是批注写回另存的输入（满足验收标准）。
    const persistentSource: string = this.copySourceToPersistentStorage(path, docId);
    // 栅格化输入统一用持久化沙箱副本（已是沙箱路径，PDFRasterizer 内部不再二次拷贝）
    const effectivePath: string = persistentSource.length > 0 ? persistentSource : path;
    const rasterizer: ITextRasterizer | undefined = this.rasterizers.get(format);
    if (rasterizer === undefined) {
      throw new DocumentImportError(DOC_RASTERIZE_ERROR_CODE, `未注册 ${format} 栅格化器`);
    }
    const opts: RasterizeOptions = this.normalizeOptions(options);
    let pages: RasterizedPage[];
    try {
      pages = await rasterizer.rasterize(effectivePath, opts);
    } catch (e) {
      if (e instanceof DocumentRasterizeError) {
        throw new DocumentImportError(e.code, e.detail);
      }
      Logger.error(TAG_MODULE, `rasterize error: ${e}`);
      throw new DocumentImportError(DOC_RASTERIZE_ERROR_CODE, '文档栅格化失败');
    }
    if (pages.length === 0) {
      throw new DocumentImportError(DOC_RASTERIZE_ERROR_CODE, '文档栅格化失败（无可用页面）');
    }
    this.docBitmaps.set(docId, pages);
    // 源文件路径：优先持久化副本；兜底回退原始 path（仅持久化失败时，导出能力降级）
    this.docSources.set(docId, persistentSource.length > 0 ? persistentSource : path);
    const pageLayers: PageLayerInfo[] = this.rasterizeToPageLayers(docId, pages);
    const meta: DocMeta = {
      docId: docId,
      fileName: name,
      format: format,
      pageCount: pages.length,
      pageLayers: pageLayers,
      rasterized: true,
    };
    Logger.info(TAG_MODULE, `import done: docId=${docId}, pages=${pages.length}`);
    return meta;
  }

  /** 栅格化页面 → PageLayer（type='page'，pageRef='docId:pageIndex'） */
  rasterizeToPageLayers(docId: string, pages: RasterizedPage[]): PageLayerInfo[] {
    const lm: LayerManager = LayerManager.getInstance();
    const infos: PageLayerInfo[] = [];
    for (let i = 0; i < pages.length; i++) {
      const page: RasterizedPage = pages[i];
      const layer = lm.createPageLayer(`文档页 ${page.index + 1}`, `${docId}:${page.index}`);
      const info: PageLayerInfo = {
        pageIndex: page.index,
        layerId: layer.id,
        width: page.width,
        height: page.height,
      };
      infos.push(info);
    }
    return infos;
  }

  /** 按 docId + 页面号取位图（缺图时返回 null，渲染层懒加载兜底） */
  getPageBitmap(docId: string, pageIndex: number): image.PixelMap | null {
    const pages: RasterizedPage[] | undefined = this.docBitmaps.get(docId);
    if (pages === undefined) {
      return null;
    }
    for (let i = 0; i < pages.length; i++) {
      if (pages[i].index === pageIndex) {
        return pages[i].bitmap;
      }
    }
    return null;
  }

  /** F-04 任务 B：取源文件沙箱路径（批注写回的输入）。未知 docId 返回空串 */
  getDocSourcePath(docId: string): string {
    const p: string | undefined = this.docSources.get(docId);
    return p !== undefined ? p : '';
  }

  getDocPageCount(docId: string): number {
    const pages: RasterizedPage[] | undefined = this.docBitmaps.get(docId);
    if (pages === undefined) {
      return 0;
    }
    return pages.length;
  }

  clearDoc(docId: string): void {
    this.docBitmaps.delete(docId);
    this.docSources.delete(docId);
  }

  /** F-04 任务 B+：源 PDF 资产根目录 filesDir/docs（与 notes/thumbs 平级） */
  private docAssetsRoot(): string {
    try {
      const ctx = getContext() as common.UIAbilityContext;
      if (ctx === undefined || ctx === null || ctx.filesDir === undefined) {
        return '';
      }
      return `${ctx.filesDir}/docs`;
    } catch (e) {
      Logger.warn(TAG_MODULE, `docAssetsRoot 获取失败: ${SafeAsync.describe(e as Error)}`);
      return '';
    }
  }

  /**
   * F-04 任务 B+：把原始（可能是 DocumentViewPicker 返回的临时 URI）源 PDF 复制到
   * filesDir/docs/{docId}/source.pdf 持久化。复制失败返回空串（调用方降级处理）。
   */
  private copySourceToPersistentStorage(sourceUri: string, docId: string): string {
    if (sourceUri.length === 0) {
      return '';
    }
    try {
      const root: string = this.docAssetsRoot();
      if (root.length === 0) {
        return '';
      }
      if (!fs.accessSync(root)) {
        fs.mkdirSync(root, true);
      }
      const dir: string = `${root}/${docId}`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      const dest: string = `${dir}/source.pdf`;
      // 目标已存在则先删除，避免 fs.copyFile 冲突
      try {
        fs.accessSync(dest);
        fs.unlinkSync(dest);
      } catch (e) {
        // 不存在，忽略
      }
      fs.copyFile(sourceUri, dest);
      Logger.info(TAG_MODULE, `源 PDF 已持久化: ${dest}`);
      return dest;
    } catch (e) {
      Logger.error(TAG_MODULE, `源 PDF 持久化失败: ${SafeAsync.describe(e as Error)}`);
      return '';
    }
  }

  /** F-04 任务 B+：设置某文档的源文件路径（重载恢复会话时由 DocSessionManager 注入） */
  setDocSourcePath(docId: string, sourcePath: string): void {
    if (docId.length > 0) {
      this.docSources.set(docId, sourcePath);
    }
  }

  /** F-04 任务 B+：删除某文档的资产目录 filesDir/docs/{docId}（删笔记时清理，避免孤儿目录） */
  deleteDocAsset(docId: string): void {
    if (docId.length === 0) {
      return;
    }
    const root: string = this.docAssetsRoot();
    if (root.length === 0) {
      return;
    }
    const dir: string = `${root}/${docId}`;
    try {
      if (fs.accessSync(dir)) {
        // @ohos.file.fs 的 rmdirSync 只接 1 个参数，本身即递归删除
        fs.rmdirSync(dir);
        Logger.info(TAG_MODULE, `已删除文档资产目录: ${dir}`);
      }
    } catch (e) {
      Logger.warn(TAG_MODULE, `删除文档资产目录失败 ${dir}: ${SafeAsync.describe(e as Error)}`);
    }
  }

  private normalizeOptions(options?: RasterizeOptions): RasterizeOptions {
    if (options !== undefined) {
      return {
        maxPages: options.maxPages > 0 ? options.maxPages : Constants.PDF_FREE_PAGE_LIMIT,
        scale: options.scale > 0 ? options.scale : 1.0,
        backgroundColor: options.backgroundColor !== undefined && options.backgroundColor.length > 0
          ? options.backgroundColor : '#FFFFFF',
      };
    }
    return {
      maxPages: Constants.PDF_FREE_PAGE_LIMIT,
      scale: 1.0,
      backgroundColor: '#FFFFFF',
    };
  }

  private extractFileName(path: string): string {
    const idx: number = path.lastIndexOf('/');
    if (idx >= 0 && idx < path.length - 1) {
      return path.substring(idx + 1);
    }
    return path;
  }
}
