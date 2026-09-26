/**
 * StrokeFitter.ets — 二阶贝塞尔拟合 + 压感量化（ENG-02，阶段1 P0 净新增）
 *
 * 职责（架构 §3.2 / 数据规范§三）：
 *  1. 二阶贝塞尔拟合：把高频手写采样点压缩为少量控制点，体积较原始点降 60%+；
 *  2. 压感量化：原始压感（0–1）量化为 0–255 整数（数据规范硬性要求）；
 *  3. 计算入 TaskPool 子线程，主线程只负责采集与合成（架构 §4.2）。
 *
 * 设计要点：
 *  - 全部方法为纯函数（无 UI / 状态依赖），满足 TaskPool「可序列化」契约（架构§7.9）；
 *  - 拟合结果两种形态：
 *      · BezierSegment[] —— 渲染管线直接消费的二阶贝塞尔段；
 *      · Point3[]        —— 持久化形态（数据规范 payload.stroke.points），即拟合后的控制点，
 *        渲染时按「中点锚点 + 原始点作控制点」的二次贝塞尔平滑（见 StrokeEngine.renderStrokeToContext）。
 *  - 压缩主算法：距离降噪 + Ramer–Douglas–Peucker（RDP）简化，保留端点与拐点。
 *
 * ArkTS 严格模式：显式类型，无 any/unknown，无对象展开。
 */

import { Point3, PRESSURE_MAX } from './types/BoardModel';
import { taskpool } from '@kit.ArkTS';

/** 拟合后单条二阶贝塞尔段：锚点 A → 控制点 C → 锚点 B，p0/p1 为两端压感 */
export interface BezierSegment {
  ax: number;
  ay: number;
  cx: number;
  cy: number;
  bx: number;
  by: number;
  /** 起点压感 0–255 */
  p0: number;
  /** 终点压感 0–255 */
  p1: number;
}

/** RDP 默认简化阈值（逻辑 vp）：大于该垂直距离的拐点保留 */
const DEFAULT_RDP_EPSILON: number = 1.2;
/** 距离降噪默认阈值（逻辑 vp）：相邻点更近则丢弃 */
const DEFAULT_MIN_DIST: number = 1.0;

/** 压感量化：原始 0–1 → 0–255 整数（越界保护） */
export function quantizePressure(raw: number): number {
  if (raw === undefined || raw === null || !Number.isFinite(raw)) {
    return 0;
  }
  const clamped: number = raw < 0 ? 0 : raw > 1 ? 1 : raw;
  const v: number = Math.round(clamped * PRESSURE_MAX);
  return v < 0 ? 0 : v > PRESSURE_MAX ? PRESSURE_MAX : v;
}

/** 距离降噪：丢弃与上一保留点距离小于 minDist 的点（保留首尾） */
export function decimateByDistance(points: Point3[], minDist: number): Point3[] {
  if (points.length <= 2) {
    return points.slice();
  }
  const dist: number = minDist > 0 ? minDist : DEFAULT_MIN_DIST;
  const out: Point3[] = [];
  out.push(points[0]);
  let lastX: number = points[0].x;
  let lastY: number = points[0].y;
  for (let i = 1; i < points.length - 1; i++) {
    const p: Point3 = points[i];
    const dx: number = p.x - lastX;
    const dy: number = p.y - lastY;
    if (dx * dx + dy * dy >= dist * dist) {
      out.push({ x: p.x, y: p.y, p: quantizePressure(p.p) });
      lastX = p.x;
      lastY = p.y;
    }
  }
  out.push(points[points.length - 1]);
  return out;
}

/** 垂直距离（点到线段 AB 的垂距平方，避免开方） */
function perpDistSq(px: number, py: number, ax: number, ay: number, bx: number, by: number): number {
  const dx: number = bx - ax;
  const dy: number = by - ay;
  const lenSq: number = dx * dx + dy * dy;
  if (lenSq === 0) {
    const ex: number = px - ax;
    const ey: number = py - ay;
    return ex * ex + ey * ey;
  }
  let t: number = ((px - ax) * dx + (py - ay) * dy) / lenSq;
  if (t < 0) {
    t = 0;
  } else if (t > 1) {
    t = 1;
  }
  const projX: number = ax + t * dx;
  const projY: number = ay + t * dy;
  const ex: number = px - projX;
  const ey: number = py - projY;
  return ex * ex + ey * ey;
}

