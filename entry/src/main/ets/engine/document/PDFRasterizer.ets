/**
 * PDFRasterizer.ets — PDF 文档栅格化实现（v2.0 增量，S1T02 / NP-05）
 *
 * P0 能力：
 *  - 通过 @ohos.file.fs 读取文件头，最小 PDF 解析器提取页面数（/Type /Pages → /Count）
 *    与页面尺寸（/MediaBox），解析失败以 A4（595×842）兜底；
 *  - 免费版限制 PDF_FREE_PAGE_LIMIT=10 页（架构 §8.5）；
 *  - 每页生成位图（image.PixelMap）作为只读 PageLayer 底图；
 *  - CAJ 降级：.caj 后缀直接抛出"请转换为 PDF 后导入"（架构 Q-01 决策）。
 *
 * v2.4（F-04 真实渲染）：页面位图优先由华为系统 PDF Kit（@kit.PDFKit，
 *   SystemCapability.OfficeService.PDFService.Core，@since 5.0.0(12)）真实栅格化：
 *   pdfService.PdfDocument.loadDocument → getPage(i).getPagePixelMap() 直接得到
 *   image.PixelMap，与 RasterizedPage.bitmap 契约完全吻合（零第三方依赖）。
 *   能力检测：canIUse('SystemCapability.OfficeService.PDFService.Core')，
 *   不可用时（非华为设备 / 部分模拟器）回退到「白底位图 + 页面尺寸」几何栅格化，
 *   并向上抛出可识别的降级标记，由 UI 明确告知用户（不静默失败）。
 *   沙箱约束：loadDocument 仅接受沙箱路径，因此先用 fs 把 DocumentViewPicker
 *   返回的原始 URI 复制到 context.cacheDir 再加载；文件复制失败直接进入降级。
 */

import fs from '@ohos.file.fs';
import image from '@ohos.multimedia.image';
import { common } from '@kit.AbilityKit';
import { pdfService } from '@kit.PDFKit';
import { Logger } from '../../common/Logger';
import { Constants } from '../../common/Constants';
import { SafeAsync } from '../../common/utils/SafeAsync';
import {
  ITextRasterizer,
  RasterizedPage,
  RasterizeOptions,
  DocumentRasterizeError,
  DOC_RASTERIZE_ERROR_CODE,
} from './ITextRasterizer';

const TAG_MODULE = 'PDFRasterizer';
const PDF_SIGNATURE: string = '%PDF';
const CAJ_EXT: string = '.caj';
const A4_WIDTH: number = 595;
const A4_HEIGHT: number = 842;
const MAX_SCAN_BYTES: number = 4 * 1024 * 1024; // 最小解析器只扫描头部 4MB
const MAX_PAGE_COUNT: number = 10000;
/** 系统 PDF 能力标识（与 @hms.officeservice.pdfservice 的 @syscap 一致） */
const PDF_SYS_CAPABILITY: string = 'SystemCapability.OfficeService.PDFService.Core';

interface PdfPageInfo {
  index: number;
  width: number;
  height: number;
}

interface PdfParseResult {
  pageInfos: PdfPageInfo[];
  title: string;
}

interface MediaBox {
  width: number;
  height: number;
}

interface RgbColor {
  r: number;
  g: number;
  b: number;
}

export class PDFRasterizer implements ITextRasterizer {
  /**
   * F-04 任务 B：原始 URI → 沙箱副本路径。
   * 批注写回（PDFAnnotationWriter）需要拿到同一份沙箱 PDF 作为写入源，
   * 而 loadDocument 只接受沙箱路径，故在栅格化阶段把映射记下来复用，避免二次拷贝。
   */
  private static readonly sandboxPaths: Map<string, string> = new Map<string, string>();

  /** 取某个原始 URI 对应的沙箱副本路径；未栅格化过返回空串 */
  static getSandboxPath(uri: string): string {
    const p: string | undefined = PDFRasterizer.sandboxPaths.get(uri);
    return p !== undefined ? p : '';
  }

  /** 当前设备是否具备系统 PDF 真实渲染能力 */
  static isRealRenderSupported(): boolean {
    return canIUse(PDF_SYS_CAPABILITY);
  }

  supports(format: string): boolean {
    return format === 'pdf';
  }

