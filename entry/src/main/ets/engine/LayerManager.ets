/**
 * LayerManager.ets — 图层管理器 v1.1 + v2.0 增量（S1T01/S1T02/S1T03）
 *
 * v2.0 增量：
 *  - Layer 增补 type 扩展（'draw' | 'paper' | 'page' | 'group'）及
 *    groupId / paperTemplate / pageRef 字段（向后兼容，v1 旧字段保留）；
 *  - 新增文本/批注/图片元素容器（textBlocks/annotations/images），与 v1 strokes/shapes 并存；
 *  - 新增 createPaperLayer / createPageLayer（NP-01/NP-05）；
 *  - 新增 addElement / getElements 统一元素入口（CanvasElement 联合类型，S1T03）；
 *  - 新增 mergeLayers / duplicateLayer / groupLayers / ungroupLayer / exportLayer（NP-03）；
 *  - 图层级操作（合并/分组/重排/透明度）走 LWW-Register 语义（架构 §8.1 约定 3），
 *    不产生 RGA Insert/Delete。
 *
 * 说明：Layer 接口原定义于本文件（v1），engine/types/ 下无 Layer.ets，
 *       遵循"以现有代码实际结构为准做最小兼容扩展"，Layer 保持在本文件内。
 */

import { Logger } from '../common/Logger';
import { StrokeData } from './StrokeEngine';
import {
  ShapeData,
  TextBlockData,
  AnnotationData,
  ImageRefData,
  CanvasElement,
  CanvasElementType,
  getCanvasElementType,
} from './types/CanvasElement';
import { CanvasNode } from './types/BoardModel';

const TAG_MODULE = 'LayerManager';

// 重新导出，保持 v1 import { ShapeData } from './LayerManager' 兼容
export { ShapeData, TextBlockData, AnnotationData, ImageRefData, CanvasElement };

export interface RGAElement<T> {
  id: string;
  value: T;
  deleted: boolean;
}

/** v2.0：图层创建选项 */
export interface LayerCreateOptions {
  paperTemplate?: string;
  pageRef?: string;
  groupId?: string;
}

/** v2.0：单层导出快照（NP-03 exportLayer） */
export interface LayerExportData {
  id: string;
  name: string;
  type: string;
  opacity: number;
  visible: boolean;
  locked: boolean;
  groupId: string;
  paperTemplate: string;
  pageRef: string;
  elements: CanvasElement[];
  updatedAt: number;
  exportedAt: number;
}

export interface Layer {
  id: string;
  name: string;
  /** 'draw' | 'paper' | 'page' | 'group'（v2.0 扩展；paper/page 不参与 CRDT） */
  type: string;
  opacity: number;
  visible: boolean;
  locked: boolean;
  /** 图层顺序（z-index） */
  order: number;
  /** v2.0 增量：分组归属（group 图层 id） */
  groupId: string;
  /** v2.0 增量：纸图层模板（blank/grid/dot/lined/four_line，NP-01） */
  paperTemplate: string;
  /** v2.0 增量：文档页引用（'docId:pageIndex'，NP-06） */
  pageRef: string;
  offscreenCanvas: OffscreenCanvas | null;
  strokes: RGAElement<StrokeData>[];
  shapes: ShapeData[];
  /** v2.0 增量 */
  textBlocks: TextBlockData[];
  /** v2.0 增量 */
  annotations: AnnotationData[];
  /** v2.0 增量 */
  images: ImageRefData[];
  metadata: LayerMetadata;
}

interface LayerMetadata {
  createdAt: number;
  updatedAt: number;
  createdBy: string;
}

export class LayerManager {
  private static instance: LayerManager | null = null;
  private layers: Map<string, Layer> = new Map();
  private order: string[] = [];
  private activeLayerId: string = '';

  static getInstance(): LayerManager {
    if (!LayerManager.instance) {
      LayerManager.instance = new LayerManager();
    }
    return LayerManager.instance;
  }

  private constructor() {
    this.createLayer('默认图层', 'draw');
  }

