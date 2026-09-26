import { Point, StrokeEngine } from './StrokeEngine';
import { LayerManager } from './LayerManager';

export enum EraserMode {
  POINT = 'point',
  LINE = 'line',
  REGION = 'region',
}

export class EraserTool {
  private mode: EraserMode = EraserMode.POINT;
  private eraserRadius: number = 20;
  private isErasing: boolean = false;

  setMode(mode: EraserMode): void { this.mode = mode; }
  setRadius(radius: number): void { this.eraserRadius = radius; }

  // 点擦 — 圆形碰撞检测
  eraseAtPoint(x: number, y: number): string[] {
    const layerManager = LayerManager.getInstance();
    const activeLayer = layerManager.getActiveLayer();
    if (!activeLayer) return [];

    const erasedIds: string[] = [];
    const strokes = layerManager.getStrokes(activeLayer.id);
    
    for (const element of strokes) {
      if (element.deleted) continue;
      if (this.isPointNearStroke(x, y, element.value.points)) {
        element.deleted = true;
        erasedIds.push(element.value.id);
      }
    }
    
    return erasedIds;
  }

  // 线擦 — 线段碰撞检测

  eraseAlongLine(points: Point[]): string[] {
    const layerManager = LayerManager.getInstance();
    const activeLayer = layerManager.getActiveLayer();
    if (!activeLayer) return [];

    const erasedIds: string[] = [];
    const strokes = layerManager.getStrokes(activeLayer.id);

    for (let i = 1; i < points.length; i++) {
      for (const element of strokes) {
        if (element.deleted) continue;
        if (this.isLineNearStroke(points[i-1], points[i], element.value.points)) {
          element.deleted = true;
          erasedIds.push(element.value.id);
        }
      }
    }

    return erasedIds;
  }

  // 区域擦 — 矩形碰撞检测
  eraseInRect(x: number, y: number, w: number, h: number): string[] {
    const layerManager = LayerManager.getInstance();
    const activeLayer = layerManager.getActiveLayer();
    if (!activeLayer) return [];

    const erasedIds: string[] = [];
    const strokes = layerManager.getStrokes(activeLayer.id);

    for (const element of strokes) {
      if (element.deleted) continue;
      if (this.isStrokeInRect(element.value.points, x, y, w, h)) {
        element.deleted = true;
        erasedIds.push(element.value.id);
      }
    }

    return erasedIds;
  }

  // ─── 碰撞检测 ───

  private isPointNearStroke(px: number, py: number, points: Point[]): boolean {
    for (const point of points) {
      const dx = point.x - px;
      const dy = point.y - py;
      if (Math.sqrt(dx * dx + dy * dy) <= this.eraserRadius) {
        return true;
      }
    }
    return false;
  }

  private isLineNearStroke(p1: Point, p2: Point, strokePoints: Point[]): boolean {
    for (const sp of strokePoints) {
      if (this.pointToSegmentDistance(sp.x, sp.y, p1.x, p1.y, p2.x, p2.y) <= this.eraserRadius) {
        return true;
      }
    }
    return false;
  }

  private isStrokeInRect(points: Point[], rx: number, ry: number, rw: number, rh: number): boolean {
    for (const point of points) {
      if (point.x >= rx && point.x <= rx + rw && point.y >= ry && point.y <= ry + rh) {
        return true;
      }
    }
    return false;
  }

  private pointToSegmentDistance(px: number, py: number, ax: number, ay: number, bx: number, by: number): number {
    const dx = bx - ax;
    const dy = by - ay;
    const lenSq = dx * dx + dy * dy;
    if (lenSq === 0) return Math.sqrt((px - ax) ** 2 + (py - ay) ** 2);
    let t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
    t = Math.max(0, Math.min(1, t));
    const projX = ax + t * dx;
    const projY = ay + t * dy;
    return Math.sqrt((px - projX) ** 2 + (py - projY) ** 2);
  }
}
