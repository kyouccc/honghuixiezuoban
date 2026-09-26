/**
 * StrokeEngine.ets — 笔触引擎 v1.1 + v2.0 增量（S1T01 / NP-02）
 *
 * v2.0 增量：
 *  - StrokeData 增补可选字段 brushShape/pressureCurve/opacity/blendMode/texture
 *    （对齐 proto StrokeData field 10-14，架构 §1.1 / §3.1）；
 *  - setTool 时自动套用 BrushRegistry 笔刷配置（荧光笔半透明 multiply、毛笔压感曲线等）；
 *  - finalizeStroke 将笔刷参数写入 StrokeData，随 CRDT 同步；
 *  - renderStrokeToContext 按 BrushRegistry 配置应用透明度/混合模式/压感曲线渲染。
 */

import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';
import { BrushRegistry, BrushConfig } from './BrushRegistry';
import { PressureSampler } from './PressureSampler';
import { Point3, StrokePayload } from './types/BoardModel';
import { fitToPoints } from './StrokeFitter';

const TAG_MODULE = 'StrokeEngine';

export interface Point {
  x: number;
  y: number;
  t: number;
  pressure: number;
}

export interface StrokeData {
  id: string;
  layerId: string;
  tool: string;
  color: string;
  width: number;
  points: Point[];
  createdAt: number;
  createdBy: string;
  // ─── v2.0 增量（可选，向后兼容 v1 元素）───
  brushShape?: string;        // round | flat | texture
  pressureCurve?: number[];   // 压感曲线控制点
  opacity?: number;           // 0-1
  blendMode?: string;         // normal | multiply
  texture?: string;           // 笔刷纹理 id
}

export interface StrokeStats {
  totalStrokes: number;
  avgRenderTimeMs: number;
}

export class StrokeEngine {
  private static instance: StrokeEngine | null = null;
  private isDrawing: boolean = false;
  private currentPoints: Point[] = [];
  private currentTool: string = 'pen';
  private currentColor: string = '#000000';
  private currentWidth: number = 3;
  private prevPoint: Point | null = null;
  private layerId: string = 'default';
  private userId: string = 'local';
  private totalStrokes: number = 0;
  private totalRenderTime: number = 0;
  // ─── v2.0 增量：笔刷状态 ───
  private currentBrushShape: string = 'round';
  private currentPressureCurve: number[] = [0, 0.3, 0.7, 1.0];
  private currentOpacity: number = 1.0;
  private currentBlendMode: string = 'normal';
  private currentTexture: string = '';

  static getInstance(): StrokeEngine {
    if (!StrokeEngine.instance) {
      StrokeEngine.instance = new StrokeEngine();
    }
    return StrokeEngine.instance;
  }

  setTool(tool: string): void {
    this.currentTool = tool;
    // v2.0：切换工具时套用注册表默认笔刷参数
    const cfg = BrushRegistry.getBrushConfig(tool);
    this.currentBrushShape = cfg.brushShape;
    this.currentPressureCurve = cfg.pressureCurve.slice();
    this.currentOpacity = cfg.opacity;
    this.currentBlendMode = cfg.blendMode;
    this.currentTexture = cfg.texture;
    Logger.info(TAG_MODULE, `Tool set: ${tool}, opacity=${cfg.opacity}, blend=${cfg.blendMode}`);
  }

  setColor(color: string): void {
    this.currentColor = color;
  }

  setWidth(width: number): void {
    this.currentWidth = Math.max(Constants.STROKE_MIN_WIDTH, Math.min(Constants.STROKE_MAX_WIDTH, width));
  }

  setLayerId(layerId: string): void {
    this.layerId = layerId;
  }

  setUserId(userId: string): void {
    this.userId = userId;
  }

  // ─── v2.0 增量：笔刷参数调节 ───
  setBrushShape(brushShape: string): void {
    this.currentBrushShape = brushShape;
  }

  setPressureCurve(curve: number[]): void {
    if (curve.length > 0) {
      this.currentPressureCurve = curve.slice();
    }
  }

  setOpacity(opacity: number): void {
    this.currentOpacity = Math.max(0, Math.min(1, opacity));
  }

  setBlendMode(blendMode: string): void {
    this.currentBlendMode = blendMode;
  }

  setTexture(texture: string): void {
    this.currentTexture = texture;
  }

  /** 应用完整笔刷配置（外部面板选择预设时调用） */
  applyBrushConfig(config: BrushConfig): void {
    this.currentBrushShape = config.brushShape;
    this.currentPressureCurve = config.pressureCurve.slice();
    this.currentOpacity = config.opacity;
    this.currentBlendMode = config.blendMode;
    this.currentTexture = config.texture;
  }

