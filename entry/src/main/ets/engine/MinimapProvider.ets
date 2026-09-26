/**
 * MinimapProvider.ets — minimap 缩略图 + 锚点数据（NOTE-03，阶段2 P1 占位）
 *
 * ⚠️ 红线：阶段2 功能，本期（阶段1）【仅接口占位】，不实质实现缩略图渲染 / 浮层组件。
 *   仅提供「由节点集合计算世界包围盒 + 书签锚点列表」的纯数据桩，供阶段1 数据结构打通。
 */

import { BookmarkData, CanvasNode, Rect, StrokePayload, boundsOfPoints, nodeBounds } from './types/BoardModel';

export interface MinimapPoint {
  x: number;
  y: number;
}

export interface MinimapNorm {
  nx: number;
  ny: number;
}

export class MinimapProvider {
  /**
   * 计算全部节点的世界包围盒（供 minimap 缩放映射）。
   * 占位实现：遍历可见节点取并集；阶段2 接 OffscreenCanvas 烘焙缩略图。
   */
  static worldBounds(nodes: CanvasNode[]): Rect {
    let minX: number = Number.MAX_SAFE_INTEGER;
    let minY: number = Number.MAX_SAFE_INTEGER;
    let maxX: number = Number.MIN_SAFE_INTEGER;
    let maxY: number = Number.MIN_SAFE_INTEGER;
    let has: boolean = false;
    for (let i = 0; i < nodes.length; i++) {
      const n: CanvasNode = nodes[i];
      if (n.deleted) {
        continue;
      }
      const b: Rect = nodeBounds(n);
      has = true;
      if (b.x < minX) {
        minX = b.x;
      }
      if (b.y < minY) {
        minY = b.y;
      }
      if (b.x + b.w > maxX) {
        maxX = b.x + b.w;
      }
      if (b.y + b.h > maxY) {
        maxY = b.y + b.h;
      }
    }
    if (!has) {
      return { x: 0, y: 0, w: 1, h: 1 };
    }
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
  }

  /**
   * 世界坐标 → minimap 归一化坐标（0–1）。
   * 占位：线性映射；阶段2 浮层据此布点。
   */
  static normalize(point: MinimapPoint, world: Rect): MinimapNorm {
    const w: number = world.w > 0 ? world.w : 1;
    const h: number = world.h > 0 ? world.h : 1;
    const result: MinimapNorm = {
      nx: (point.x - world.x) / w,
      ny: (point.y - world.y) / h
    };
    return result;
  }

  /** 书签锚点列表（直接透传，供 minimap 标记） */
  static anchors(bookmarks: BookmarkData[]): BookmarkData[] {
    return bookmarks.slice();
  }

  /**
   * 计算当前视口在世界坐标系中的矩形（供 minimap 画视口框）。
   * 屏幕逻辑坐标 (vpX, vpY) 对应世界坐标 vpX/scale；视口宽高 = screenW/scale。
   */
  static viewportRect(world: Rect, vpX: number, vpY: number, scale: number, screenW: number, screenH: number): Rect {
    const s: number = scale > 0 ? scale : 1;
    const worldLeft: number = -vpX / s;
    const worldTop: number = -vpY / s;
    return {
      x: worldLeft,
      y: worldTop,
      w: screenW / s,
      h: screenH / s
    };
  }

  /** 占位：单笔迹缩略图贡献（阶段2 烘焙用） */
  static strokeContribution(node: CanvasNode): Rect {
    if (node.type === 'stroke') {
      const pl = node.payload as StrokePayload;
      if (pl.points !== undefined) {
        return boundsOfPoints(pl.points);
      }
    }
    return nodeBounds(node);
  }
}
