/**
 * ShapeTool.ets — 形状工具 v1.1 + v2.0 增量（S1T03 / NP-04）
 *
 * v2.0 增量：
 *  - ShapeData 迁移至 engine/types/CanvasElement.ets（CanvasElement 联合类型成员），
 *    字段 type → shapeType，增补 rotation/layerId/createdBy/createdAt（架构 §3.1）；
 *  - 形状元素纳入 CRDT：createShape 产出完整 ShapeData，
 *    可经 RGAEngine<CanvasElement>.localInsert(shape) 入 RGA 收敛（提交路径）；
 *  - 兼容导出：import { ShapeData } from './LayerManager' 仍可用（LayerManager 重新导出）。
 */

import { ShapeData } from './LayerManager';
import { Logger } from '../common/Logger';

const TAG_MODULE = 'ShapeTool';

export enum ShapeType {
  RECTANGLE = 'rectangle',
  CIRCLE = 'circle',
  ARROW = 'arrow',
  LINE = 'line',
}

export class ShapeTool {
  private currentType: ShapeType = ShapeType.RECTANGLE;
  private isDrawing: boolean = false;
  private startX: number = 0;
  private startY: number = 0;
  private currentColor: string = '#007DFF';
  private currentLineWidth: number = 2;
  private currentLayerId: string = 'default';
  private currentCreatedBy: string = 'local';

  setType(type: ShapeType): void { this.currentType = type; }
  setColor(color: string): void { this.currentColor = color; }
  setLineWidth(width: number): void { this.currentLineWidth = Math.max(1, width); }
  setLayerId(layerId: string): void { this.currentLayerId = layerId; }
  setCreatedBy(userId: string): void { this.currentCreatedBy = userId; }

  startDraw(x: number, y: number): void {
    this.isDrawing = true;
    this.startX = x;
    this.startY = y;
  }

  endDraw(endX: number, endY: number): ShapeData | null {
    if (!this.isDrawing) return null;
    this.isDrawing = false;

    return this.createShape(this.startX, this.startY, endX, endY);
  }

  createShape(x1: number, y1: number, x2: number, y2: number): ShapeData {
    const id: string = `shape_${Date.now()}_${Math.random().toString(36).substring(2, 8)}`;
    const x: number = Math.min(x1, x2);
    const y: number = Math.min(y1, y2);
    let w: number = Math.abs(x2 - x1);
    let h: number = Math.abs(y2 - y1);

    // 圆：宽度=高度（取较小值）
    if (this.currentType === ShapeType.CIRCLE) {
      const size: number = Math.max(w, h);
      w = size;
      h = size;
    }

    const shape: ShapeData = {
      id: id,
      layerId: this.currentLayerId,
      createdBy: this.currentCreatedBy,
      createdAt: Date.now(),
      shapeType: this.currentType,
      x: x,
      y: y,
      width: w,
      height: h,
      color: this.currentColor,
      rotation: 0,
      lineWidth: this.currentLineWidth,
    };

    Logger.info(TAG_MODULE, `Shape created: ${id}, type=${shape.shapeType}`);
    return shape;
  }

  /**
   * CRDT 提交路径（S1T03）：形状元素已是 CanvasElement 联合类型成员，
   * 直接 RGAEngine<CanvasElement>.localInsert(shape) 入 RGA 即可参与收敛。
   * 本方法提供显式语义标识。
   */
  static toCanvasElement(shape: ShapeData): ShapeData {
    return shape;
  }

  // 生成SVG路径
  static toSVG(shape: ShapeData): string {
    const x: number = shape.x;
    const y: number = shape.y;
    const w: number = shape.width;
    const h: number = shape.height;
    const color: string = shape.color;
    const lineWidth: number = shape.lineWidth > 0 ? shape.lineWidth : 2;
    switch (shape.shapeType) {
      case ShapeType.RECTANGLE:
        return `<rect x="${x}" y="${y}" width="${w}" height="${h}" stroke="${color}" fill="none" stroke-width="${lineWidth}"/>`;
      case ShapeType.CIRCLE: {
        const r: number = w / 2;
        return `<circle cx="${x + r}" cy="${y + r}" r="${r}" stroke="${color}" fill="none" stroke-width="${lineWidth}"/>`;
      }
      case ShapeType.LINE:
        return `<line x1="${x}" y1="${y}" x2="${x + w}" y2="${y + h}" stroke="${color}" stroke-width="${lineWidth}"/>`;
      case ShapeType.ARROW:
        return `<path d="M${x},${y} L${x + w},${y + h}" stroke="${color}" fill="none" stroke-width="${lineWidth}" marker-end="url(#arrowhead)"/>`;
      default:
        return '';
    }
  }
}