  handleTouchEvent(event: TouchEvent, scale: number, offsetX: number, offsetY: number): void {
    const touchType: number = event.type;
    if (touchType === TouchType.Down) {
      this.isDrawing = true;
      this.currentPoints = [];
      if (event.touches.length > 0) {
        const touch: TouchObject = event.touches[0];
        // S2-A / T2-2：真实压感优先（getHistoricalPoints().force），起笔默认 0.5
        const force: number = PressureSampler.resolveForce(event, 0.5);
        this.addPoint(touch.x, touch.y, force, scale, offsetX, offsetY);
      }
    } else if (touchType === TouchType.Move && this.isDrawing) {
      if (event.touches.length > 0) {
        const touch: TouchObject = event.touches[0];
        // S2-A / T2-2：真实压感优先；无压感设备回退速度模拟（A2-3：无压感回退无跳变）
        const sampled: number = PressureSampler.sampleForce(event);
        const canvasX: number = (touch.x - offsetX) / scale;
        const canvasY: number = (touch.y - offsetY) / scale;
        const force: number = sampled >= 0 ? sampled : this.simulateMovePressure(canvasX, canvasY);
        this.addPoint(touch.x, touch.y, force, scale, offsetX, offsetY);
      }
    } else if (touchType === TouchType.Up && this.isDrawing) {
      this.isDrawing = false;
      if (this.currentPoints.length >= 2) {
        const stroke: StrokeData = this.finalizeStroke();
        this.renderStroke(stroke);
        this.totalStrokes++;
      }
    }
  }

  /** 无压感速度模拟：由与上一点的位移估计压力（距离连续 → 压力连续，无跳变） */
  private simulateMovePressure(canvasX: number, canvasY: number): number {
    if (this.prevPoint === null) {
      return 0.5;
    }
    const dx: number = canvasX - this.prevPoint.x;
    const dy: number = canvasY - this.prevPoint.y;
    // 固定帧间隔 ~16ms 简化（模拟精度要求低，A2-3 只要求无跳变）
    return PressureSampler.estimateVelocityPressure(Math.sqrt(dx * dx + dy * dy), 16);
  }

  private addPoint(x: number, y: number, pressure: number, scale: number, offsetX: number, offsetY: number): void {
    const canvasX: number = (x - offsetX) / scale;
    const canvasY: number = (y - offsetY) / scale;
    const now: number = Date.now();
    const t: number = this.currentPoints.length > 0 ? now - this.currentPoints[0].t : 0;
    this.currentPoints.push({
      x: canvasX,
      y: canvasY,
      t: t,
      pressure: Math.min(1.0, Math.max(0.1, pressure))
    });
    this.prevPoint = { x: canvasX, y: canvasY, t: t, pressure: Math.min(1.0, Math.max(0.1, pressure)) };
  }

  private finalizeStroke(): StrokeData {
    const stroke: StrokeData = {
      id: `stroke_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`,
      layerId: this.layerId,
      tool: this.currentTool,
      color: this.currentColor,
      width: this.currentWidth,
      points: this.currentPoints.slice(),
      createdAt: Date.now(),
      createdBy: this.userId,
      brushShape: this.currentBrushShape,
      pressureCurve: this.currentPressureCurve.slice(),
      opacity: this.currentOpacity,
      blendMode: this.currentBlendMode,
      texture: this.currentTexture,
    };
    return stroke;
  }

  /**
   * ENG-02：把当前采集的原始采样点（压力 0–1）转换为合规 `{x, y, p}` 控制点序列（p 0–255）。
   * 经 StrokeFitter 二阶贝塞尔拟合压缩（体积较原始点降 60%+）。落盘 / 双链同步走此格式。
   */
  buildCompliantPoints(): Point3[] {
    if (this.currentPoints.length === 0) {
      return [];
    }
    const raw: Point3[] = [];
    for (let i = 0; i < this.currentPoints.length; i++) {
      const p: Point = this.currentPoints[i];
      raw.push({ x: p.x, y: p.y, p: p.pressure });
    }
    return fitToPoints(raw);
  }

  /**
   * ENG-02：提交当前笔迹为合规 StrokePayload（数据规范§三 payload.stroke）。
   * 仅当点数 ≥ 2 才视为有效笔迹；否则返回 null。
   */
  commitStrokePayload(): StrokePayload | null {
    if (this.currentPoints.length < 2) {
      return null;
    }
    const points: Point3[] = this.buildCompliantPoints();
    const payload: StrokePayload = {
      tool: this.currentTool,
      color: this.currentColor,
      width: this.currentWidth,
      points: points
    };
    return payload;
  }

