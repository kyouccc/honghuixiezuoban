/**
 * FillTool.ets — 填充工具（P0-4 / v2.7.0 性能根治）
 *
 * 功能：
 *  1. 油漆桶填充（floodFill）：从点击位置向连通区域填充颜色；
 *  2. 容差控制（tolerance）：颜色相近的像素一并填充；
 *  3. 仅填充空白区域模式（fillEmptyOnly）：不覆盖已有笔迹。
 *
 * ══════════════════════════════════════════════════════════════════════
 * v2.7.0 审核修复（问题①-1「选择填功能后页面点击其它功能无响应，需要重启」）
 *
 * 真因：旧实现的 PixelAccessor 是**逐像素**回调，页面侧实现为：
 *     getPixel() → ctx.getImageData(x, y, 1, 1)
 *     setPixel() → ctx.createImageData(1,1) + ctx.putImageData(d, x, y)
 *   即每个像素一次 GPU↔CPU 同步往返。在 PAD（1920×2880）上填充一块连通区域
 *   动辄命中数十万~数百万像素 → 数百万次同步回读/上传，主线程被彻底钉死，
 *   表现为「点填之后整页点不动、只能杀进程重启」。
 *
 * 修法：PixelAccessor 升级为 **PixelBuffer**（整幅批量读写）：
 *     loadPixels()  → 一次 getImageData(0,0,w,h) 把整幅像素取到内存
 *     flushPixels() → 一次 putImageData 写回
 *   扫描线算法全程只操作内存中的 Uint8ClampedArray，GPU 往返从「数百万次」降到 **2 次**。
 *   访问标记由 boolean[] 改为 Uint8Array（1920×2880 下内存占用从数十 MB 降到 ~5MB）。
 * ══════════════════════════════════════════════════════════════════════
 */

import { Logger } from '../common/Logger';
import { EyedropperTool, RGBColor } from './EyedropperTool';

const TAG = 'FillTool';

/** 填充模式 */
export enum FillMode {
  /** 油漆桶：替换连通区域内所有相似颜色 */
  BUCKET = 'bucket',
  /** 仅填充空白（透明/白色）区域 */
  EMPTY_ONLY = 'empty_only',
}

/**
 * 整幅像素缓冲接口（由外部注入）。
 * 实现方必须保证 loadPixels/flushPixels 各自只做一次批量 GPU 操作。
 */
export interface PixelBuffer {
  getWidth(): number;
  getHeight(): number;
  /** 一次性取出整幅 RGBA（长度 = w*h*4），只有一次 GPU 回读 */
  loadPixels(): Uint8ClampedArray | null;
  /** 一次性写回整幅 RGBA，只有一次 GPU 上传 */
  flushPixels(data: Uint8ClampedArray): void;
}

/** 填充结果 */
export interface FillOutcome {
  /** 是否实际执行了填充 */
  ok: boolean;
  /** 被填充的像素数 */
  filledCount: number;
  /** 未执行/失败原因（ok=true 时为空串） */
  reason: string;
}

/**
 * 安全上限：单次填充最多处理的像素数。
 * 超过则拒绝执行并给出明确提示，避免极端情况下长时间占用主线程。
 * 12,000,000 px ≈ 2000×6000，已远大于本项目最大画布。
 */
const MAX_FILL_PIXELS: number = 12000000;

export class FillTool {
  private mode: FillMode = FillMode.BUCKET;
  /** 颜色容差（0-255） */
  private tolerance: number = 32;
  /** 填充颜色 */
  private fillColor: string = '#FF0000';

  // ── 配置 ──

  setMode(mode: FillMode): void { this.mode = mode; }
  setTolerance(t: number): void { this.tolerance = Math.max(0, Math.min(255, t)); }
  setFillColor(hex: string): void { this.fillColor = EyedropperTool.normalizeHex(hex); }

  get currentColor(): string { return this.fillColor; }
  get currentTolerance(): number { return this.tolerance; }

  // ── 油漆桶填充（Flood Fill） ──

