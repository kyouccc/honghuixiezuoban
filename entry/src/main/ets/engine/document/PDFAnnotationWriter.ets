/**
 * PDFAnnotationWriter.ets — 手写批注写回 PDF（F-04 任务 B）
 *
 * 能力：把 AnnotationPage 画布上的手写笔迹，以标准 PDF Ink 批注（AnnotationType.INK）
 * 写回源 PDF 并另存，产出的文件在任意标准 PDF 阅读器中都能看到批注。
 * 实现基于华为系统 PDF Kit（@kit.PDFKit，@syscap SystemCapability.OfficeService.PDFService.Core），
 * 零第三方依赖。
 *
 * 关键点 1 —— 坐标系转换（这是本模块唯一容易出错的地方）：
 *   画布坐标系：原点在左上角，Y 轴向下，单位 vp，尺寸 = canvasWidth × canvasHeight；
 *   PDF  坐标系：原点在左下角，Y 轴向上，单位 pt，尺寸 = page.getWidth() × page.getHeight()。
 *   AnnotationPage.renderPaper() 用 drawImage(bmp, 0, 0, w, h) 把页位图**整幅拉伸**铺满画布，
 *   因此两个坐标系之间是纯线性映射（无 letterbox 留白），换算公式：
 *       pdfX = canvasX * (pageWidth  / canvasWidth)
 *       pdfY = pageHeight - canvasY * (pageHeight / canvasHeight)   ← Y 轴翻转
 *
 * 关键点 2 —— 颜色格式：
 *   d.ts 注释统一写作 "The RGB color of ..."，即 24 位 0xRRGGBB，不含 alpha 通道；
 *   透明度走 PdfAnnotationInfo.opacity（0~1）单独表达。
 *
 * 关键点 3 —— 降级策略（绝不崩、绝不静默）：
 *   - 系统 PDF 能力不可用 → 返回 success=false + 明确文案，由 UI 提示用户；
 *   - 源文件缺失（cacheDir 被系统回收）→ 明确提示"请重新导入"，不抛异常；
 *   - 单条笔迹写入失败 → 跳过该条并计数，其余照常写入，最后如实汇报成功条数。
 *
 * ArkTS 严格模式：无 any/unknown、显式类型、对象字面量均有接口标注。
 */

import fs from '@ohos.file.fs';
import { pdfService } from '@kit.PDFKit';
import { Logger } from '../../common/Logger';
import { SafeAsync } from '../../common/utils/SafeAsync';

const TAG_MODULE = 'PDFAnnotationWriter';

/** 系统 PDF 能力标识（与 @hms.officeservice.pdfservice 的 @syscap 一致） */
const PDF_SYS_CAPABILITY: string = 'SystemCapability.OfficeService.PDFService.Core';

/** 单条 ink 批注最大采样点：点过密会拖慢 addAnnotation 并显著撑大文件体积 */
const MAX_POINTS_PER_STROKE: number = 512;

/** 单点笔迹的补点偏移（pt）：避免零长度路径被阅读器丢弃 */
const DEGENERATE_POINT_OFFSET: number = 0.2;

/** 画布坐标点（vp，左上原点） */
export interface InkPointVO {
  x: number;
  y: number;
}

/** 一条待写回的手写笔迹 */
export interface InkStrokeVO {
  /** 画布坐标采样点序列 */
  points: InkPointVO[];
  /** 颜色，'#RRGGBB' 或 '#RGB' */
  color: string;
  /** 线宽（vp） */
  width: number;
  /** 不透明度 0~1 */
  opacity: number;
}

/** 一页的待写回批注（含该页绘制时的画布尺寸，用于坐标换算） */
export interface PageInkVO {
  /** 0 基页码 */
  pageIndex: number;
  /** 绘制该页批注时的画布宽（vp） */
  canvasWidth: number;
  /** 绘制该页批注时的画布高（vp） */
  canvasHeight: number;
  strokes: InkStrokeVO[];
}

