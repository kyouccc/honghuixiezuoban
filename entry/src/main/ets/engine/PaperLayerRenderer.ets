/**
 * PaperLayerRenderer.ets — 纸图层渲染器（v2.0 增量，S1T01 / NP-01）
 *
 * 底纸模板（空白/网格/点阵/横线/四线格）渲染为本地背景图案。
 * 关键约束（架构 §1.1 / §8.1 约定 4）：纸图层（paper/page）不产生 CRDT 元素，
 * 仅作为"文档模型"的一部分随 .hcnote / 会话快照分发，协同中表现为只读背景。
 *
 * 渲染上下文由页面/离屏持有，本类不在组件字段外创建 RenderingContextSettings /
 * CanvasRenderingContext2D（遵循工程约束）；图案以基本图元直接绘制，P0 可满足
 * 5 种底纸切换 + 书写延迟 ≤9ms 验收（底纸只绘制一次，不参与每帧重绘）。
 */

import { Logger } from '../common/Logger';

const TAG_MODULE = 'PaperLayerRenderer';

export enum PaperTemplate {
  BLANK = 'blank',
  GRID = 'grid',
  DOT = 'dot',
  LINED = 'lined',
  FOUR_LINE = 'four_line',
}

export interface PaperTemplateInfo {
  template: string;
  name: string;
}

export class PaperLayerRenderer {
  private static readonly LINE_GAP: number = 24;      // 网格间距
  private static readonly DOT_GAP: number = 24;       // 点阵间距
  private static readonly LINED_GAP: number = 36;     // 横线行距
  private static readonly FOUR_LINE_GROUP: number = 40; // 四线格组高

  /** 底纸模板列表（UI 选择用） */
  static getTemplates(): PaperTemplateInfo[] {
    return [
      { template: PaperTemplate.BLANK, name: '空白' },
      { template: PaperTemplate.GRID, name: '网格' },
      { template: PaperTemplate.DOT, name: '点阵' },
      { template: PaperTemplate.LINED, name: '横线' },
      { template: PaperTemplate.FOUR_LINE, name: '四线格' },
    ];
  }

  static isSupported(template: string): boolean {
    return template === PaperTemplate.BLANK ||
      template === PaperTemplate.GRID ||
      template === PaperTemplate.DOT ||
      template === PaperTemplate.LINED ||
      template === PaperTemplate.FOUR_LINE;
  }

  /**
   * 在给定渲染上下文上绘制底纸图案。
   * @param ctx Canvas 渲染上下文（由页面/离屏持有）
   * @param template 底纸模板
   * @param w 画布宽（世界坐标）
   * @param h 画布高（世界坐标）
   * @param bgColor 底纸底色（十六进制字符串）。
   *        🔧 v2.6.0 审核修复（问题②-3 真因）：之前底色恒为 '#FFFFFF'，
   *        本方法只认模板（blank/grid/dot/lined/four_line），
   *        而「主题设置-画布纸张」写入的是 light/dark/dark_alt/warm/sepia，
   *        两套枚举完全不相交 → 用户怎么选纸张，画布都不变（审核员判为「设置无效」）。
   *        现在把底色作为参数下传，由 ThemeManager.getCanvasPaperColor() 提供，
   *        并据底色亮度自动切换网格线颜色，深色纸张下图案依然可见。
   */
  static renderPaper(ctx: CanvasRenderingContext2D, template: string, w: number, h: number,
                     bgColor?: string): void {
    if (!ctx || w <= 0 || h <= 0) {
      Logger.warn(TAG_MODULE, `renderPaper: invalid size ${w}x${h}`);
      return;
    }
    const bg: string = (bgColor !== undefined && bgColor !== null && bgColor.length > 0)
      ? bgColor : '#FFFFFF';
    const dark: boolean = PaperLayerRenderer.isDarkColor(bg);
    ctx.save();
    ctx.globalAlpha = 1.0;
    ctx.globalCompositeOperation = 'source-over';
    if (template === PaperTemplate.GRID) {
      PaperLayerRenderer.renderGrid(ctx, w, h, bg, dark);
    } else if (template === PaperTemplate.DOT) {
      PaperLayerRenderer.renderDot(ctx, w, h, bg, dark);
    } else if (template === PaperTemplate.LINED) {
      PaperLayerRenderer.renderLined(ctx, w, h, bg, dark);
    } else if (template === PaperTemplate.FOUR_LINE) {
      PaperLayerRenderer.renderFourLine(ctx, w, h, bg, dark);
    } else {
      PaperLayerRenderer.renderBlank(ctx, w, h, bg);
    }
    ctx.restore();
  }

