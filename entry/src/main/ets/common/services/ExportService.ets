/**
 * 导出服务
 * 支持 PNG、SVG、PDF 等多种导出格式
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { analytics, AnalyticsEvent } from './AnalyticsService';
import image from '@ohos.multimedia.image';

const TAG = 'ExportService';
const DOMAIN = 0x0000;

export enum ExportFormat {
  PNG = 'png',
  SVG = 'svg',
  PDF = 'pdf'
}

/** S2-Ca / T2-5a：导出 PDF 的分层选项（写方向，不复用 PDF Kit 读 API） */
export interface ExportPdfOptions {
  /** 是否包含批注层（本实现：WhiteboardPage 无独立批注层时传 false；分层由调用方位图合成决定） */
  includeAnnotations: boolean;
  /** 页码范围（1 基，如 [1,3]；缺省=全部页） */
  pageRange?: number[];
}

/** S2-Ca / T2-5a：单页 PDF 输入（JPEG 位图 dataURL + 尺寸） */
export interface PdfPageImage {
  /** JPEG dataURL（`data:image/jpeg;base64,...`，由 Canvas.toDataURL('image/jpeg') 产出） */
  jpegDataUrl: string;
  /** 页面宽（pt，≈ 位图像素宽） */
  width: number;
  /** 页面高（pt，≈ 位图像素高） */
  height: number;
}

export interface ExportOptions {
  format: ExportFormat;
  width?: number;
  height?: number;
  backgroundColor?: string;
  includeGrid?: boolean;
  quality?: number; // 0-1，用于 PNG 压缩
}

/** 笔触点 */
interface StrokePoint {
  x: number;
  y: number;
}

export interface StrokeData {
  id: string;
  points: Array<StrokePoint>;
  color: string;
  width: number;
}

export interface ShapeData {
  id: string;
  type: 'rectangle' | 'circle' | 'arrow' | 'line';
  x: number;
  y: number;
  width: number;
  height: number;
  color: string;
  strokeWidth: number;
}

/** 分析埋点数据 */
interface AnalyticsEventData {
  stroke_count?: number;
  shape_count?: number;
  width?: number;
  height?: number;
}

export class ExportService {
  private static instance: ExportService;

  private constructor() {}

  static getInstance(): ExportService {
    if (!ExportService.instance) {
      ExportService.instance = new ExportService();
    }
    return ExportService.instance;
  }

  /**
   * 导出为 SVG
   */
  exportToSVG(
    strokes: StrokeData[],
    shapes: ShapeData[],
    options: ExportOptions
  ): string {
    hilog.info(DOMAIN, TAG, 'Exporting to SVG');
    
    const width = options.width || 1080;
    const height = options.height || 1920;
    const bgColor = options.backgroundColor || '#FFFFFF';
    
    let svg = `<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
  <rect width="100%" height="100%" fill="${bgColor}"/>
  <g id="strokes">
`;
    
    // 导出笔触
    for (const stroke of strokes) {
      if (stroke.points.length < 2) continue;
      
      let pathData = `M ${stroke.points[0].x} ${stroke.points[0].y}`;
      for (let i = 1; i < stroke.points.length; i++) {
        pathData += ` L ${stroke.points[i].x} ${stroke.points[i].y}`;
      }
      
      svg += `    <path d="${pathData}" stroke="${stroke.color}" stroke-width="${stroke.width}" fill="none" stroke-linecap="round" stroke-linejoin="round"/>\n`;
    }
    
    svg += '  </g>\n';
    svg += '  <g id="shapes">\n';
    
    // 导出形状
    for (const shape of shapes) {
      svg += this.shapeToSVG(shape);
    }
    
    svg += '  </g>\n';
    svg += '</svg>';
    
    // 记录埋点
    const eventData: AnalyticsEventData = {
      stroke_count: strokes.length,
      shape_count: shapes.length,
      width: width,
      height: height
    };
    analytics.track(AnalyticsEvent.EXPORT_SVG, eventData);
    
    hilog.info(DOMAIN, TAG, `SVG exported, size: ${svg.length} bytes`);
    return svg;
  }