  createLayer(name: string, type: string, options?: LayerCreateOptions): Layer {
    const id: string = `layer_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`;
    const metadata: LayerMetadata = {
      createdAt: Date.now(),
      updatedAt: Date.now(),
      createdBy: 'local'
    };
    const layer: Layer = {
      id: id, name: name, type: type,
      opacity: 1.0, visible: true, locked: false,
      order: this.layers.size,
      groupId: options !== undefined && options.groupId !== undefined ? options.groupId : '',
      paperTemplate: options !== undefined && options.paperTemplate !== undefined ? options.paperTemplate : '',
      pageRef: options !== undefined && options.pageRef !== undefined ? options.pageRef : '',
      offscreenCanvas: null,
      strokes: [], shapes: [],
      textBlocks: [], annotations: [], images: [],
      metadata: metadata
    };
    this.layers.set(id, layer);
    this.order.push(id);
    if (!this.activeLayerId) {
      this.activeLayerId = id;
    }
    Logger.info(TAG_MODULE, `Layer created: ${name}, type=${type}`);
    return layer;
  }

  /** v2.0：创建纸图层（NP-01，底纸模板不产生 CRDT 元素） */
  createPaperLayer(name: string, paperTemplate: string): Layer {
    return this.createLayer(name, 'paper', { paperTemplate: paperTemplate });
  }

  /** v2.0：创建文档页图层（NP-05/06，只读底图，pageRef='docId:pageIndex'） */
  createPageLayer(name: string, pageRef: string): Layer {
    return this.createLayer(name, 'page', { pageRef: pageRef });
  }

  getLayers(): Layer[] {
    const result: Layer[] = [];
    for (const id of this.order) {
      const layer: Layer | undefined = this.layers.get(id);
      if (layer) {
        result.push(layer);
      }
    }
    return result;
  }

  getLayer(id: string): Layer | null {
    const layer: Layer | undefined = this.layers.get(id);
    return layer !== undefined ? layer : null;
  }

  getActiveLayer(): Layer | undefined {
    return this.layers.get(this.activeLayerId);
  }

  setOpacity(id: string, opacity: number): void {
    if (isNaN(opacity) || opacity < 0 || opacity > 1) {
      Logger.warn(TAG_MODULE, `setOpacity: invalid value ${opacity}`);
      return;
    }
    const layer: Layer | undefined = this.layers.get(id);
    if (layer) {
      layer.opacity = Math.max(0, Math.min(1, opacity));
      layer.metadata.updatedAt = Date.now();
    }
  }

  setVisibility(id: string, visible: boolean): void {
    const layer: Layer | undefined = this.layers.get(id);
    if (layer) {
      layer.visible = visible;
    }
  }

  toggleVisibility(id: string): void {
    const layer: Layer | undefined = this.layers.get(id);
    if (layer) {
      layer.visible = !layer.visible;
    }
  }

  setLocked(id: string, locked: boolean): void {
    const layer: Layer | undefined = this.layers.get(id);
    if (layer) {
      layer.locked = locked;
    }
  }

  toggleLock(id: string): void {
    const layer: Layer | undefined = this.layers.get(id);
    if (layer) {
      layer.locked = !layer.locked;
    }
  }

  setActiveLayer(id: string): boolean {
    if (this.layers.has(id)) {
      this.activeLayerId = id;
      return true;
    }
    return false;
  }