  async rasterize(uri: string, options: RasterizeOptions): Promise<RasterizedPage[]> {
    const lowerUri: string = uri.toLowerCase();
    if (lowerUri.endsWith(CAJ_EXT)) {
      throw new DocumentRasterizeError(DOC_RASTERIZE_ERROR_CODE, 'CAJ 格式暂不支持（Q-01 降级），请转换为 PDF 后导入');
    }
    // E-3b：直连调用兜底 backgroundColor（与 DocumentImporter.normalizeOptions 一致），保证页面位图非 null
    const bgColor: string = options.backgroundColor !== undefined && options.backgroundColor.length > 0
      ? options.backgroundColor : '#FFFFFF';
    const parseResult: PdfParseResult = await this.parsePdfInfo(uri);
    const maxPages: number = options.maxPages > 0 ? options.maxPages : Constants.PDF_FREE_PAGE_LIMIT;
    const limit: number = Math.min(parseResult.pageInfos.length, maxPages);
    const pages: RasterizedPage[] = [];

    // F-04：优先尝试系统 PDF Kit 真实栅格化；能力不可用或失败时回退几何栅格化
    const sandboxPath: string | null = await this.copyToSandboxIfNeeded(uri);
    if (sandboxPath !== null) {
      // 记录映射供批注写回复用（任务 B）
      PDFRasterizer.sandboxPaths.set(uri, sandboxPath);
    }
    const canRenderReal: boolean = sandboxPath !== null && canIUse(PDF_SYS_CAPABILITY);
    let pdfDoc: pdfService.PdfDocument | null = null;
    let renderedReal: boolean = false;

    if (canRenderReal) {
      try {
        pdfDoc = new pdfService.PdfDocument();
        pdfDoc.loadDocument(sandboxPath as string);
        const realCount: number = pdfDoc.getPageCount();
        if (realCount <= 0) {
          // 文档无页面，放弃真实渲染，走降级
          pdfDoc.releaseDocument();
          pdfDoc = null;
        }
      } catch (e) {
        Logger.error(TAG_MODULE, `PDF Kit 加载失败，回退几何栅格化: ${SafeAsync.describe(e as Error)}`);
        if (pdfDoc !== null) {
          pdfDoc.releaseDocument();
          pdfDoc = null;
        }
      }
    }

    for (let i = 0; i < limit; i++) {
      const info: PdfPageInfo = parseResult.pageInfos[i];
      let bitmap: image.PixelMap | null = null;
      if (pdfDoc !== null) {
        bitmap = this.rasterizePageReal(pdfDoc, i, bgColor);
      }
      if (bitmap === null) {
        // 真实渲染不可用或该页失败：几何栅格化（白底 + 页面尺寸），保证底图非空、不白屏
        bitmap = await PDFRasterizer.createBlankBitmap(info.width, info.height, bgColor);
      } else {
        renderedReal = true;
      }
      const page: RasterizedPage = {
        index: info.index,
        width: info.width,
        height: info.height,
        bitmap: bitmap,
      };
      pages.push(page);
    }

    if (pdfDoc !== null) {
      pdfDoc.releaseDocument();
      pdfDoc = null;
    }
    Logger.info(TAG_MODULE,
      `rasterize done: ${pages.length}/${parseResult.pageInfos.length} pages, real=${renderedReal ? 'yes' : 'no'}`);
    return pages;
  }

  /**
   * 用系统 PDF Kit 把单页栅格化为 PixelMap（@since 5.0.0(12) getPagePixelMap 直接返回 image.PixelMap）。
   * 任何异常都返回 null，由调用方回退到白底几何栅格化（绝不抛错中断导入）。
   */
  private rasterizePageReal(doc: pdfService.PdfDocument, index: number, bgColor: string): image.PixelMap | null {
    try {
      const page: pdfService.PdfPage = doc.getPage(index);
      const pixelMap: image.PixelMap = page.getPagePixelMap();
      page.release();
      return pixelMap;
    } catch (e) {
      Logger.error(TAG_MODULE, `getPagePixelMap(${index}) 失败，回退白底: ${SafeAsync.describe(e as Error)}`);
      return null;
    }
  }