  /**
   * 从起点 (startX, startY) 执行洪水填充（扫描线算法，避免递归栈溢出）。
   *
   * v2.7.0：改为整幅批量读写 —— 全流程只在内存数组中扫描，
   * GPU 往返恒为 2 次（loadPixels + flushPixels）。
   */
  floodFill(buffer: PixelBuffer, startX: number, startY: number): FillOutcome {
    const w: number = buffer.getWidth();
    const h: number = buffer.getHeight();
    if (w <= 0 || h <= 0) {
      return { ok: false, filledCount: 0, reason: '画布尺寸无效' };
    }
    if (w * h > MAX_FILL_PIXELS) {
      Logger.warn(TAG, `floodFill: 画布过大 ${w}x${h}，拒绝执行`);
      return { ok: false, filledCount: 0, reason: `画布过大（${w}×${h}），暂不支持填充` };
    }
    if (startX < 0 || startX >= w || startY < 0 || startY >= h) {
      Logger.warn(TAG, `floodFill: 起点越界 (${startX}, ${startY})`);
      return { ok: false, filledCount: 0, reason: '点击位置超出画布' };
    }

    // ① 一次性取整幅像素（唯一一次 GPU 回读）
    const px: Uint8ClampedArray | null = buffer.loadPixels();
    if (px === null || px.length < w * h * 4) {
      Logger.error(TAG, 'floodFill: 像素读取失败');
      return { ok: false, filledCount: 0, reason: '无法读取画布像素' };
    }

    const fillRgb: RGBColor = EyedropperTool.hexToRgb(this.fillColor);
    const startIdx: number = (startY * w + startX) * 4;
    const tr: number = px[startIdx];
    const tg: number = px[startIdx + 1];
    const tb: number = px[startIdx + 2];
    const ta: number = px[startIdx + 3];

    // 目标色与填充色一致 → 无事可做
    if (this.rgbaMatch(tr, tg, tb, ta, fillRgb.r, fillRgb.g, fillRgb.b, fillRgb.a)) {
      return { ok: true, filledCount: 0, reason: '该区域已是当前颜色' };
    }

    // ② 纯内存扫描线填充
    const visited: Uint8Array = new Uint8Array(w * h);
    const stackX: Int32Array = new Int32Array(w * h + 4);
    const stackY: Int32Array = new Int32Array(w * h + 4);
    let sp: number = 0;
    stackX[sp] = startX;
    stackY[sp] = startY;
    sp++;

    let filledCount: number = 0;
    const tol: number = this.tolerance;
    const emptyOnly: boolean = this.mode === FillMode.EMPTY_ONLY;

    while (sp > 0) {
      sp--;
      const sx: number = stackX[sp];
      let sy: number = stackY[sp];

      // 向上找到 span 顶端
      while (sy >= 0 && this.pixelMatches(px, w, sx, sy, tr, tg, tb, ta, tol, emptyOnly)) {
        sy--;
      }
      sy++;

      let spanLeft: boolean = false;
      let spanRight: boolean = false;

      while (sy < h && this.pixelMatches(px, w, sx, sy, tr, tg, tb, ta, tol, emptyOnly)) {
        const idx: number = sy * w + sx;
        if (visited[idx] === 1) {
          sy++;
          continue;
        }
        visited[idx] = 1;

        // 就地写入填充色
        const p: number = idx * 4;
        px[p] = fillRgb.r;
        px[p + 1] = fillRgb.g;
        px[p + 2] = fillRgb.b;
        px[p + 3] = fillRgb.a;
        filledCount++;

        if (sx > 0) {
          const leftMatch: boolean = visited[sy * w + (sx - 1)] === 0
            && this.pixelMatches(px, w, sx - 1, sy, tr, tg, tb, ta, tol, emptyOnly);
          if (!spanLeft && leftMatch) {
            stackX[sp] = sx - 1; stackY[sp] = sy; sp++;
            spanLeft = true;
          } else if (spanLeft && !leftMatch) {
            spanLeft = false;
          }
        }

        if (sx < w - 1) {
          const rightMatch: boolean = visited[sy * w + (sx + 1)] === 0
            && this.pixelMatches(px, w, sx + 1, sy, tr, tg, tb, ta, tol, emptyOnly);
          if (!spanRight && rightMatch) {
            stackX[sp] = sx + 1; stackY[sp] = sy; sp++;
            spanRight = true;
          } else if (spanRight && !rightMatch) {
            spanRight = false;
          }
        }
        sy++;
      }
    }

    if (filledCount === 0) {
      return { ok: true, filledCount: 0, reason: '该区域无可填充像素' };
    }

    // ③ 一次性写回（唯一一次 GPU 上传）
    buffer.flushPixels(px);
    Logger.info(TAG, `floodFill: 填充 ${filledCount} 像素`);
    return { ok: true, filledCount: filledCount, reason: '' };
  }

  /** 读取内存缓冲中某像素是否满足填充条件 */
  private pixelMatches(px: Uint8ClampedArray, w: number, x: number, y: number,
                       tr: number, tg: number, tb: number, ta: number,
                       tol: number, emptyOnly: boolean): boolean {
    const p: number = (y * w + x) * 4;
    if (emptyOnly) {
      // 仅填充透明 / 接近白色
      if (px[p + 3] < 10) {
        return true;
      }
      return px[p] > 240 && px[p + 1] > 240 && px[p + 2] > 240;
    }
    const da: number = Math.abs(px[p + 3] - ta);
    if (da > tol) {
      return false;
    }
    // 透明像素之间只比 alpha，避免半透明边缘因 RGB 噪点被误拒
    if (ta < 10 && px[p + 3] < 10) {
      return true;
    }
    return Math.abs(px[p] - tr) <= tol
      && Math.abs(px[p + 1] - tg) <= tol
      && Math.abs(px[p + 2] - tb) <= tol;
  }

  /** RGBA 是否在容差内匹配 */
  private rgbaMatch(r1: number, g1: number, b1: number, a1: number,
                    r2: number, g2: number, b2: number, a2: number): boolean {
    const tol: number = this.tolerance;
    return Math.abs(r1 - r2) <= tol && Math.abs(g1 - g2) <= tol
      && Math.abs(b1 - b2) <= tol && Math.abs(a1 - a2) <= tol;
  }
}
