/**
 * BoardModel.ets — 鸿绘协作板「合规画布数据模型」类型正本（ENG-04 / NOTE-01 / NOTE-02 / NOTE-03）
 *
 * 本文件严格对齐《画布数据模型规范》（合规版），字段定义以规范为准，**禁止重定义 / 删减**。
 * 与旧版 `.hcnote`（schema v2，points 平铺 + pressure 平行数组）不同构；本模型为合规主存储
 * 格式，落盘为 `board.json`（配合 `meta.json` + `resources/` 文件夹映射）。
 *
 * 设计要点：
 *  - 节点 JSON 强制字段：`id / type / lamport / deleted / resources / payload`；
 *  - 双链独立成表 `links[]`（软删除，无幽灵引用）；书签三类 `必背 / 易错 / 真题`；
 *  - 坐标统一为画布逻辑坐标（vp），与屏幕像素解耦，缩放/平移只改 viewport；
 *  - 笔触压感量化 0–255，二阶贝塞尔拟合后体积较原始点降低 60%+（见 engine/StrokeFitter.ets）；
 *  - 本模块不 import 任何其他业务模块，避免循环依赖（纯类型定义 + 常量）。
 *
 * ArkTS 严格模式：显式类型，无 any/unknown。
 */

// ═══════════════════════════════════════════════════════════════════
// 一、格式常量
// ═══════════════════════════════════════════════════════════════════

/** 合规 board.json schema 版本 */
export const BOARD_SCHEMA_VERSION: string = '1.0';

/** 压感量化上限（0–255） */
export const PRESSURE_MAX: number = 255;

/** 无限画布逻辑坐标半范围（vp）：±20000 */
export const CANVAS_LOGICAL_HALF_RANGE: number = 20000;

/** 缩放范围下限（ENG-01：0.1x） */
export const ZOOM_MIN: number = 0.1;

/** 缩放范围上限（ENG-01：8x） */
export const ZOOM_MAX: number = 8;

/** 节点类型白名单（数据规范§三） */
export enum NodeType {
  STROKE = 'stroke',
  TEXT = 'text',
  STICKY = 'sticky',
  IMAGE = 'image',
  SHAPE = 'shape',
  FRAME = 'frame',
  BOOKMARK = 'bookmark'
}

/** 书签三类（数据规范§五，指令集规定，不得扩展） */
export enum BookmarkType {
  MUST_RECITE = '必背',
  EASY_WRONG = '易错',
  REAL_QUESTION = '真题'
}

/** 笔触工具白名单（数据规范§三 payload.stroke） */
export enum StrokeTool {
  PEN = 'pen',
  PENCIL = 'pencil',
  MARKER = 'marker',
  ERASER = 'eraser'
}

// ═══════════════════════════════════════════════════════════════════
// 二、基础几何 / 坐标类型
// ═══════════════════════════════════════════════════════════════════

/**
 * 压感采样点（数据规范§三 payload.stroke.points）。
 * x/y 为画布逻辑坐标（vp）；p 为压感，量化到 0–255。
 */
export interface Point3 {
  x: number;
  y: number;
  /** 压感，0–255 */
  p: number;
}

/** 视口（数据规范§二 / §四 viewport）。zoom 对应既有 viewportScale。 */
export interface Viewport {
  x: number;
  y: number;
  zoom: number;
}

/**
 * 轴对齐矩形（四叉树 / 视口裁剪用）。
 * 统一以画布逻辑坐标表示；x/y 为左上角，w/h 为宽高。
 */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

// ═══════════════════════════════════════════════════════════════════
// 三、节点 payload（按 type 区分的联合类型）
// ═══════════════════════════════════════════════════════════════════

/** 笔迹 payload（二阶贝塞尔拟合后的控制点序列 + 压感 0–255） */
export interface StrokePayload {
  tool: string;          // StrokeTool 枚举值
  color: string;
  width: number;
  /** 拟合后的控制点（{x,y,p}），由 StrokeFitter 产出，体积较原始点降 60%+ */
  points: Point3[];
}

/** 文本便签 payload（数据规范§三 payload.text） */
export interface TextPayload {
  content: string;
  /** 是否为 Markdown 富文本 */
  md: boolean;
  size: number;
  color: string;
}

/** 便利贴 payload（数据规范§三 payload.sticky） */
export interface StickyPayload {
  text: string;
  color: string;
}

/** 图片节点 payload（引用 resources/，数据规范§三 payload.image） */
export interface ImagePayload {
  src: string;            // 相对路径，如 resources/img_01.png
  rotation: number;
}