  addStroke(layerId: string, stroke: RGAElement<StrokeData>): void {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      layer.strokes.push(stroke);
      layer.metadata.updatedAt = Date.now();
    }
  }

  addShape(layerId: string, shape: ShapeData): void {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      layer.shapes.push(shape);
      layer.metadata.updatedAt = Date.now();
    }
  }

  /** v2.0：添加文本框元素 */
  addTextBlock(layerId: string, block: TextBlockData): void {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      layer.textBlocks.push(block);
      layer.metadata.updatedAt = Date.now();
    }
  }

  /** v2.0：添加批注元素 */
  addAnnotation(layerId: string, annotation: AnnotationData): void {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      layer.annotations.push(annotation);
      layer.metadata.updatedAt = Date.now();
    }
  }

  /** v2.0：添加图片引用元素 */
  addImageRef(layerId: string, imageRef: ImageRefData): void {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      layer.images.push(imageRef);
      layer.metadata.updatedAt = Date.now();
    }
  }

  /**
   * v2.0：统一元素入口（CanvasElement 联合类型），按类型分派到对应容器。
   * 返回 true 表示写入成功；paper/page 只读图层拒绝写入。
   */
  addElement(layerId: string, element: CanvasElement): boolean {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (!layer) {
      Logger.warn(TAG_MODULE, `addElement: layer not found ${layerId}`);
      return false;
    }
    if (layer.type === 'paper' || layer.type === 'page') {
      Logger.warn(TAG_MODULE, `addElement: read-only layer ${layerId}`);
      return false;
    }
    const elementType: string = getCanvasElementType(element);
    if (elementType === CanvasElementType.STROKE) {
      const strokeElement: RGAElement<StrokeData> = {
        id: element.id,
        value: element as StrokeData,
        deleted: false,
      };
      layer.strokes.push(strokeElement);
    } else if (elementType === CanvasElementType.SHAPE) {
      layer.shapes.push(element as ShapeData);
    } else if (elementType === CanvasElementType.TEXT_BLOCK) {
      layer.textBlocks.push(element as TextBlockData);
    } else if (elementType === CanvasElementType.ANNOTATION) {
      // 架构 §8.1 约定 5：Annotation 必须携带 pageIndex + refDocId，否则视为无效元素拒绝入图层
      const ann: AnnotationData = element as AnnotationData;
      if (ann.pageIndex < 0 || ann.refDocId === undefined || ann.refDocId.length === 0) {
        Logger.warn(TAG_MODULE, `addElement: invalid annotation rejected (missing pageIndex/refDocId), id=${element.id}`);
        return false;
      }
      layer.annotations.push(ann);
    } else if (elementType === CanvasElementType.IMAGE_REF) {
      layer.images.push(element as ImageRefData);
    } else {
      Logger.warn(TAG_MODULE, `addElement: unsupported element type ${elementType}`);
      return false;
    }
    layer.metadata.updatedAt = Date.now();
    return true;
  }

  /** v2.0：收集图层全部可见元素（strokes + shapes + textBlocks + annotations + images） */
  getElements(layerId: string): CanvasElement[] {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (!layer) {
      return [];
    }
    const result: CanvasElement[] = [];
    for (let i = 0; i < layer.strokes.length; i++) {
      const stroke: RGAElement<StrokeData> = layer.strokes[i];
      if (!stroke.deleted) {
        result.push(stroke.value);
      }
    }
    for (let i = 0; i < layer.shapes.length; i++) {
      result.push(layer.shapes[i]);
    }
    for (let i = 0; i < layer.textBlocks.length; i++) {
      result.push(layer.textBlocks[i]);
    }
    for (let i = 0; i < layer.annotations.length; i++) {
      result.push(layer.annotations[i]);
    }
    for (let i = 0; i < layer.images.length; i++) {
      result.push(layer.images[i]);
    }
    return result;
  }

  getStrokes(layerId: string): RGAElement<StrokeData>[] {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      return layer.strokes;
    }
    return [];
  }

  getShapes(layerId: string): ShapeData[] {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      return layer.shapes;
    }
    return [];
  }

  getTextBlocks(layerId: string): TextBlockData[] {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      return layer.textBlocks;
    }
    return [];
  }

  getAnnotations(layerId: string): AnnotationData[] {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      return layer.annotations;
    }
    return [];
  }

  getImages(layerId: string): ImageRefData[] {
    const layer: Layer | undefined = this.layers.get(layerId);
    if (layer) {
      return layer.images;
    }
    return [];
  }

  moveUp(id: string): void {
    const idx: number = this.order.indexOf(id);
    if (idx < this.order.length - 1) {
      const temp: string = this.order[idx];
      this.order[idx] = this.order[idx + 1];
      this.order[idx + 1] = temp;
    }
  }

  moveDown(id: string): void {
    const idx: number = this.order.indexOf(id);
    if (idx > 0) {
      const temp: string = this.order[idx];
      this.order[idx] = this.order[idx - 1];
      this.order[idx - 1] = temp;
    }
  }

  deleteLayer(id: string): boolean {
    if (!this.layers.has(id)) {
      Logger.warn(TAG_MODULE, `deleteLayer: not found ${id}`);
      return false;
    }
    if (this.order.length <= 1) {
      Logger.warn(TAG_MODULE, 'Cannot delete the last layer');
      return false;
    }
    this.layers.delete(id);
    this.order = this.order.filter(oid => oid !== id);
    if (this.activeLayerId === id) {
      this.activeLayerId = this.order[0] || '';
    }
    return true;
  }

  renameLayer(id: string, newName: string): boolean {
    if (!newName || newName.trim().length === 0) {
      Logger.warn(TAG_MODULE, 'renameLayer: empty name');
      return false;
    }
    const layer: Layer | undefined = this.layers.get(id);
    if (!layer) {
      Logger.warn(TAG_MODULE, `renameLayer: not found ${id}`);
      return false;
    }
    layer.name = newName.trim();
    layer.metadata.updatedAt = Date.now();
    return true;
  }

  // ═══ v2.0 增量：图层增强（NP-03）═══

  /**
   * 合并图层：新建目标图层 + 迁移源图层全部元素引用（CRDT 元素引用不变，
   * 归属图层字段 LWW 更新，架构 §1.1）。合并成功后删除源图层。
   */
  mergeLayers(srcIds: string[], targetName: string): Layer | null {
    const validSrcIds: string[] = [];
    for (let i = 0; i < srcIds.length; i++) {
      if (this.layers.has(srcIds[i])) {
        validSrcIds.push(srcIds[i]);
      }
    }
    if (validSrcIds.length === 0) {
      Logger.warn(TAG_MODULE, 'mergeLayers: no valid source layers');
      return null;
    }
    const firstLayer: Layer | undefined = this.layers.get(validSrcIds[0]);
    const targetType: string = firstLayer !== undefined ? firstLayer.type : 'draw';
    const target: Layer = this.createLayer(targetName, targetType);
    for (let i = 0; i < validSrcIds.length; i++) {
      const src: Layer | undefined = this.layers.get(validSrcIds[i]);
      if (src === undefined) {
        continue;
      }
      this.migrateElements(src, target);
      this.layers.delete(src.id);
      this.order = this.order.filter(oid => oid !== src.id);
    }
    this.activeLayerId = target.id;
    Logger.info(TAG_MODULE, `mergeLayers: ${validSrcIds.length} layers -> ${target.id}`);
    return target;
  }

  /** 复制图层：生成新图层 id，元素生成新 id（作为全新 CRDT 元素），保留结构与样式 */
  duplicateLayer(id: string): Layer | null {
    const src: Layer | undefined = this.layers.get(id);
    if (!src) {
      Logger.warn(TAG_MODULE, `duplicateLayer: not found ${id}`);
      return null;
    }
    const dup: Layer = this.createLayer(`${src.name} 副本`, src.type, {
      paperTemplate: src.paperTemplate,
      pageRef: src.pageRef,
      groupId: src.groupId,
    });
    for (let i = 0; i < src.strokes.length; i++) {
      const s: RGAElement<StrokeData> = src.strokes[i];
      const newId: string = `stroke_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
      dup.strokes.push({
        id: newId,
        value: LayerManager.cloneStrokeData(s.value, newId, dup.id, Date.now()),
        deleted: false,
      });
    }
    for (let i = 0; i < src.shapes.length; i++) {
      const shape: ShapeData = src.shapes[i];
      const newId: string = `shape_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
      dup.shapes.push(LayerManager.cloneShapeData(shape, newId, dup.id, Date.now()));
    }
    for (let i = 0; i < src.textBlocks.length; i++) {
      const block: TextBlockData = src.textBlocks[i];
      const newId: string = `text_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
      dup.textBlocks.push(LayerManager.cloneTextBlockData(block, newId, dup.id, Date.now()));
    }
    for (let i = 0; i < src.annotations.length; i++) {
      const ann: AnnotationData = src.annotations[i];
      const newId: string = `ann_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
      dup.annotations.push(LayerManager.cloneAnnotationData(ann, newId, dup.id, Date.now()));
    }
    for (let i = 0; i < src.images.length; i++) {
      const img: ImageRefData = src.images[i];
      const newId: string = `image_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
      dup.images.push(LayerManager.cloneImageRefData(img, newId, dup.id, Date.now()));
    }
    Logger.info(TAG_MODULE, `duplicateLayer: ${src.id} -> ${dup.id}`);
    return dup;
  }

  /** 分组图层：创建 'group' 容器图层，成员图层 groupId 指向容器（≥2 层） */
  groupLayers(ids: string[]): Layer | null {
    const validIds: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (this.layers.has(ids[i])) {
        validIds.push(ids[i]);
      }
    }
    if (validIds.length < 2) {
      Logger.warn(TAG_MODULE, 'groupLayers: need at least 2 layers');
      return null;
    }
    const group: Layer = this.createLayer('分组', 'group');
    for (let i = 0; i < validIds.length; i++) {
      const layer: Layer | undefined = this.layers.get(validIds[i]);
      if (layer !== undefined) {
        layer.groupId = group.id;
      }
    }
    Logger.info(TAG_MODULE, `groupLayers: ${validIds.length} layers -> group ${group.id}`);
    return group;
  }

  /** 取消分组：清空成员 groupId 并删除容器图层 */
  ungroupLayer(id: string): boolean {
    const group: Layer | undefined = this.layers.get(id);
    if (!group || group.type !== 'group') {
      Logger.warn(TAG_MODULE, `ungroupLayer: not a group layer ${id}`);
      return false;
    }
    const allLayers: Layer[] = this.getLayers();
    for (let i = 0; i < allLayers.length; i++) {
      if (allLayers[i].groupId === id) {
        allLayers[i].groupId = '';
      }
    }
    this.layers.delete(id);
    this.order = this.order.filter(oid => oid !== id);
    if (this.activeLayerId === id) {
      this.activeLayerId = this.order.length > 0 ? this.order[0] : '';
    }
    Logger.info(TAG_MODULE, `ungroupLayer: ${id}`);
    return true;
  }

  /** 单层导出：返回图层快照（元素为 CanvasElement 数组，后续可由 io/HCNoteWriter 序列化） */
  exportLayer(id: string): LayerExportData | null {
    const layer: Layer | undefined = this.layers.get(id);
    if (!layer) {
      Logger.warn(TAG_MODULE, `exportLayer: not found ${id}`);
      return null;
    }
    const data: LayerExportData = {
      id: layer.id,
      name: layer.name,
      type: layer.type,
      opacity: layer.opacity,
      visible: layer.visible,
      locked: layer.locked,
      groupId: layer.groupId,
      paperTemplate: layer.paperTemplate,
      pageRef: layer.pageRef,
      elements: this.getElements(layer.id),
      updatedAt: layer.metadata.updatedAt,
      exportedAt: Date.now(),
    };
    return data;
  }

  /** 获取指定分组下的图层 id 列表 */
  getGroupedLayerIds(groupId: string): string[] {
    const result: string[] = [];
    const allLayers: Layer[] = this.getLayers();
    for (let i = 0; i < allLayers.length; i++) {
      if (allLayers[i].groupId === groupId) {
        result.push(allLayers[i].id);
      }
    }
    return result;
  }

  private migrateElements(src: Layer, target: Layer): void {
    for (let i = 0; i < src.strokes.length; i++) {
      const s: RGAElement<StrokeData> = src.strokes[i];
      target.strokes.push({
        id: s.id,
        value: LayerManager.cloneStrokeData(s.value, s.value.id, target.id, s.value.createdAt),
        deleted: s.deleted,
      });
    }
    for (let i = 0; i < src.shapes.length; i++) {
      const shape: ShapeData = src.shapes[i];
      target.shapes.push(LayerManager.cloneShapeData(shape, shape.id, target.id, shape.createdAt));
    }
    for (let i = 0; i < src.textBlocks.length; i++) {
      const block: TextBlockData = src.textBlocks[i];
      target.textBlocks.push(LayerManager.cloneTextBlockData(block, block.id, target.id, block.createdAt));
    }
    for (let i = 0; i < src.annotations.length; i++) {
      const ann: AnnotationData = src.annotations[i];
      target.annotations.push(LayerManager.cloneAnnotationData(ann, ann.id, target.id, ann.createdAt));
    }
    for (let i = 0; i < src.images.length; i++) {
      const img: ImageRefData = src.images[i];
      target.images.push(LayerManager.cloneImageRefData(img, img.id, target.id, img.createdAt));
    }
  }

  // ═══ v2.0：元素克隆助手（ArkTS 禁止对象展开 arkts-no-spread，逐字段复制）═══

  private static cloneStrokeData(src: StrokeData, newId: string, layerId: string, createdAt: number): StrokeData {
    return {
      id: newId,
      layerId: layerId,
      tool: src.tool,
      color: src.color,
      width: src.width,
      points: src.points.slice(),
      createdAt: createdAt,
      createdBy: src.createdBy,
      brushShape: src.brushShape,
      pressureCurve: src.pressureCurve !== undefined ? src.pressureCurve.slice() : undefined,
      opacity: src.opacity,
      blendMode: src.blendMode,
      texture: src.texture,
    };
  }

  private static cloneShapeData(src: ShapeData, newId: string, layerId: string, createdAt: number): ShapeData {
    return {
      id: newId,
      layerId: layerId,
      createdBy: src.createdBy,
      createdAt: createdAt,
      shapeType: src.shapeType,
      x: src.x,
      y: src.y,
      width: src.width,
      height: src.height,
      color: src.color,
      rotation: src.rotation,
      lineWidth: src.lineWidth,
    };
  }

  private static cloneTextBlockData(src: TextBlockData, newId: string, layerId: string, createdAt: number): TextBlockData {
    return {
      id: newId,
      layerId: layerId,
      createdBy: src.createdBy,
      createdAt: createdAt,
      text: src.text,
      x: src.x,
      y: src.y,
      fontSize: src.fontSize,
      fontFamily: src.fontFamily,
      align: src.align,
      color: src.color,
    };
  }

  private static cloneAnnotationData(src: AnnotationData, newId: string, layerId: string, createdAt: number): AnnotationData {
    return {
      id: newId,
      layerId: layerId,
      createdBy: src.createdBy,
      createdAt: createdAt,
      annotationType: src.annotationType,
      pageIndex: src.pageIndex,
      refDocId: src.refDocId,
      refElementId: src.refElementId,
      color: src.color,
      points: src.points.slice(),
      width: src.width,
    };
  }

  private static cloneImageRefData(src: ImageRefData, newId: string, layerId: string, createdAt: number): ImageRefData {
    return {
      id: newId,
      layerId: layerId,
      createdBy: src.createdBy,
      createdAt: createdAt,
      imageHash: src.imageHash,
      mimeType: src.mimeType,
      x: src.x,
      y: src.y,
      width: src.width,
      height: src.height,
      binaryRef: src.binaryRef,
      uri: src.uri,
      rotation: src.rotation,
      scale: src.scale,
    };
  }

  getLayerCount(): number {
    return this.order.length;
  }

  /**
   * ENG-03：把静态节点光栅化到离屏静态层（OffscreenCanvas）。
   * 当前实现：在活动绘制层的 offscreenCanvas 上绘制各节点包围盒（占位级静态层），
   * 动态元素（光标/选中框/连线）不在此层。阶段1 真实笔迹由 CanvasEngine 主上下文绘制，
   * 本方法为「脏时重绘静态层」的钩子，保证离屏静态层链路接通、可被万级节点视口裁剪复用。
   */
  rasterizeStatic(nodes: CanvasNode[]): void {
    const active: Layer | undefined = this.getActiveLayer();
    if (active === undefined) {
      return;
    }
    if (active.offscreenCanvas === null) {
      try {
        active.offscreenCanvas = new OffscreenCanvas(1080, 1920);
      } catch (e) {
        Logger.warn(TAG_MODULE, 'rasterizeStatic: OffscreenCanvas 创建失败，跳过离屏静态层');
        return;
      }
    }
    const ctx: OffscreenCanvasRenderingContext2D | null = active.offscreenCanvas.getContext('2d') as OffscreenCanvasRenderingContext2D | null;
    if (ctx === null) {
      return;
    }
    ctx.clearRect(0, 0, active.offscreenCanvas.width, active.offscreenCanvas.height);
    for (let i = 0; i < nodes.length; i++) {
      const n: CanvasNode = nodes[i];
      if (n.deleted || n.w <= 0 || n.h <= 0) {
        continue;
      }
      ctx.save();
      ctx.strokeStyle = '#CCCCCC';
      ctx.lineWidth = 1;
      ctx.strokeRect(n.x, n.y, n.w, n.h);
      ctx.restore();
    }
  }

  reset(): void {
    this.layers.clear();
    this.order = [];
    this.activeLayerId = '';
    this.createLayer('默认图层', 'draw');
  }
}
