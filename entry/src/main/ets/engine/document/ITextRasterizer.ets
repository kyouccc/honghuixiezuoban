/**
 * ITextRasterizer.ets — 文档栅格化抽象接口（v2.0 增量，S1T02 / NP-05）
 *
 * P0 实现：PDFRasterizer（PDF 页面栅格化为位图）。
 * P1 扩展：CAJ 通过服务端转换或引导自转 PDF 后走本管线（架构 Q-01 决策）；
 *         EPUB 复用 HTML 排版引擎栅格化（EPUBRasterizer，架构文件列表 P1 可选）。
 */

import image from '@ohos.multimedia.image';

/** 栅格化选项 */
export interface RasterizeOptions {
  maxPages: number;          // 最大页数（免费版 PDF_FREE_PAGE_LIMIT=10）
  scale: number;             // 栅格化缩放（>0，默认 1.0）
  backgroundColor: string;   // 页面底色（如 '#FFFFFF'）
}

/** 单页栅格化结果 */
export interface RasterizedPage {
  index: number;             // 页面号（从 0 开始）
  width: number;             // 页面宽（世界坐标 pt）
  height: number;            // 页面高（世界坐标 pt）
  bitmap: image.PixelMap | null;  // 页面位图（PageLayer 只读底图）
}

/** 文档栅格化错误码（对齐 REST 错误码 1105） */
export const DOC_RASTERIZE_ERROR_CODE: number = 1105;

/** 文档栅格化异常 */
export class DocumentRasterizeError extends Error {
  code: number;
  detail: string;

  constructor(code: number, detail: string) {
    super(detail);
    this.code = code;
    this.detail = detail;
  }
}

/** 栅格化抽象接口（P0 实现 PDFRasterizer；P1 扩展 CAJ/EPUB 插件位，接入不破坏架构） */
export interface ITextRasterizer {
  supports(format: string): boolean;
  rasterize(uri: string, options: RasterizeOptions): Promise<RasterizedPage[]>;
}