/** 形状节点 payload（矩形/圆/箭头等，阶段1 占位渲染） */
export interface ShapePayload {
  shape: string;          // rect | circle | line | arrow
  color: string;
  rotation: number;
}

/** 画框 / 分页节点 payload（数据规范§三 payload.frame） */
export interface FramePayload {
  label: string;
  page: number;
}

/** 书签锚点节点 payload（数据规范§五，锚定到画布坐标） */
export interface BookmarkPayload {
  bookmarkType: string;   // BookmarkType 枚举值
  label: string;
}

/** payload 联合类型（序列化时按节点 type 解释） */
export type NodePayload =
  | StrokePayload
  | TextPayload
  | StickyPayload
  | ImagePayload
  | ShapePayload
  | FramePayload
  | BookmarkPayload;

// ═══════════════════════════════════════════════════════════════════
// 四、画布节点（强制字段：id/type/lamport/deleted/resources/payload）
// ═══════════════════════════════════════════════════════════════════

/**
 * 画布节点。
 * 强制字段（数据规范§三）：id / type / lamport / deleted / resources / payload。
 * x/y/w/h/z 为几何包围盒（供四叉树空间索引与视口裁剪），非强制但强烈建议填充。
 */
export interface CanvasNode {
  id: string;
  /** NodeType 枚举值 */
  type: string;
  /** 逻辑时钟；本地每次写操作自增 1（CRDT 全序 = (lamport, actorId)） */
  lamport: number;
  /** 软删除标记：删除只置 true，不物理删（协作可恢复、可合并） */
  deleted: boolean;
  /** 关联资源相对路径（如 resources/img_01.png）；纯笔迹/文本为空串 */
  resources: string;
  /** 包围盒左上角 X（逻辑坐标） */
  x: number;
  /** 包围盒左上角 Y（逻辑坐标） */
  y: number;
  /** 包围盒宽 */
  w: number;
  /** 包围盒高 */
  h: number;
  /** 层级（z-index） */
  z: number;
  /** 类型专属数据（见 NodePayload） */
  payload: NodePayload;
}

// ═══════════════════════════════════════════════════════════════════
// 五、双链（独立成表，软删除无幽灵引用）
// ═══════════════════════════════════════════════════════════════════

export interface LinkData {
  id: string;
  from: string;           // 源节点 id
  to: string;             // 目标节点 id
  label: string;
  lamport: number;
  deleted: boolean;
}

// ═══════════════════════════════════════════════════════════════════
// 六、书签（三类：必背 / 易错 / 真题）
// ═══════════════════════════════════════════════════════════════════

export interface BookmarkData {
  id: string;
  nodeId: string;
  /** BookmarkType 枚举值 */
  type: string;
  x: number;
  y: number;
  zoom: number;
  label: string;
}

// ═══════════════════════════════════════════════════════════════════
// 七、顶层 board.json 结构
// ═══════════════════════════════════════════════════════════════════

/**
 * board.json 顶层结构（数据规范§二）。
 * 只存结构化数据 + 资源引用路径，二进制绝不内联（保证体积小、易 diff、易 CRDT 合并）。
 */
export interface BoardData {
  schemaVersion: string;
  boardId: string;
  lamport: number;
  viewport: Viewport;
  nodes: CanvasNode[];
  links: LinkData[];
  bookmarks: BookmarkData[];
}

// ═══════════════════════════════════════════════════════════════════
// 八、辅助构造 / 守卫（纯函数，便于页面与存储层复用）
// ═══════════════════════════════════════════════════════════════════

/** 取节点包围盒（用于四叉树插入 / 视口裁剪） */
export function nodeBounds(node: CanvasNode): Rect {
  return { x: node.x, y: node.y, w: node.w, h: node.h };
}

/** 节点是否可见（未软删除） */
export function isNodeVisible(node: CanvasNode): boolean {
  return !node.deleted;
}

/** 两点矩形（用于笔迹包围盒计算） */
export function boundsOfPoints(points: Point3[]): Rect {
  if (points.length === 0) {
    return { x: 0, y: 0, w: 0, h: 0 };
  }
  let minX: number = points[0].x;
  let minY: number = points[0].y;
  let maxX: number = points[0].x;
  let maxY: number = points[0].y;
  for (let i = 1; i < points.length; i++) {
    const p: Point3 = points[i];
    if (p.x < minX) {
      minX = p.x;
    }
    if (p.y < minY) {
      minY = p.y;
    }
    if (p.x > maxX) {
      maxX = p.x;
    }
    if (p.y > maxY) {
      maxY = p.y;
    }
  }
  return { x: minX, y: minY, w: maxX - minX, h: maxY - minY };
}