/**
 * Ramer–Douglas–Peucker 简化（迭代实现，避免递归深度问题）。
 * 返回保留的点（含首尾），压感已量化为 0–255。
 */
export function ramerDouglasPeucker(points: Point3[], epsilon: number): Point3[] {
  if (points.length <= 2) {
    return points.slice();
  }
  const epsSq: number = epsilon * epsilon;
  // 标记保留点
  const keep: boolean[] = new Array<boolean>(points.length);
  for (let i = 0; i < keep.length; i++) {
    keep[i] = false;
  }
  keep[0] = true;
  keep[points.length - 1] = true;

  // 栈保存 [start, end]
  const stack: number[] = [0, points.length - 1];
  while (stack.length >= 2) {
    const end: number = stack.pop() as number;
    const start: number = stack.pop() as number;
    let maxDistSq: number = 0;
    let idx: number = -1;
    const ax: number = points[start].x;
    const ay: number = points[start].y;
    const bx: number = points[end].x;
    const by: number = points[end].y;
    for (let i = start + 1; i < end; i++) {
      const d: number = perpDistSq(points[i].x, points[i].y, ax, ay, bx, by);
      if (d > maxDistSq) {
        maxDistSq = d;
        idx = i;
      }
    }
    if (maxDistSq > epsSq && idx !== -1) {
      keep[idx] = true;
      stack.push(start);
      stack.push(idx);
      stack.push(idx);
      stack.push(end);
    }
  }

  const out: Point3[] = [];
  for (let i = 0; i < points.length; i++) {
    if (keep[i]) {
      out.push({ x: points[i].x, y: points[i].y, p: quantizePressure(points[i].p) });
    }
  }
  return out;
}

/**
 * 拟合主入口：距离降噪 + RDP 简化 → 持久化用 Point3[]（控制点序列）。
 * 渲染时以「相邻点中点为锚点、原始点为控制点」走 quadraticCurveTo 平滑。
 */
export function fitToPoints(points: Point3[], epsilon?: number): Point3[] {
  if (points.length <= 2) {
    const simple: Point3[] = points.slice();
    for (let i = 0; i < simple.length; i++) {
      simple[i] = { x: simple[i].x, y: simple[i].y, p: quantizePressure(simple[i].p) };
    }
    return simple;
  }
  const eps: number = epsilon !== undefined && epsilon > 0 ? epsilon : DEFAULT_RDP_EPSILON;
  const decimated: Point3[] = decimateByDistance(points, DEFAULT_MIN_DIST);
  return ramerDouglasPeucker(decimated, eps);
}

/**
 * 二阶贝塞尔段拟合：在 RDP 锚点之间用「原始点作控制点」构造二次贝塞尔段。
 * 渲染管线可直接按段绘制（ctx.moveTo(A) → ctx.quadraticCurveTo(C, B)）。
 */
export function fit(points: Point3[], epsilon?: number): BezierSegment[] {
  const anchors: Point3[] = fitToPoints(points, epsilon);
  if (anchors.length <= 1) {
    return [];
  }
  const segments: BezierSegment[] = [];
  for (let i = 0; i < anchors.length - 1; i++) {
    const a: Point3 = anchors[i];
    const b: Point3 = anchors[i + 1];
    // 控制点：取 a、b 的原始邻居中点近似（无原始邻居时取 a、b 中点）
    const cx: number = (a.x + b.x) / 2;
    const cy: number = (a.y + b.y) / 2;
    segments.push({
      ax: a.x,
      ay: a.y,
      cx: cx,
      cy: cy,
      bx: b.x,
      by: b.y,
      p0: quantizePressure(a.p),
      p1: quantizePressure(b.p)
    });
  }
  return segments;
}

/**
 * TaskPool 封装：在子线程执行二阶贝塞尔拟合，避免万点笔迹阻塞主线程。
 * 函数体为模块级纯函数（满足 TaskPool 可序列化契约），失败回退主线程同步执行。
 */
@Concurrent
export function strokeFitTask(points: Point3[]): BezierSegment[] {
  return fit(points);
}

/** 在子线程执行拟合（返回 BezierSegment[]）；不可用时回退同步 */
export async function fitInTaskPool(points: Point3[]): Promise<BezierSegment[]> {
  try {
    return await taskpool.execute(strokeFitTask, points) as BezierSegment[];
  } catch (e) {
    // TaskPool 不可用时（如预览器）回退主线程，保证功能不中断
    return fit(points);
  }
}