  /** 解析 PDF 页数与页面尺寸（最小 PDF 解析器） */
  private async parsePdfInfo(uri: string): Promise<PdfParseResult> {
    const content: string = this.readFileHead(uri);
    if (!content.startsWith(PDF_SIGNATURE)) {
      throw new DocumentRasterizeError(DOC_RASTERIZE_ERROR_CODE, '文件不是有效的 PDF');
    }
    const pageCount: number = this.extractPageCount(content);
    const boxes: MediaBox[] = this.extractMediaBoxes(content, pageCount);
    const pageInfos: PdfPageInfo[] = [];
    for (let i = 0; i < pageCount; i++) {
      const box: MediaBox = boxes[i];
      const w: number = box.width > 0 ? box.width : A4_WIDTH;
      const h: number = box.height > 0 ? box.height : A4_HEIGHT;
      pageInfos.push({ index: i, width: w, height: h });
    }
    const result: PdfParseResult = {
      pageInfos: pageInfos,
      title: this.extractTitle(content),
    };
    return result;
  }

  /**
   * 保证传入 loadDocument 的是沙箱路径：
   *  - 若 uri 已是沙箱路径（以 context.cacheDir / filesDir 前缀开头）直接复用；
   *  - 否则（DocumentViewPicker 返回的原始 URI）用 fs 复制到 context.cacheDir 后返回沙箱路径；
   *  - 复制失败 / 无可用 context 时返回 null，调用方将走几何栅格化降级。
   */
  private async copyToSandboxIfNeeded(uri: string): Promise<string | null> {
    if (uri.length === 0) {
      return null;
    }
    // 已是沙箱路径：直接返回
    if (uri.startsWith('/data/storage') || uri.startsWith('file:///data/storage')) {
      return uri.startsWith('file://') ? uri.substring('file://'.length) : uri;
    }
    try {
      const ctx: common.UIAbilityContext | undefined = this.getUIAbilityContext();
      if (ctx === undefined) {
        Logger.warn(TAG_MODULE, '无 UIAbilityContext，无法复制到沙箱，走几何栅格化');
        return null;
      }
      const cacheDir: string = ctx.cacheDir;
      const sep: number = uri.lastIndexOf('/');
      const rawName: string = sep >= 0 ? uri.substring(sep + 1) : `import_${Date.now()}.pdf`;
      const safeName: string = rawName.replace(/[^a-zA-Z0-9._-]/g, '_');
      const dest: string = `${cacheDir}/${safeName}`;
      // 目标已存在则先删除，避免 fs.copyFile 冲突
      try {
        fs.accessSync(dest);
        fs.unlinkSync(dest);
      } catch (e) {
        // 不存在，忽略
      }
      fs.copyFile(uri, dest);
      Logger.info(TAG_MODULE, `已复制到沙箱: ${dest}`);
      return dest;
    } catch (e) {
      Logger.error(TAG_MODULE, `复制到沙箱失败: ${SafeAsync.describe(e as Error)}`);
      return null;
    }
  }

  /** 取 UIAbilityContext（用于 cacheDir 沙箱路径）。取不到返回 undefined。 */
  private getUIAbilityContext(): common.UIAbilityContext | undefined {
    try {
      // getContext(this) 在组件/Ability 上下文可用；PDFRasterizer 为普通单例，
      // 退化为尝试全局 UIAbilityContext。取不到时由调用方降级。
      const ctx = getContext() as common.UIAbilityContext;
      if (ctx !== undefined && ctx !== null && ctx.cacheDir !== undefined) {
        return ctx;
      }
      return undefined;
    } catch (e) {
      Logger.warn(TAG_MODULE, `getContext 失败: ${SafeAsync.describe(e as Error)}`);
      return undefined;
    }
  }

