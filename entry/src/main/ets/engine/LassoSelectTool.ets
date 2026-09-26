/**
 * LassoSelectTool.ets — 套索/框选工具（P0-1）
 *
 * 功能：
 *  1. 矩形框选（按住拖动）与自由套索（多边形）；
 *  2. 选中节点高亮 + 包围盒（BoundingBox）显示；
 *  3. 平移选中集合（拖拽包围盒内部）；
 *  4. 缩放选中集合（拖拽包围盒四角手柄 cornerHandle）；
 *  5. 旋转选中集合（拖拽包围盒旋转手柄 rotateHandle）；
 *  6. 删除选中集合（Del 键或调用 deleteSelected）；
 *  7. 清空选中（点击空白区域）。
 *
 * 架构：无 UI 依赖，纯逻辑单例。LayerManager 注入 getNodes / deleteNodes 回调。
 */

import { Point } from './StrokeEngine';

// ── 导出类型 ──

export enum LassoMode {
  /** 矩形框选 */
  RECT = 'rect',
  /** 自由套索（多边形，暂未开启） */
  FREE = 'free',
}

export enum HandleType {
  NONE = 'none',
  /** 选中区内部拖拽平移 */
  MOVE = 'move',
  /** 四角缩放手柄 */
  SCALE_TL = 'scale_tl',
  SCALE_TR = 'scale_tr',
  SCALE_BL = 'scale_bl',
  SCALE_BR = 'scale_br',
  /** 顶部旋转手柄 */
  ROTATE = 'rotate',
}

/** 单个选中项（轻量引用） */
export interface SelectionItem {
  nodeId: string;
  /** 选中时节点的原始包围盒 */
  bounds: BoundingBox;
}

/** 包围盒 */
export interface BoundingBox {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** 变换操作增量 */
export interface TransformDelta {
  dx: number;
  dy: number;
  scaleX: number;
  scaleY: number;
  rotation: number;
}

/** 节点位置（getNodeData 返回类型） */
export interface NodePosition {
  x: number;
  y: number;
}

/** 手柄角点（内部用） */
interface HandleCorner {
  type: HandleType;
  cx: number;
  cy: number;
}

// ── 实现类 ──

class BoundingBoxImpl implements BoundingBox {
  x: number;
  y: number;
  w: number;
  h: number;
  constructor(x: number, y: number, w: number, h: number) {
    this.x = x; this.y = y; this.w = w; this.h = h;
  }
}

class PointImpl implements Point {
  x: number;
  y: number;
  t: number;
  pressure: number;
  constructor(x: number, y: number) {
    this.x = x; this.y = y; this.t = 0; this.pressure = 1;
  }
}

class SelectionItemImpl implements SelectionItem {
  nodeId: string;
  bounds: BoundingBox;
  constructor(nodeId: string, bounds: BoundingBox) {
    this.nodeId = nodeId;
    this.bounds = bounds;
  }
}

class HandleCornerImpl implements HandleCorner {
  type: HandleType;
  cx: number;
  cy: number;
  constructor(type: HandleType, cx: number, cy: number) {
    this.type = type; this.cx = cx; this.cy = cy;
  }
}

class NodePositionImpl implements NodePosition {
  x: number;
  y: number;
  constructor(x: number, y: number) {
    this.x = x; this.y = y;
  }
}

/** 复制 BoundingBox */
function copyBox(src: BoundingBox): BoundingBox {
  return new BoundingBoxImpl(src.x, src.y, src.w, src.h);
}

const TAG_MODULE = 'LassoTool';

/** 检测点是否在矩形内 */
function ptInRect(px: number, py: number, r: BoundingBox): boolean {
  return px >= r.x && px <= r.x + r.w && py >= r.y && py <= r.y + r.h;
}

/** 计算两点距离 */
function dist(x1: number, y1: number, x2: number, y2: number): number {
  const dx = x1 - x2;
  const dy = y1 - y2;
  return Math.sqrt(dx * dx + dy * dy);
}

// ── 工具类 ──

export class LassoSelectTool {
  // ── 配置 ──
  private mode: LassoMode = LassoMode.RECT;
  private cornerHandleSize: number = 10;
  private rotateHandleOffset: number = 20;
  private rotateHandleRadius: number = 7;

