/**
 * SketchToVector.ets — 草图转矢量识别引擎（v1.1）
 *
 * 纯确定性几何算法版（无需AI模型，预览器/真机均可运行）：
 *   1. RDP (Ramer-Douglas-Peucker) 折线简化去噪
 *   2. 形状分类：闭合度 + 角点分布 + 直线度 + 箭头特征
 *   3. 输出标准形状参数（rectangle/circle/arrow/line 的首尾两点或中心）
 *
 * 后续可无缝替换为 MindSpore Lite 模型版（架构文档 §1.4.0），
 * 本类保持相同的 convert() 接口，白板页无需改动。
 */

export interface VecPoint { x: number; y: number; }

export interface VectorResult {
  shape: string;        // 'rectangle' | 'circle' | 'arrow' | 'line'
  points: VecPoint[];   // 标准形状参数：形状类为 [起点, 终点]
  confidence: number;   // 0-1
}

interface BBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface BBoxCorners {
  p0: VecPoint;
  p1: VecPoint;
}

export class SketchToVector {
  // ─── 入口：转换自由笔迹为标准形状 ───
  static convert(input: VecPoint[]): VectorResult | null {
    if (!input || input.length < 5) return null;

    const bbox = SketchToVector.boundingBox(input);
    const diag = Math.hypot(bbox.w, bbox.h);
    if (diag < 8) return null; // 过小忽略

    // 1. RDP 简化：epsilon 取包围盒对角线的 3%
    const simplified = SketchToVector.rdp(input, diag * 0.03);
    if (simplified.length < 2) return null;

    // 2. 闭合度判定
    const first = simplified[0];
    const last = simplified[simplified.length - 1];
    const closedDist = Math.hypot(last.x - first.x, last.y - first.y);
    const isClosed = closedDist < diag * 0.18;

    // 3. 周长检查
    const perimeter = SketchToVector.perimeter(input);
    if (perimeter < 10) return null;

    if (isClosed) {
      // ── 闭合图形：矩形 vs 圆 ──
      const corners = SketchToVector.detectCorners(simplified);
      if (corners >= 3 && corners <= 7 && SketchToVector.isRectangular(simplified, diag)) {
        const r = SketchToVector.bboxCorners(bbox);
        return { shape: 'rectangle', points: [r.p0, r.p1], confidence: 0.9 };
      }
      // 圆/椭圆：包围盒
      const b = SketchToVector.bboxCorners(bbox);
      return { shape: 'circle', points: [b.p0, b.p1], confidence: 0.85 };
    }

    // ── 开放图形：直线 vs 箭头 ──
    const maxDev = SketchToVector.maxPerpDistance(input, first, last);
    const span = Math.hypot(last.x - first.x, last.y - first.y);

    if (SketchToVector.hasArrowhead(input)) {
      return { shape: 'arrow', points: [first, last], confidence: 0.88 };
    }
    if (span > diag * 0.4 && maxDev < span * 0.06) {
      return { shape: 'line', points: [first, last], confidence: 0.92 };
    }

    return null; // 无法识别
  }

  // ─── RDP 折线简化 ───
  static rdp(points: VecPoint[], epsilon: number): VecPoint[] {
    if (points.length < 3) return points.slice();
    const first = points[0];
    const last = points[points.length - 1];
    let maxDist = 0;
    let index = 0;
    for (let i = 1; i < points.length - 1; i++) {
      const d = SketchToVector.pointLineDist(points[i], first, last);
      if (d > maxDist) {
        maxDist = d;
        index = i;
      }
    }
    if (maxDist > epsilon) {
      const left = SketchToVector.rdp(points.slice(0, index + 1), epsilon);
      const right = SketchToVector.rdp(points.slice(index), epsilon);
      return left.slice(0, -1).concat(right);
    }
    return [first, last];
  }

  // ─── 点到线段距离 ───
  private static pointLineDist(p: VecPoint, a: VecPoint, b: VecPoint): number {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const len2 = abx * abx + aby * aby;
    if (len2 === 0) return Math.hypot(p.x - a.x, p.y - a.y);
    const t = Math.max(0, Math.min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2));
    return Math.hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby));
  }

  // ─── 所有点到首尾连线的最大垂直偏移 ───
  private static maxPerpDistance(points: VecPoint[], a: VecPoint, b: VecPoint): number {
    let max = 0;
    for (const p of points) {
      const d = SketchToVector.pointLineDist(p, a, b);
      if (d > max) max = d;
    }
    return max;
  }

  // ─── 周长 ───
  private static perimeter(points: VecPoint[]): number {
    let sum = 0;
    for (let i = 1; i < points.length; i++) {
      sum += Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y);
    }
    return sum;
  }

  // ─── 包围盒 ───
  private static boundingBox(points: VecPoint[]): BBox {
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const p of points) {
      if (p.x < minX) minX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.x > maxX) maxX = p.x;
      if (p.y > maxY) maxY = p.y;
    }
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
  }

  private static bboxCorners(b: BBox): BBoxCorners {
    const p0: VecPoint = { x: b.x, y: b.y };
    const p1: VecPoint = { x: b.x + b.w, y: b.y + b.h };
    return { p0: p0, p1: p1 };
  }

  // ─── 角点检测：RDP 简化后方向突变点的数量 ───
  private static detectCorners(simplified: VecPoint[]): number {
    if (simplified.length < 3) return 0;
    let count = 0;
    const angleThreshold = Math.cos(Math.PI * 0.25); // 夹角 < 135° 视为转折
    for (let i = 1; i < simplified.length - 1; i++) {
      const a = simplified[i - 1];
      const b = simplified[i];
      const c = simplified[i + 1];
      const v1x = a.x - b.x, v1y = a.y - b.y;
      const v2x = c.x - b.x, v2y = c.y - b.y;
      const len1 = Math.hypot(v1x, v1y);
      const len2 = Math.hypot(v2x, v2y);
      if (len1 < 1 || len2 < 1) continue;
      const cos = (v1x * v2x + v1y * v2y) / (len1 * len2);
      if (cos < angleThreshold) count++;
    }
    return count;
  }

  // ─── 矩形判定 ───
  private static isRectangular(simplified: VecPoint[], diag: number): boolean {
    if (simplified.length < 4) return false;
    const b = SketchToVector.boundingBox(simplified);
    if (b.w < diag * 0.25 || b.h < diag * 0.25) return false;
    const corners = SketchToVector.detectCorners(simplified);
    return corners >= 3 && corners <= 7;
  }

  // ─── 箭头检测：末端 18% 段内存在方向折返（V形分叉） ───
  private static hasArrowhead(points: VecPoint[]): boolean {
    if (points.length < 6) return false;
    const n = points.length;
    const headStart = Math.floor(n * 0.82); // 末端 18%
    const tip = points[n - 1];
    const shaft = points[headStart];
    const dirX = tip.x - shaft.x;
    const dirY = tip.y - shaft.y;
    const dirLen = Math.hypot(dirX, dirY);
    if (dirLen < 5) return false;
    const ux = dirX / dirLen;
    const uy = dirY / dirLen;
    let devCount = 0;
    for (let i = headStart; i < n - 1; i++) {
      const dx = points[i].x - points[i - 1].x;
      const dy = points[i].y - points[i - 1].y;
      const l = Math.hypot(dx, dy);
      if (l < 2) continue;
      const dot = (dx * ux + dy * uy) / l;
      if (dot < Math.cos(Math.PI / 6.5)) devCount++; // 偏离 > ~28°
    }
    return devCount >= 1;
  }
}