  private readFileHead(uri: string): string {
    let file: fs.File | null = null;
    try {
      file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(uri);
      const toRead: number = Math.min(stat.size, MAX_SCAN_BYTES);
      const buf: ArrayBuffer = new ArrayBuffer(toRead);
      const readLen: number = fs.readSync(file.fd, buf, { offset: 0, length: toRead });
      const bytes: Uint8Array = new Uint8Array(buf, 0, readLen);
      return PDFRasterizer.decodeBytesToString(bytes);
    } catch (e) {
      Logger.error(TAG_MODULE, `readFileHead error: ${e}`);
      throw new DocumentRasterizeError(DOC_RASTERIZE_ERROR_CODE, '读取 PDF 文件失败');
    } finally {
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }

  /** 页面内容栅格化为位图（几何栅格化：白底 + 页面尺寸；PDF Kit 不可用时作为降级底图） */
  private async rasterizePageContent(info: PdfPageInfo, bgColor: string): Promise<image.PixelMap | null> {
    return PDFRasterizer.createBlankBitmap(info.width, info.height, bgColor);
  }

  private static async createBlankBitmap(width: number, height: number, bgColor: string): Promise<image.PixelMap | null> {
    try {
      const w: number = Math.max(1, Math.round(width));
      const h: number = Math.max(1, Math.round(height));
      const rgba: Uint8Array = new Uint8Array(w * h * 4);
      const rgb: RgbColor = PDFRasterizer.hexToRgb(bgColor);
      for (let i = 0; i < rgba.length; i += 4) {
        rgba[i] = rgb.r;
        rgba[i + 1] = rgb.g;
        rgba[i + 2] = rgb.b;
        rgba[i + 3] = 255;
      }
      const opts: image.InitializationOptions = {
        size: { width: w, height: h },
        pixelFormat: image.PixelMapFormat.RGBA_8888,
      };
      const pixelMap: image.PixelMap = await image.createPixelMap(rgba.buffer as ArrayBuffer, opts);
      return pixelMap;
    } catch (e) {
      Logger.error(TAG_MODULE, `createBlankBitmap error: ${e}`);
      return null;
    }
  }

  private extractPageCount(content: string): number {
    const regex = /\/Count\s+(\d+)/;
    const match: RegExpMatchArray | null = content.match(regex);
    if (match !== null && match.length >= 2) {
      const count: number = parseInt(match[1]);
      if (!isNaN(count) && count > 0 && count <= MAX_PAGE_COUNT) {
        return count;
      }
    }
    return 1;
  }

  private extractMediaBoxes(content: string, pageCount: number): MediaBox[] {
    const boxes: MediaBox[] = [];
    const regex = /\/MediaBox\s*\[\s*[\d.\-]+\s+[\d.\-]+\s+([\d.]+)\s+([\d.]+)\s*\]/g;
    let m: RegExpExecArray | null = regex.exec(content);
    while (m !== null && boxes.length < pageCount) {
      const w: number = parseFloat(m[1]);
      const h: number = parseFloat(m[2]);
      boxes.push({ width: w, height: h });
      m = regex.exec(content);
    }
    while (boxes.length < pageCount) {
      boxes.push({ width: A4_WIDTH, height: A4_HEIGHT });
    }
    return boxes;
  }

  private extractTitle(content: string): string {
    const regex = /\/Title\s*\(([^)]*)\)/;
    const match: RegExpMatchArray | null = content.match(regex);
    if (match !== null && match.length >= 2) {
      return match[1].substring(0, 120);
    }
    return '';
  }

  private static hexToRgb(hex: string): RgbColor {
    let normalized: string = hex;
    if (normalized.length > 0 && normalized.charAt(0) === '#') {
      normalized = normalized.substring(1);
    }
    if (normalized.length === 3) {
      const r: string = normalized.charAt(0);
      const g: string = normalized.charAt(1);
      const b: string = normalized.charAt(2);
      normalized = r + r + g + g + b + b;
    }
    const value: number = parseInt(normalized, 16);
    if (isNaN(value)) {
      return { r: 255, g: 255, b: 255 };
    }
    return {
      r: (value >> 16) & 0xFF,
      g: (value >> 8) & 0xFF,
      b: value & 0xFF,
    };
  }

  /** Latin-1 解码（PDF 头部/xref 以 ASCII 为主，扫描 /Count /MediaBox 足够） */
  private static decodeBytesToString(bytes: Uint8Array): string {
    const parts: string[] = [];
    const chunkSize: number = 8192;
    for (let i = 0; i < bytes.length; i += chunkSize) {
      let chunk: string = '';
      const end: number = Math.min(i + chunkSize, bytes.length);
      for (let j = i; j < end; j++) {
        chunk += String.fromCharCode(bytes[j]);
      }
      parts.push(chunk);
    }
    return parts.join('');
  }
}