  renderStroke(stroke: StrokeData): void {
    const startTime: number = Date.now();
    const points: Point[] = stroke.points;
    if (points.length < 2) {
      return;
    }
    const smoothed: Point[] = this.catmullRomSmooth(points);
    const elapsed: number = Date.now() - startTime;
    this.totalRenderTime += elapsed;
    if (elapsed > Constants.CANVAS_STROKE_LATENCY_MS) {
      Logger.warn(TAG_MODULE, `Stroke render exceeded limit: ${elapsed}ms`);
    }
  }

  /**
   * v2.0：按 BrushRegistry 配置渲染笔迹到指定上下文（页面/离屏持有 ctx）。
   * 应用透明度、混合模式（multiply）、压感曲线（逐段变宽）。
   */
  renderStrokeToContext(ctx: CanvasRenderingContext2D, stroke: StrokeData): void {
    if (!ctx || stroke.points.length < 2) {
      return;
    }
    const cfg = BrushRegistry.getBrushConfig(stroke.tool);
    const opacity: number = stroke.opacity !== undefined ? stroke.opacity : cfg.opacity;
    const blendMode: string = stroke.blendMode !== undefined ? stroke.blendMode : cfg.blendMode;
    const curve: number[] =
      stroke.pressureCurve !== undefined && stroke.pressureCurve.length > 0 ? stroke.pressureCurve : cfg.pressureCurve;
    const texture: string = stroke.texture !== undefined && stroke.texture.length > 0 ? stroke.texture : cfg.texture;
    const points: Point[] = this.catmullRomSmooth(stroke.points);
    const startTime: number = Date.now();
    ctx.save();
    ctx.globalAlpha = Math.max(0, Math.min(1, opacity));
    ctx.globalCompositeOperation = blendMode === 'multiply' ? 'multiply' : 'source-over';
    ctx.lineCap = texture === 'flat' ? 'butt' : 'round';
    ctx.lineJoin = 'round';
    ctx.strokeStyle = stroke.color;
    if (texture === 'grain') {
      ctx.setLineDash([1, 2]);
    } else if (texture === 'soft') {
      ctx.globalAlpha = Math.max(0, Math.min(1, opacity * 0.85));
    }
    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    for (let i = 1; i < points.length; i++) {
      const pressure: number = points[i].pressure;
      const t: number = BrushRegistry.samplePressureCurve(curve, pressure);
      ctx.lineWidth = Math.max(0.5, stroke.width * (0.4 + 0.6 * t));
      ctx.lineTo(points[i].x, points[i].y);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(points[i].x, points[i].y);
    }
    ctx.restore();
    const elapsed: number = Date.now() - startTime;
    this.totalRenderTime += elapsed;
    if (elapsed > Constants.CANVAS_STROKE_LATENCY_MS) {
      Logger.warn(TAG_MODULE, `renderStrokeToContext exceeded limit: ${elapsed}ms`);
    }
  }

  private catmullRomSmooth(points: Point[]): Point[] {
    if (points.length <= 2) {
      return points;
    }
    const result: Point[] = [points[0]];
    for (let i = 1; i < points.length - 2; i++) {
      const p0: Point = points[i - 1];
      const p1: Point = points[i];
      const p2: Point = points[i + 1];
      const p3: Point = points[i + 2];
      for (let t = 0; t <= 1; t += 0.5) {
        const tt: number = t * t;
        const ttt: number = tt * t;
        const x: number = 0.5 * (
          (2 * p1.x) +
          (-p0.x + p2.x) * t +
          (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * tt +
          (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * ttt
        );
        const y: number = 0.5 * (
          (2 * p1.y) +
          (-p0.y + p2.y) * t +
          (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * tt +
          (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * ttt
        );
        result.push({
          x: x, y: y,
          t: p1.t,
          pressure: p1.pressure + (p2.pressure - p1.pressure) * t
        });
      }
    }
    result.push(points[points.length - 1]);
    return result;
  }

  getStats(): StrokeStats {
    const avgMs: number = this.totalStrokes > 0 ? this.totalRenderTime / this.totalStrokes : 0;
    const stats: StrokeStats = { totalStrokes: this.totalStrokes, avgRenderTimeMs: avgMs };
    return stats;
  }

  reset(): void {
    this.currentPoints = [];
    this.isDrawing = false;
    this.totalStrokes = 0;
    this.totalRenderTime = 0;
  }
}