  /**
   * 形状转 SVG
   */
  private shapeToSVG(shape: ShapeData): string {
    const type = shape.type;
    const x = shape.x;
    const y = shape.y;
    const width = shape.width;
    const height = shape.height;
    const color = shape.color;
    const strokeWidth = shape.strokeWidth;
    
    switch (type) {
      case 'rectangle':
        return `    <rect x="${x}" y="${y}" width="${width}" height="${height}" stroke="${color}" stroke-width="${strokeWidth}" fill="none"/>\n`;
        
      case 'circle':
        const cx = x + width / 2;
        const cy = y + height / 2;
        const r = Math.min(width, height) / 2;
        return `    <circle cx="${cx}" cy="${cy}" r="${r}" stroke="${color}" stroke-width="${strokeWidth}" fill="none"/>\n`;
        
      case 'line':
        return `    <line x1="${x}" y1="${y}" x2="${x + width}" y2="${y + height}" stroke="${color}" stroke-width="${strokeWidth}"/>\n`;
        
      case 'arrow':
        // 箭头：线 + 三角形
        const endX = x + width;
        const endY = y + height;
        const angle = Math.atan2(height, width);
        const arrowSize = 15;
        const arrowAngle = Math.PI / 6; // 30度
        
        const x1 = endX - arrowSize * Math.cos(angle - arrowAngle);
        const y1 = endY - arrowSize * Math.sin(angle - arrowAngle);
        const x2 = endX - arrowSize * Math.cos(angle + arrowAngle);
        const y2 = endY - arrowSize * Math.sin(angle + arrowAngle);
        
        return `    <line x1="${x}" y1="${y}" x2="${endX}" y2="${endY}" stroke="${color}" stroke-width="${strokeWidth}"/>
    <polygon points="${endX},${endY} ${x1},${y1} ${x2},${y2}" fill="${color}"/>\n`;
        
      default:
        return '';
    }
  }

  /**
   * 导出为 PDF（简化版，使用 SVG 转 PDF）
   */
  async exportToPDF(
    strokes: StrokeData[],
    shapes: ShapeData[],
    options: ExportOptions
  ): Promise<ArrayBuffer | null> {
    hilog.info(DOMAIN, TAG, 'Exporting to PDF');
    
    // 先生成 SVG
    const svg = this.exportToSVG(strokes, shapes, options);
    
    // TODO: 使用 PDF 生成库将 SVG 转换为 PDF
    // HarmonyOS 可能需要使用第三方库或后端服务
    
    // 记录埋点
    const eventData: AnalyticsEventData = {
      stroke_count: strokes.length,
      shape_count: shapes.length
    };
    analytics.track(AnalyticsEvent.EXPORT_PDF, eventData);
    
    hilog.warn(DOMAIN, TAG, 'PDF export not fully implemented');
    return null;
  }

  /**
   * 将 PNG dataURL 转换为 PDF ArrayBuffer（修复 ExportDialog "PDF 导出功能开发中" 的功能与实际不符）。
   * 流程：PNG dataURL → PixelMap → JPEG 编码 → 复用 exportBitmapsToPDF 产出真实 PDF。
   * 用于 ExportDialog 的 PDF 导出按钮（用户已有画布 PNG 位图，转换为可分享 PDF）。
   */
  async exportPngDataUrlToPDF(
    pngDataUrl: string,
    width: number,
    height: number
  ): Promise<ArrayBuffer> {
    hilog.info(DOMAIN, TAG, 'exportPngDataUrlToPDF start');
    if (!pngDataUrl || pngDataUrl.length === 0) {
      return new ArrayBuffer(0);
    }
    // 1) dataURL → base64 → ArrayBuffer
    const commaIdx: number = pngDataUrl.indexOf(',');
    const b64: string = commaIdx >= 0 ? pngDataUrl.substring(commaIdx + 1) : pngDataUrl;
    const helper = new util.Base64Helper();
    const pngBuf: ArrayBuffer = helper.decodeSync(b64, util.Type.BASIC).buffer as ArrayBuffer;

    // 2) 解码 PNG → PixelMap
    const src: image.ImageSource = image.createImageSource(pngBuf);
    const pixelMap: image.PixelMap = await src.createPixelMap();

    // 3) 编码 PixelMap → JPEG ArrayBuffer
    const packer: image.ImagePacker = image.createImagePacker();
    const packOpts: image.PackingOption = { format: 'image/jpeg', quality: 90 };
    const jpegBuf: ArrayBuffer = await packer.packing(pixelMap, packOpts);

    // 4) JPEG ArrayBuffer → base64 → dataURL
    const jpegBytes: Uint8Array = new Uint8Array(jpegBuf);
    const b64Bytes: Uint8Array = helper.encodeSync(jpegBytes, util.Type.BASIC);
    const decoder = new util.TextDecoder('utf-8');
    const jpegB64: string = decoder.decodeToString(b64Bytes);
    const jpegDataUrl: string = `data:image/jpeg;base64,${jpegB64}`;

    // 5) 复用位图→PDF 生成器
    const w: number = width > 0 ? width : 800;
    const h: number = height > 0 ? height : 600;
    const pages: PdfPageImage[] = [{ jpegDataUrl, width: w, height: h }];
    const pdfBuf: ArrayBuffer = this.exportBitmapsToPDF(pages, { includeAnnotations: false });
    hilog.info(DOMAIN, TAG, `exportPngDataUrlToPDF done, size=${pdfBuf.byteLength}`);
    return pdfBuf;
  }