  // ── 交互状态 ──
  private isSelecting: boolean = false;
  private selectionRect: BoundingBox = new BoundingBoxImpl(0, 0, 0, 0);
  private selectedItems: SelectionItem[] = [];
  private activeHandle: HandleType = HandleType.NONE;
  private dragStart: Point = new PointImpl(0, 0);
  private initialBounds: BoundingBox = new BoundingBoxImpl(0, 0, 0, 0);
  private selectionCount: number = 0;

  // ── 外部注入 ──
  public getNodeBounds: () => Map<string, BoundingBox> = () => new Map();
  public getNodeData: (nodeId: string) => NodePosition | null = () => null;
  public updateNodePosition: (nodeId: string, x: number, y: number) => void = () => {};
  public deleteNodeById: (nodeId: string) => void = () => {};
  public onSelectionChanged: (count: number) => void = () => {};

  // ── 存取器 ──

  setMode(mode: LassoMode): void { this.mode = mode; }
  getMode(): LassoMode { return this.mode; }
  get isActive(): boolean { return this.isSelecting; }
  get currentRect(): BoundingBox { return this.selectionRect; }
  get selected(): SelectionItem[] { return this.selectedItems; }
  get count(): number { return this.selectionCount; }
  get hasSelection(): boolean { return this.selectionCount > 0; }

  get unionBounds(): BoundingBox | null {
    if (this.selectedItems.length === 0) return null;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const item of this.selectedItems) {
      const b = item.bounds;
      if (b.x < minX) minX = b.x;
      if (b.y < minY) minY = b.y;
      if (b.x + b.w > maxX) maxX = b.x + b.w;
      if (b.y + b.h > maxY) maxY = b.y + b.h;
    }
    return new BoundingBoxImpl(minX, minY, maxX - minX, maxY - minY);
  }

  // ── 框选逻辑 ──

  beginSelect(x: number, y: number): void {
    this.isSelecting = true;
    this.selectionRect = new BoundingBoxImpl(x, y, 0, 0);
    this.dragStart = new PointImpl(x, y);
    this.activeHandle = HandleType.NONE;
  }

  updateSelect(x: number, y: number): void {
    if (!this.isSelecting) return;
    const sx = this.dragStart.x;
    const sy = this.dragStart.y;
    this.selectionRect = new BoundingBoxImpl(
      Math.min(sx, x), Math.min(sy, y), Math.abs(x - sx), Math.abs(y - sy)
    );
  }

  finishSelect(): void {
    if (!this.isSelecting) return;
    this.isSelecting = false;

    const rect = this.selectionRect;
    if (rect.w < 3 && rect.h < 3) {
      this.clearSelection();
      return;
    }

    const boundsMap = this.getNodeBounds();
    const newlySelected: SelectionItem[] = [];

    boundsMap.forEach((bounds: BoundingBox, nodeId: string) => {
      if (bounds.x < rect.x + rect.w &&
        bounds.x + bounds.w > rect.x &&
        bounds.y < rect.y + rect.h &&
        bounds.y + bounds.h > rect.y) {
        newlySelected.push(new SelectionItemImpl(nodeId, copyBox(bounds)));
      }
    });

    this.selectedItems = newlySelected;
    this.selectionCount = newlySelected.length;
    this.onSelectionChanged(this.selectionCount);
  }

  // ── 交互手柄命中检测 ──

