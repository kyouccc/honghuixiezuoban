/**
 * CRDT 操作类型定义 v1.1 + v2.0 增量
 * 修复：VectorClock 扁平化为 Record<string,number>（与 RGAEngine 一致）；
 *       InsertOp/DeleteOp 增加 vectorClock 字段；
 *       RGAElement 支持泛型；
 *       deserializeNodeID 增加输入验证
 *
 * v2.0 增量（S1T01/S1T02 + S2T03）：
 *  - InsertOp 增补 elementType 字段（元素类型：stroke/shape/text_block/annotation/image_ref/mind_map）；
 *  - 元素数据结构（ShapeData/TextBlockData/AnnotationData/ImageRefData/CanvasElement 联合类型）
 *    统一收敛到 engine/types/CanvasElement.ets，本文件重新导出，保证 wire 模型单一事实源
 *    （架构 §3.1 / §8.1 约定 2）；
 *  - InsertOp/CRDTOp 泛型化（默认 CanvasElement）：RGAEngine<CanvasElement> 协同全类型元素，
 *    避免远程操作反序列化后 element.value 退化为 string 的类型丢失（S2T03）。
 */
import {
  Point,
  StrokeData,
  ShapeData,
  TextBlockData,
  AnnotationData,
  ImageRefData,
  CanvasElement,
  CanvasElementType,
  getCanvasElementType,
  getCanvasElementTypeLabel,
} from '../../engine/types/CanvasElement';

export {
  Point,
  StrokeData,
  ShapeData,
  TextBlockData,
  AnnotationData,
  ImageRefData,
  CanvasElement,
  CanvasElementType,
  getCanvasElementType,
  getCanvasElementTypeLabel,
};

export interface NodeID {
  lamportTs: number;
  siteId: string;
}

/** 扁平化向量时钟（siteId → 逻辑时钟值） */
export type VectorClock = Record<string, number>;

export interface RGAElement<T = string> {
  id: NodeID;
  value: T;
  deleted: boolean;
  afterId: NodeID | null;
}

export interface InsertOp<T = CanvasElement> {
  type: string;
  element: RGAElement<T>;
  afterId: NodeID | null;
  vectorClock: VectorClock;
  timestamp: number;
  /** v2.0 增量：CRDT 元素类型（stroke/shape/text_block/annotation/image_ref/mind_map） */
  elementType?: string;
}

export interface DeleteOp {
  type: string;
  targetId: NodeID;
  vectorClock: VectorClock;
  timestamp: number;
  /** v2.0 修复（E-3）：删除操作同样携带元素类型，服务端按真实类型校验权限（Annotator 可删自己的批注） */
  elementType?: string;
}

/**
 * T2-5（S2-Cb）：元素级字段更新（LWW-Register 写入）。
 * 字段值一律字符串化（JSON 序列化后写入），与 layerLWW 的 value 语义一致。
 * siteId 为产生者标识：LWW 决胜键 = (lamportTs=vectorClock[siteId], siteId) 字典序（非墙钟，t25 §1.4）。
 */
export interface UpdateOp {
  type: string;
  targetId: NodeID;
  /** 可变字段名（Image：x/y/width/height/rotation/scale；Text：text/x/y/fontSize/fontFamily/align/color；Annotation：color/width） */
  field: string;
  /** 字段新值（字符串化；数字/布尔用 JSON.stringify 编码） */
  value: string;
  vectorClock: VectorClock;
  timestamp: number;
  elementType?: string;
  /** 产生者 siteId（LWW 决胜身份，与 NodeID.siteId 对齐） */
  siteId: string;
}

/** T2-5（S2-Cb）：撤销删除 = 清墓碑（ResurrectOp），不重新插入、不丢 NodeID/afterId/顺序位 */
export interface ResurrectOp {
  type: string;
  targetId: NodeID;
  vectorClock: VectorClock;
  timestamp: number;
  elementType?: string;
}

export type CRDTOp<T = CanvasElement> = InsertOp<T> | DeleteOp | ResurrectOp | UpdateOp;

export function compareNodeIds(a: NodeID, b: NodeID): number {
  if (a.lamportTs !== b.lamportTs) {
    return a.lamportTs - b.lamportTs;
  }
  if (a.siteId < b.siteId) {
    return -1;
  }
  if (a.siteId > b.siteId) {
    return 1;
  }
  return 0;
}

export function serializeNodeID(id: NodeID): string {
  return `${id.lamportTs}:${id.siteId}`;
}

export function deserializeNodeID(str: string): NodeID | null {
  if (!str || str.indexOf(':') === -1) return null;
  const parts: string[] = str.split(':');
  const lamportTs: number = parseInt(parts[0]);
  if (isNaN(lamportTs)) return null;
  const siteId: string = parts.slice(1).join(':');
  if (siteId.length === 0) return null;
  return { lamportTs: lamportTs, siteId: siteId };
}

/** 从 CRDT 操作中解析元素类型（未标注时回退为 stroke） */
export function getElementTypeOfOp(op: CRDTOp): string {
  const insertOp: InsertOp = op as InsertOp;
  if (insertOp.elementType !== undefined && insertOp.elementType.length > 0) {
    return insertOp.elementType;
  }
  return 'stroke';
}