  /**
   * S2-Ca / T2-5a：位图数组 → 最小 PDF 容器（零三方依赖）。
   * 每页 JPEG 字节经 DCTDecode 直接嵌入（PDF 标准允许 DCTDecode 图像流 = JPEG 字节），
   * 手写对象/xref/trailer。A2-7a：产出 PDF 可被系统阅读器打开。
   */
  exportBitmapsToPDF(pages: PdfPageImage[], options: ExportPdfOptions): ArrayBuffer {
    hilog.info(DOMAIN, TAG, `exportBitmapsToPDF pages=${pages.length}`);
    const list: PdfPageImage[] = pages !== undefined && pages !== null ? pages : [];
    if (list.length === 0) {
      return new ArrayBuffer(0);
    }
    // pageRange（1 基）过滤
    let selected: PdfPageImage[] = list;
    if (options !== undefined && options.pageRange !== undefined && options.pageRange !== null
      && options.pageRange.length > 0) {
      const filtered: PdfPageImage[] = [];
      for (let i = 0; i < list.length; i++) {
        if (options.pageRange.indexOf(i + 1) >= 0) {
          filtered.push(list[i]);
        }
      }
      if (filtered.length > 0) {
        selected = filtered;
      }
    }

    const bytes: number[] = [];
    ExportService.writeAscii(bytes, '%PDF-1.4\n');
    ExportService.writeAscii(bytes, '%\u00E2\u00E3\u00CF\u00D3\n'); // 二进制注释行（合规性建议）

    // 对象布局：1 Catalog / 2 Pages / 每页 (Page, Image, Contents)
    const pageCount: number = selected.length;
    const objCount: number = 3 + pageCount * 3;
    const offsets: number[] = [];
    const pageObjNums: number[] = [];
    for (let i = 0; i < pageCount; i++) {
      pageObjNums.push(3 + i * 3);
    }

    // 1 Catalog
    offsets.push(bytes.length);
    ExportService.writeAscii(bytes, '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
    // 2 Pages
    offsets.push(bytes.length);
    let kids: string = '[';
    for (let i = 0; i < pageObjNums.length; i++) {
      kids += `${pageObjNums[i]} 0 R`;
      if (i < pageObjNums.length - 1) {
        kids += ' ';
      }
    }
    kids += ']';
    ExportService.writeAscii(bytes, `2 0 obj\n<< /Type /Pages /Kids ${kids} /Count ${pageCount} >>\nendobj\n`);

    // 每页：Page + Image + Contents
    for (let i = 0; i < pageCount; i++) {
      const page: PdfPageImage = selected[i];
      const pageObjNum: number = 3 + i * 3;
      const imgObjNum: number = 4 + i * 3;
      const contentObjNum: number = 5 + i * 3;
      const w: number = Math.max(1, Math.round(page.width));
      const h: number = Math.max(1, Math.round(page.height));
      const jpeg: Uint8Array = ExportService.jpegFromDataUrl(page.jpegDataUrl);

      // Page
      offsets.push(bytes.length);
      ExportService.writeAscii(bytes,
        `${pageObjNum} 0 obj\n` +
        `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ${w} ${h}] ` +
        `/Resources << /XObject << /Im0 ${imgObjNum} 0 R >> >> /Contents ${contentObjNum} 0 R >>\nendobj\n`);

      // Image XObject（DCTDecode 流 = JPEG 字节）
      offsets.push(bytes.length);
      ExportService.writeAscii(bytes,
        `${imgObjNum} 0 obj\n` +
        `<< /Type /XObject /Subtype /Image /Width ${w} /Height ${h} ` +
        `/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length ${jpeg.length} >>\nstream\n`);
      for (let k = 0; k < jpeg.length; k++) {
        bytes.push(jpeg[k]);
      }
      ExportService.writeAscii(bytes, '\nendstream\nendobj\n');

      // Contents 流：q W 0 0 H 0 0 cm /Im0 Do Q
      offsets.push(bytes.length);
      const contentText: string = `q ${w} 0 0 ${h} 0 0 cm /Im0 Do Q\n`;
      ExportService.writeAscii(bytes,
        `${contentObjNum} 0 obj\n<< /Length ${contentText.length} >>\nstream\n${contentText}endstream\nendobj\n`);
    }

    // xref
    const xrefOffset: number = bytes.length;
    ExportService.writeAscii(bytes, `xref\n0 ${objCount + 1}\n`);
    ExportService.writeAscii(bytes, '0000000000 65535 f \n');
    for (let i = 0; i < offsets.length; i++) {
      ExportService.writeAscii(bytes, `${ExportService.pad10(offsets[i])} 00000 n \n`);
    }
    ExportService.writeAscii(bytes, `trailer\n<< /Size ${objCount + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`);

    const out: Uint8Array = Uint8Array.from(bytes);
    hilog.info(DOMAIN, TAG, `PDF built, ${out.length} bytes`);
    return out.buffer as ArrayBuffer;
  }

  /** 从 JPEG dataURL 提取 JPEG 字节（base64 解码） */
  private static jpegFromDataUrl(dataUrl: string): Uint8Array {
    if (dataUrl === undefined || dataUrl === null || dataUrl.length === 0) {
      return new Uint8Array(0);
    }
    const comma: number = dataUrl.indexOf(',');
    const b64: string = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
    return ExportService.base64Decode(b64);
  }

  /** base64 解码（标准表，ArkTS 无内置；输出字节数组） */
  private static base64Decode(b64: string): Uint8Array {
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const out: number[] = [];
    let buffer: number = 0;
    let bits: number = 0;
    for (let i = 0; i < b64.length; i++) {
      const c: string = b64.charAt(i);
      if (c === '=') {
        break;
      }
      const idx: number = chars.indexOf(c);
      if (idx < 0) {
        continue; // 忽略换行/空白
      }
      buffer = (buffer << 6) | idx;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xFF);
      }
    }
    return Uint8Array.from(out);
  }

  /** 十进制 10 位补齐（xref 偏移） */
  private static pad10(n: number): string {
    const s: string = String(n);
    let pad: string = '';
    for (let i = s.length; i < 10; i++) {
      pad += '0';
    }
    return pad + s;
  }

  /** 追加 ASCII 字节 */
  private static writeAscii(bytes: number[], text: string): void {
    for (let i = 0; i < text.length; i++) {
      bytes.push(text.charCodeAt(i) & 0xFF);
    }
  }

  /**
   * 导出数据 URL
   */
  exportToDataURL(
    strokes: StrokeData[],
    shapes: ShapeData[],
    options: ExportOptions
  ): string {
    switch (options.format) {
      case ExportFormat.SVG:
        const svg = this.exportToSVG(strokes, shapes, options);
        return `data:image/svg+xml;base64,${this.base64Encode(svg)}`;
        
      case ExportFormat.PNG:
        // PNG 导出由 Canvas 的 toDataURL 处理
        return '';
        
      case ExportFormat.PDF:
        // PDF 导出需要异步处理
        return '';
        
      default:
        return '';
    }
  }

  /**
   * Base64 编码
   */
  private base64Encode(str: string): string {
    // 简化的 Base64 编码
    // 实际应使用 @kit.BasicFeaturesKit 的 util.Base64Helper
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const charsArr: string[] = chars.split('');
    let result: string = '';
    
    for (let i = 0; i < str.length; i += 3) {
      const c1: number = str.charCodeAt(i);
      const c2: number = str.charCodeAt(i + 1);
      const c3: number = str.charCodeAt(i + 2);
      
      const e1: number = c1 >> 2;
      const e2: number = ((c1 & 3) << 4) | (c2 >> 4);
      const e3: number = ((c2 & 15) << 2) | (c3 >> 6);
      const e4: number = c3 & 63;
      
      result += charsArr[e1] + charsArr[e2];
      result += i + 1 < str.length ? charsArr[e3] : '=';
      result += i + 2 < str.length ? charsArr[e4] : '=';
    }
    
    return result;
  }

  /**
   * 保存到文件（使用系统文件选择器）
   */
  async saveToFile(
    data: string | ArrayBuffer,
    filename: string,
    format: ExportFormat
  ): Promise<boolean> {
    try {
      hilog.info(DOMAIN, TAG, `Saving file: ${filename}.${format}`);
      
      // 配置文件选择器选项
      const documentSaveOptions = new picker.DocumentSaveOptions();
      documentSaveOptions.newFileNames = [`${filename}.${format}`];
      
      // 根据格式设置文件类型
      switch (format) {
        case ExportFormat.PNG:
          documentSaveOptions.fileSuffixChoices = ['.png'];
          break;
        case ExportFormat.SVG:
          documentSaveOptions.fileSuffixChoices = ['.svg'];
          break;
        case ExportFormat.PDF:
          documentSaveOptions.fileSuffixChoices = ['.pdf'];
          break;
      }
      
      // 调起系统保存器
      const documentViewPicker = new picker.DocumentViewPicker();
      const uris = await documentViewPicker.save(documentSaveOptions);
      
      if (uris && uris.length > 0) {
        const uri = uris[0];
        hilog.info(DOMAIN, TAG, `User selected path: ${uri}`);

        // 🔴 v2.7.2 审核修复（问题②-2「导出图片显示选择路径，实际未导出」）：
        //   原实现 openSync → writeSync → closeSync → **无条件 return true**，
        //   既不 flush 也不校验落盘结果 —— 写入静默失败时界面仍报成功，
        //   用户看到的就是"选了路径，但文件里没内容"。
        //   现改为：写入 → fsync 刷盘 → 关闭 → **读取文件大小校验**，只有真的写进去才算成功。
        let expectedBytes: number = 0;
        try {
          const file = fileIo.openSync(uri,
            fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);

          if (typeof data === 'string') {
            const textEncoder = new util.TextEncoder('utf-8');
            const encodedData: Uint8Array = textEncoder.encodeInto(data);
            expectedBytes = encodedData.buffer.byteLength;
            fileIo.writeSync(file.fd, encodedData.buffer);
          } else {
            expectedBytes = data.byteLength;
            fileIo.writeSync(file.fd, data);
          }

          // 刷盘：防止 close 后数据仍在缓冲、目标文件为空
          try {
            fileIo.fsyncSync(file.fd);
          } catch (e) {
            hilog.warn(DOMAIN, TAG, `fsync 跳过: ${JSON.stringify(e)}`);
          }
          fileIo.closeSync(file);

          // 落盘校验：文件实际大小必须与写入字节数一致
          const actualBytes: number = fileIo.statSync(uri).size;
          hilog.info(DOMAIN, TAG, `写入校验 uri=${uri} 期望=${expectedBytes}B 实际=${actualBytes}B`);
          if (expectedBytes <= 0 || actualBytes < expectedBytes) {
            hilog.error(DOMAIN, TAG, `落盘校验失败：期望 ${expectedBytes}B，实际 ${actualBytes}B`);
            return false;
          }
          hilog.info(DOMAIN, TAG, 'File saved successfully');
        } catch (e) {
          hilog.error(DOMAIN, TAG, `写入文件失败: ${JSON.stringify(e)}`);
          return false;
        }

        // 记录分析事件
        interface ExportTrackProps extends Record<string, string | number | boolean> {
          feature: string;
          format: ExportFormat;
          filename: string;
        }
        const trackProps: ExportTrackProps = {
          feature: 'export',
          format: format,
          filename: filename
        };
        analytics.track(AnalyticsEvent.EXPORT_IMAGE, trackProps);

        return true;
      } else {
        hilog.warn(DOMAIN, TAG, 'User cancelled save dialog');
        return false;
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to save file: ${JSON.stringify(error)}`);
      return false;
    }
  }
}

// 导出单例
export const exportService = ExportService.getInstance();
