/**
 * EyedropperTool.ets — 取色器工具（P0-4）
 *
 * 功能：
 *  1. 从画布像素采样颜色（pickColorAt）；
 *  2. 从元素颜色字段采样（pickColorFromElement）；
 *  3. 颜色历史记录（recentColors，最多 12 色）；
 *  4. 颜色格式转换（hex / rgb / hsl）。
 *
 * 架构：纯逻辑工具类。像素采样需外部注入回调。
 */

import { Logger } from '../common/Logger';

const TAG = 'EyedropperTool';

/** RGB 颜色 */
export interface RGBColor {
  r: number;
  g: number;
  b: number;
  a: number;
}

/** HSL 颜色 */
export interface HSLColor {
  h: number;
  s: number;
  l: number;
}

const MAX_RECENT = 12;

export class EyedropperTool {
  private recentColors: string[] = [];
  private pickedColor: string = '#000000';

  /** 从画布坐标读取像素 RGBA */
  public samplePixel: (x: number, y: number) => [number, number, number, number] | null = () => null;

  /** 从画布坐标拾取颜色 */
  pickColorAt(x: number, y: number): string | null {
    const rgba = this.samplePixel(x, y);
    if (!rgba) {
      Logger.warn(TAG, `pickColorAt: 无法采样 (${x}, ${y})`);
      return null;
    }
    const hex = EyedropperTool.rgbToHex(rgba[0], rgba[1], rgba[2], rgba[3]);
    this.pickedColor = hex;
    this.addToRecent(hex);
    return hex;
  }

  /** 从元素颜色字段拾取 */
  pickColorFromElement(color: string): string {
    const normalized = EyedropperTool.normalizeHex(color);
    this.pickedColor = normalized;
    this.addToRecent(normalized);
    return normalized;
  }

  get currentColor(): string { return this.pickedColor; }

  // ── 颜色历史 ──

  get recent(): readonly string[] { return this.recentColors; }

  addToRecent(hex: string): void {
    const normalized = EyedropperTool.normalizeHex(hex);
    const idx = this.recentColors.indexOf(normalized);
    if (idx >= 0) this.recentColors.splice(idx, 1);
    this.recentColors.unshift(normalized);
    if (this.recentColors.length > MAX_RECENT) {
      this.recentColors = this.recentColors.slice(0, MAX_RECENT);
    }
  }

  clearRecent(): void {
    this.recentColors = [];
  }

  // ── 颜色转换 ──

  static rgbToHex(r: number, g: number, b: number, a: number = 255): string {
    const clamp = (v: number) => Math.max(0, Math.min(255, Math.round(v)));
    const rh = clamp(r).toString(16).padStart(2, '0');
    const gh = clamp(g).toString(16).padStart(2, '0');
    const bh = clamp(b).toString(16).padStart(2, '0');
    if (a < 255) {
      const ah = clamp(a).toString(16).padStart(2, '0');
      return `#${rh}${gh}${bh}${ah}`;
    }
    return `#${rh}${gh}${bh}`;
  }

  static hexToRgb(hex: string): RGBColor {
    const h = EyedropperTool.normalizeHex(hex).replace('#', '');
    const r = parseInt(h.substring(0, 2), 16);
    const g = parseInt(h.substring(2, 4), 16);
    const b = parseInt(h.substring(4, 6), 16);
    const a = h.length >= 8 ? parseInt(h.substring(6, 8), 16) : 255;
    return { r, g, b, a };
  }

  static rgbToHsl(r: number, g: number, b: number): HSLColor {
    const rn = r / 255;
    const gn = g / 255;
    const bn = b / 255;
    const max = Math.max(rn, gn, bn);
    const min = Math.min(rn, gn, bn);
    const l = (max + min) / 2;
    let h = 0;
    let s = 0;

    if (max !== min) {
      const d = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      switch (max) {
        case rn: h = (gn - bn) / d + (gn < bn ? 6 : 0); break;
        case gn: h = (bn - rn) / d + 2; break;
        case bn: h = (rn - gn) / d + 4; break;
        default: break;
      }
      h *= 60;
    }
    return { h, s, l };
  }

  static hslToRgb(h: number, s: number, l: number): RGBColor {
    const c = (1 - Math.abs(2 * l - 1)) * s;
    const hp = h / 60;
    const x = c * (1 - Math.abs(hp % 2 - 1));
    let r = 0, g = 0, b = 0;

    if (hp >= 0 && hp < 1) { r = c; g = x; }
    else if (hp < 2) { r = x; g = c; }
    else if (hp < 3) { g = c; b = x; }
    else if (hp < 4) { g = x; b = c; }
    else if (hp < 5) { r = x; b = c; }
    else { r = c; b = x; }

    const m = l - c / 2;
    return {
      r: Math.round((r + m) * 255),
      g: Math.round((g + m) * 255),
      b: Math.round((b + m) * 255),
      a: 255,
    };
  }

  static normalizeHex(hex: string): string {
    let h = hex.trim().toLowerCase();
    if (!h.startsWith('#')) h = '#' + h;
    if (h.length === 4) {
      h = '#' + h[1] + h[1] + h[2] + h[2] + h[3] + h[3];
    }
    return h;
  }

  /** 颜色亮度（0-1） */
  static luminance(hex: string): number {
    const c = EyedropperTool.hexToRgb(hex);
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255;
  }

  /** 是否需要深色文字 */
  static needsDarkText(hex: string): boolean {
    return EyedropperTool.luminance(hex) > 0.5;
  }
}