  /**
   * 判断底色是否为深色（相对亮度 < 0.5）。支持 #RGB / #RRGGBB。
   * 用于在深色纸张下把网格线切到浅色，保证图案可见。
   */
  private static isDarkColor(hex: string): boolean {
    let raw: string = hex.trim();
    if (raw.startsWith('#')) {
      raw = raw.substring(1);
    }
    if (raw.length === 3) {
      const r3: string = raw.substring(0, 1);
      const g3: string = raw.substring(1, 2);
      const b3: string = raw.substring(2, 3);
      raw = `${r3}${r3}${g3}${g3}${b3}${b3}`;
    }
    if (raw.length !== 6) {
      return false;
    }
    const r: number = parseInt(raw.substring(0, 2), 16);
    const g: number = parseInt(raw.substring(2, 4), 16);
    const b: number = parseInt(raw.substring(4, 6), 16);
    if (Number.isNaN(r) || Number.isNaN(g) || Number.isNaN(b)) {
      return false;
    }
    // ITU-R BT.601 亮度
    const luminance: number = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    return luminance < 0.5;
  }

  private static renderBlank(ctx: CanvasRenderingContext2D, w: number, h: number, bg: string): void {
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, w, h);
  }

  private static renderGrid(ctx: CanvasRenderingContext2D, w: number, h: number,
                            bg: string, dark: boolean): void {
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, w, h);
    const gap: number = PaperLayerRenderer.LINE_GAP;
    ctx.strokeStyle = dark ? '#3D3D3D' : '#D0D7DE';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let x = 0; x <= w; x += gap) {
      ctx.moveTo(x, 0);
      ctx.lineTo(x, h);
    }
    for (let y = 0; y <= h; y += gap) {
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
    }
    ctx.stroke();
  }

  private static renderDot(ctx: CanvasRenderingContext2D, w: number, h: number,
                           bg: string, dark: boolean): void {
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, w, h);
    const gap: number = PaperLayerRenderer.DOT_GAP;
    ctx.fillStyle = dark ? '#4A4A4A' : '#C9CDD4';
    for (let y = gap / 2; y < h; y += gap) {
      for (let x = gap / 2; x < w; x += gap) {
        ctx.beginPath();
        ctx.arc(x, y, 1.2, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  private static renderLined(ctx: CanvasRenderingContext2D, w: number, h: number,
                             bg: string, dark: boolean): void {
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, w, h);
    const gap: number = PaperLayerRenderer.LINED_GAP;
    ctx.strokeStyle = dark ? '#4A5A6A' : '#B8C4D0';
    ctx.lineWidth = 1;
    ctx.beginPath();
    for (let y = gap; y <= h; y += gap) {
      ctx.moveTo(0, y);
      ctx.lineTo(w, y);
    }
    ctx.stroke();
  }

  /** 四线格（英语书写本）：3 条灰细线 + 1 条红基线为一组 */
  private static renderFourLine(ctx: CanvasRenderingContext2D, w: number, h: number,
                                bg: string, dark: boolean): void {
    ctx.fillStyle = bg;
    ctx.fillRect(0, 0, w, h);
    const group: number = PaperLayerRenderer.FOUR_LINE_GROUP;
    ctx.lineWidth = 1;
    ctx.strokeStyle = dark ? '#4A5A6A' : '#B0BBC6';
    ctx.beginPath();
    for (let y = 0; y <= h; y += group) {
      ctx.moveTo(0, y + 8);
      ctx.lineTo(w, y + 8);
      ctx.moveTo(0, y + 16);
      ctx.lineTo(w, y + 16);
      ctx.moveTo(0, y + 24);
      ctx.lineTo(w, y + 24);
    }
    ctx.stroke();
    ctx.strokeStyle = dark ? '#8A4A4A' : '#E57373';
    ctx.beginPath();
    for (let y = 0; y <= h; y += group) {
      ctx.moveTo(0, y + 32);
      ctx.lineTo(w, y + 32);
    }
    ctx.stroke();
  }
}