/** 写回结果（success=false 时 message 必定为可直接展示给用户的中文文案） */
export interface InkExportResult {
  success: boolean;
  /** 成功时为产物绝对路径，失败为空串 */
  outputPath: string;
  /** 实际写入批注的页数 */
  pageCount: number;
  /** 实际写入的笔迹条数 */
  strokeCount: number;
  /** 跳过（写入失败）的笔迹条数 */
  skippedCount: number;
  message: string;
}

export class PDFAnnotationWriter {
  /** 当前设备是否具备系统 PDF 服务能力（非华为设备 / 部分模拟器为 false） */
  static isSupported(): boolean {
    return canIUse(PDF_SYS_CAPABILITY);
  }

  /**
   * 把手写笔迹作为 Ink 批注写回 PDF 并另存。
   *
   * @param sourcePath 源 PDF 的**沙箱路径**（PDF Kit 的 loadDocument 不接受 picker 原始 URI）
   * @param outputPath 目标 PDF 沙箱路径（父目录须已存在）
   * @param pages      逐页待写回的批注
   */
  async exportWithInk(sourcePath: string, outputPath: string, pages: PageInkVO[]): Promise<InkExportResult> {
    if (!PDFAnnotationWriter.isSupported()) {
      return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '当前设备不支持系统 PDF 服务，无法导出带批注的 PDF');
    }
    if (sourcePath.length === 0) {
      return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '找不到源 PDF，请重新导入后再导出');
    }
    if (outputPath.length === 0) {
      return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '导出路径无效');
    }
    if (!PDFAnnotationWriter.fileExists(sourcePath)) {
      return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '源 PDF 缓存已被系统清理，请重新导入后再导出');
    }
    if (pages.length === 0) {
      return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '没有可导出的批注笔迹');
    }

    let doc: pdfService.PdfDocument | null = null;
    try {
      doc = new pdfService.PdfDocument();
      doc.loadDocument(sourcePath);
      const totalPages: number = doc.getPageCount();
      if (totalPages <= 0) {
        doc.releaseDocument();
        return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '源 PDF 无有效页面');
      }

      let writtenPages: number = 0;
      let writtenStrokes: number = 0;
      let skipped: number = 0;

      for (let p = 0; p < pages.length; p++) {
        const pv: PageInkVO = pages[p];
        if (pv.pageIndex < 0 || pv.pageIndex >= totalPages || pv.strokes.length === 0) {
          continue;
        }
        if (pv.canvasWidth <= 0 || pv.canvasHeight <= 0) {
          skipped += pv.strokes.length;
          Logger.warn(TAG_MODULE, `第 ${pv.pageIndex + 1} 页画布尺寸未知，跳过 ${pv.strokes.length} 条笔迹`);
          continue;
        }
        const added: number = this.writePageInk(doc, pv, totalPages);
        if (added > 0) {
          writtenPages++;
          writtenStrokes += added;
        }
        skipped += pv.strokes.length - added;
      }

      if (writtenStrokes === 0) {
        doc.releaseDocument();
        doc = null;
        return PDFAnnotationWriter.buildResult(false, '', 0, 0, skipped, '批注写回失败（无一条笔迹成功写入）');
      }

      const saved: boolean = doc.saveDocument(outputPath);
      doc.releaseDocument();
      doc = null;
      if (!saved) {
        return PDFAnnotationWriter.buildResult(false, '', writtenPages, writtenStrokes, skipped, 'PDF 保存失败，请检查存储空间');
      }
      Logger.info(TAG_MODULE,
        `写回完成 pages=${writtenPages} strokes=${writtenStrokes} skipped=${skipped} out=${outputPath}`);
      const tail: string = skipped > 0 ? `（${skipped} 条笔迹因坐标异常被跳过）` : '';
      return PDFAnnotationWriter.buildResult(true, outputPath, writtenPages, writtenStrokes, skipped,
        `已导出 ${writtenPages} 页、${writtenStrokes} 条批注${tail}`);
    } catch (e) {
      Logger.error(TAG_MODULE, `exportWithInk 失败: ${SafeAsync.describe(e as Error)}`);
      if (doc !== null) {
        try {
          doc.releaseDocument();
        } catch (releaseErr) {
          Logger.warn(TAG_MODULE, `releaseDocument 失败: ${SafeAsync.describe(releaseErr as Error)}`);
        }
      }
      return PDFAnnotationWriter.buildResult(false, '', 0, 0, 0, '批注写回 PDF 失败，请稍后重试');
    }
  }

  /**
   * 写入单页全部笔迹，返回成功条数。
   * 单条失败只跳过该条，不影响同页其余笔迹（不抛异常）。
   */
  private writePageInk(doc: pdfService.PdfDocument, pv: PageInkVO, totalPages: number): number {
    let page: pdfService.PdfPage | null = null;
    let added: number = 0;
    try {
      page = doc.getPage(pv.pageIndex);
      const pageWidth: number = page.getWidth();
      const pageHeight: number = page.getHeight();
      if (pageWidth <= 0 || pageHeight <= 0) {
        Logger.warn(TAG_MODULE, `第 ${pv.pageIndex + 1}/${totalPages} 页尺寸异常（${pageWidth}×${pageHeight}），跳过`);
        page.release();
        return 0;
      }
      const scaleX: number = pageWidth / pv.canvasWidth;
      const scaleY: number = pageHeight / pv.canvasHeight;
      for (let i = 0; i < pv.strokes.length; i++) {
        if (this.addInkAnnotation(page, pv.strokes[i], scaleX, scaleY, pageHeight, pv.pageIndex, i)) {
          added++;
        }
      }
      page.release();
      page = null;
      return added;
    } catch (e) {
      Logger.error(TAG_MODULE, `writePageInk(${pv.pageIndex}) 失败: ${SafeAsync.describe(e as Error)}`);
      if (page !== null) {
        try {
          page.release();
        } catch (releaseErr) {
          Logger.warn(TAG_MODULE, `page.release 失败: ${SafeAsync.describe(releaseErr as Error)}`);
        }
      }
      return added;
    }
  }

  /** 构造并挂载一条 Ink 批注；失败返回 false（调用方计入 skipped） */
  private addInkAnnotation(page: pdfService.PdfPage, stroke: InkStrokeVO, scaleX: number, scaleY: number,
    pageHeight: number, pageIndex: number, strokeSeq: number): boolean {
    try {
      const source: InkPointVO[] = stroke.points;
      if (source.length === 0) {
        return false;
      }
      const sampled: InkPointVO[] = PDFAnnotationWriter.downsample(source, MAX_POINTS_PER_STROKE);
      const inkPoints: pdfService.PdfPoint[] = [];
      for (let i = 0; i < sampled.length; i++) {
        const src: InkPointVO = sampled[i];
        if (!PDFAnnotationWriter.isFiniteNumber(src.x) || !PDFAnnotationWriter.isFiniteNumber(src.y)) {
          continue;
        }
        const pt: pdfService.PdfPoint = new pdfService.PdfPoint();
        pt.x = src.x * scaleX;
        // Y 轴翻转：画布左上原点 Y 向下 → PDF 左下原点 Y 向上
        pt.y = pageHeight - src.y * scaleY;
        inkPoints.push(pt);
      }
      if (inkPoints.length === 0) {
        return false;
      }
      if (inkPoints.length === 1) {
        // 单点（点按）笔迹：补一个微偏移点，避免退化成零长度路径被阅读器忽略
        const dup: pdfService.PdfPoint = new pdfService.PdfPoint();
        dup.x = inkPoints[0].x + DEGENERATE_POINT_OFFSET;
        dup.y = inkPoints[0].y + DEGENERATE_POINT_OFFSET;
        inkPoints.push(dup);
      }

      const lineColor: number = PDFAnnotationWriter.hexToRgbInt(stroke.color);
      const strokeWidthPt: number = Math.max(0.5, stroke.width * scaleX);

      const border: pdfService.PdfBorder = new pdfService.PdfBorder();
      border.borderStyle = pdfService.BorderStyle.SOLID;
      border.borderWidth = strokeWidthPt;
      border.borderColor = lineColor;

      const info: pdfService.InkAnnotationInfo = new pdfService.InkAnnotationInfo();
      info.type = pdfService.AnnotationType.INK;
      info.uniqueId = `hc_ink_p${pageIndex}_s${strokeSeq}_${Date.now()}`;
      info.inkPoints = inkPoints;
      info.lineColor = lineColor;
      info.border = border;
      info.opacity = PDFAnnotationWriter.clamp01(stroke.opacity);
      info.flag = pdfService.AnnotationFlag.PRINTED;
      info.title = 'Honghui Notes';
      info.subject = '手写批注';
      const now: Date = new Date();
      info.creationDate = now;
      info.modifiedTime = now;

      page.addAnnotation(info);
      return true;
    } catch (e) {
      Logger.warn(TAG_MODULE,
        `第 ${pageIndex + 1} 页第 ${strokeSeq + 1} 条笔迹写入失败: ${SafeAsync.describe(e as Error)}`);
      return false;
    }
  }

  // ═══════════════════════════════════════════════════
  // 工具方法
  // ═══════════════════════════════════════════════════

  /** 等间隔降采样到不超过 maxCount 个点，且始终保留首尾点（保证起笔/收笔位置精确） */
  private static downsample(points: InkPointVO[], maxCount: number): InkPointVO[] {
    if (points.length <= maxCount) {
      return points;
    }
    const result: InkPointVO[] = [];
    const step: number = points.length / maxCount;
    for (let i = 0; i < maxCount; i++) {
      const idx: number = Math.min(points.length - 1, Math.floor(i * step));
      result.push(points[idx]);
    }
    const last: InkPointVO = points[points.length - 1];
    const tail: InkPointVO = result[result.length - 1];
    if (tail.x !== last.x || tail.y !== last.y) {
      result.push(last);
    }
    return result;
  }

  /** '#RRGGBB' / '#RGB' / 'RRGGBB' → 24 位整数 0xRRGGBB；非法输入回退黑色 */
  private static hexToRgbInt(hex: string): number {
    let normalized: string = hex;
    if (normalized.length > 0 && normalized.charAt(0) === '#') {
      normalized = normalized.substring(1);
    }
    if (normalized.length === 8) {
      // 兼容 '#AARRGGBB'：丢弃 alpha，透明度由 opacity 表达
      normalized = normalized.substring(2);
    }
    if (normalized.length === 3) {
      const r: string = normalized.charAt(0);
      const g: string = normalized.charAt(1);
      const b: string = normalized.charAt(2);
      normalized = r + r + g + g + b + b;
    }
    if (normalized.length !== 6) {
      return 0x000000;
    }
    const value: number = parseInt(normalized, 16);
    if (isNaN(value)) {
      return 0x000000;
    }
    return value & 0xFFFFFF;
  }

  private static clamp01(value: number): number {
    if (!PDFAnnotationWriter.isFiniteNumber(value)) {
      return 1;
    }
    if (value < 0) {
      return 0;
    }
    if (value > 1) {
      return 1;
    }
    return value;
  }

  private static isFiniteNumber(value: number): boolean {
    return !isNaN(value) && value !== Infinity && value !== -Infinity;
  }

  private static fileExists(path: string): boolean {
    try {
      fs.accessSync(path);
      return true;
    } catch (e) {
      return false;
    }
  }

  private static buildResult(success: boolean, outputPath: string, pageCount: number, strokeCount: number,
    skippedCount: number, message: string): InkExportResult {
    const result: InkExportResult = {
      success: success,
      outputPath: outputPath,
      pageCount: pageCount,
      strokeCount: strokeCount,
      skippedCount: skippedCount,
      message: message,
    };
    return result;
  }
}
