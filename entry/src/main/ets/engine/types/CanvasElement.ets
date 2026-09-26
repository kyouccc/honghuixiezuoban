/**
 * CanvasElement.ets — CRDT 画布元素联合类型（v2.0 增量，S1T01）
 *
 * 说明：
 *  - RGA 元素泛型从 v1 的 StrokeData 扩展为 CanvasElement 联合类型（架构 §1.1 / §3.1）；
 *  - v1 StrokeData 保持原结构（向后兼容），新增 Shape/TextBlock/Annotation/ImageRef 四类元素；
 *  - 纸图层（paper/page）不产生 CRDT 元素，因此不在联合类型中（架构 §8.1 约定 4）；
 *  - Annotation 必须携带 pageIndex + refDocId，否则视为无效元素拒绝入 RGA（架构 §8.1 约定 5）。
 */

import { Point, StrokeData } from '../StrokeEngine';

// 重新导出，供 crdt/types/CRDTOp.ets 与上层统一引用
export { Point, StrokeData };

/** 元素类型字符串常量（与 proto CanvasElement.element_type 对齐，两端一致，架构 §8.1 约定 2） */
export enum CanvasElementType {
  STROKE = 'stroke',
  SHAPE = 'shape',
  TEXT_BLOCK = 'text_block',
  ANNOTATION = 'annotation',
  IMAGE_REF = 'image_ref',
  MIND_MAP = 'mind_map',
}

/** 元素公共基础字段（所有 CRDT 元素共享） */
export interface CanvasElementBase {
  id: string;
  layerId: string;
  createdBy: string;
  createdAt: number;
}

/** 形状元素（NP-04，基于 v1 BE-07 扩展；shapeType 对齐架构 §3.1 类图） */
export interface ShapeData extends CanvasElementBase {
  shapeType: string;   // rectangle | circle | arrow | line
  x: number;
  y: number;
  width: number;
  height: number;
  color: string;
  rotation: number;
  lineWidth: number;
}

/** 文本框元素（NP-04，TextBlockTool 创建，支持实时编辑） */
export interface TextBlockData extends CanvasElementBase {
  text: string;
  x: number;
  y: number;
  fontSize: number;
  fontFamily: string;
  align: string;   // left | center | right
  color: string;
}

/** 文档批注元素（NP-06，必须携带 pageIndex + refDocId） */
export interface AnnotationData extends CanvasElementBase {
  annotationType: string;  // highlight | underline | margin | freehand
  pageIndex: number;
  refDocId: string;
  refElementId: string;
  color: string;
  points: Point[];
  width: number;
}

/** 图片引用元素（NP-04；二进制走旁路通道，CRDT 仅含 imageHash 引用，架构 §8.1 约定 6） */
export interface ImageRefData extends CanvasElementBase {
  imageHash: string;
  mimeType: string;
  x: number;
  y: number;
  width: number;
  height: number;
  binaryRef: string;   // 旁路二进制通道引用（阶段二），P0 为空串
  uri: string;         // v1 兼容：本地文件 uri 引用
  rotation: number;    // v1 兼容
  scale: number;       // v1 兼容
}

/** CRDT 元素联合类型 */
export type CanvasElement = StrokeData | ShapeData | TextBlockData | AnnotationData | ImageRefData;

/**
 * 按结构判别元素类型（ArkTS 严格模式：不使用 any/unknown、不使用动态索引）。
 * 判别顺序：stroke(tool+points) → shape(shapeType) → text_block(text) → annotation(pageIndex) → image_ref(imageHash)。
 */
export function getCanvasElementType(element: CanvasElement): string {
  const stroke: StrokeData = element as StrokeData;
  if (stroke.tool !== undefined && stroke.points !== undefined) {
    return CanvasElementType.STROKE;
  }
  const shape: ShapeData = element as ShapeData;
  if (shape.shapeType !== undefined) {
    return CanvasElementType.SHAPE;
  }
  const text: TextBlockData = element as TextBlockData;
  if (text.text !== undefined) {
    return CanvasElementType.TEXT_BLOCK;
  }
  const ann: AnnotationData = element as AnnotationData;
  if (ann.pageIndex !== undefined) {
    return CanvasElementType.ANNOTATION;
  }
  const img: ImageRefData = element as ImageRefData;
  if (img.imageHash !== undefined) {
    return CanvasElementType.IMAGE_REF;
  }
  return CanvasElementType.STROKE;
}

/** 元素类型中文名（UI 展示用） */
export function getCanvasElementTypeLabel(elementType: string): string {
  if (elementType === CanvasElementType.STROKE) {
    return '笔迹';
  }
  if (elementType === CanvasElementType.SHAPE) {
    return '形状';
  }
  if (elementType === CanvasElementType.TEXT_BLOCK) {
    return '文本框';
  }
  if (elementType === CanvasElementType.ANNOTATION) {
    return '批注';
  }
  if (elementType === CanvasElementType.IMAGE_REF) {
    return '图片';
  }
  if (elementType === CanvasElementType.MIND_MAP) {
    return '思维导图';
  }
  return '未知';
}