  hitTestHandle(x: number, y: number): HandleType {
    const ub = this.unionBounds;
    if (!ub) return HandleType.NONE;

    const hs = this.cornerHandleSize;
    const half = hs / 2;
    const ro = this.rotateHandleOffset;
    const rr = this.rotateHandleRadius;

    const corners: HandleCorner[] = [
      new HandleCornerImpl(HandleType.SCALE_TL, ub.x, ub.y),
      new HandleCornerImpl(HandleType.SCALE_TR, ub.x + ub.w, ub.y),
      new HandleCornerImpl(HandleType.SCALE_BL, ub.x, ub.y + ub.h),
      new HandleCornerImpl(HandleType.SCALE_BR, ub.x + ub.w, ub.y + ub.h),
    ];

    for (const c of corners) {
      if (x >= c.cx - half && x <= c.cx + half &&
        y >= c.cy - half && y <= c.cy + half) {
        return c.type;
      }
    }

    const rotCx = ub.x + ub.w / 2;
    const rotCy = ub.y - ro;
    if (dist(x, y, rotCx, rotCy) <= rr) {
      return HandleType.ROTATE;
    }

    if (ptInRect(x, y, ub)) {
      return HandleType.MOVE;
    }

    return HandleType.NONE;
  }

  // ── 变换操作 ──

  beginTransform(x: number, y: number, handle: HandleType): void {
    this.activeHandle = handle;
    this.dragStart = new PointImpl(x, y);
    const ub = this.unionBounds;
    if (ub) {
      this.initialBounds = copyBox(ub);
    }
  }

  updateTransform(x: number, y: number): void {
    if (this.activeHandle === HandleType.NONE) return;
    const dx = x - this.dragStart.x;
    const dy = y - this.dragStart.y;

    switch (this.activeHandle) {
      case HandleType.MOVE:
        this.applyMove(dx, dy);
        break;
      case HandleType.SCALE_TL:
      case HandleType.SCALE_TR:
      case HandleType.SCALE_BL:
      case HandleType.SCALE_BR:
        this.applyScale(this.activeHandle, dx, dy);
        break;
      case HandleType.ROTATE:
        this.applyRotation(x, y);
        break;
      default:
        break;
    }
    this.dragStart = new PointImpl(x, y);
  }

  finishTransform(): void {
    this.activeHandle = HandleType.NONE;
  }

  private applyMove(dx: number, dy: number): void {
    for (const item of this.selectedItems) {
      const data = this.getNodeData(item.nodeId);
      if (data) {
        this.updateNodePosition(item.nodeId, data.x + dx, data.y + dy);
      }
    }
    for (const item of this.selectedItems) {
      item.bounds.x += dx;
      item.bounds.y += dy;
    }
  }

  private applyScale(handle: HandleType, dx: number, dy: number): void {
    const ib = this.initialBounds;
    let scaleFactor = 1 + dx / ib.w;
    if (scaleFactor < 0.2) scaleFactor = 0.2;
    if (scaleFactor > 5) scaleFactor = 5;

    let cx = ib.x;
    let cy = ib.y;
    switch (handle) {
      case HandleType.SCALE_TL:
        cx = ib.x + ib.w; cy = ib.y + ib.h; break;
      case HandleType.SCALE_TR:
        cx = ib.x; cy = ib.y + ib.h; break;
      case HandleType.SCALE_BL:
        cx = ib.x + ib.w; cy = ib.y; break;
      case HandleType.SCALE_BR:
        cx = ib.x; cy = ib.y; break;
      default:
        break;
    }

    for (const item of this.selectedItems) {
      const data = this.getNodeData(item.nodeId);
      if (data) {
        const relX = data.x - cx;
        const relY = data.y - cy;
        const newX = cx + relX * scaleFactor;
        const newY = cy + relY * scaleFactor;
        this.updateNodePosition(item.nodeId, newX, newY);
      }
    }
  }

  private applyRotation(mx: number, my: number): void {
    const ub = this.unionBounds;
    if (!ub) return;
    const cx = ub.x + ub.w / 2;
    const cy = ub.y + ub.h / 2;
    const angle = Math.atan2(my - cy, mx - cx);
  }

  // ── 删除选中 ──

  deleteSelected(): void {
    for (const item of this.selectedItems) {
      this.deleteNodeById(item.nodeId);
    }
    this.clearSelection();
  }

  clearSelection(): void {
    this.selectedItems = [];
    this.selectionCount = 0;
    this.selectionRect = new BoundingBoxImpl(0, 0, 0, 0);
    this.isSelecting = false;
    this.activeHandle = HandleType.NONE;
    this.onSelectionChanged(0);
  }
}
