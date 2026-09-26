/**
 * UndoRedoManager.ets — 撤销/重做管理器（v2.5 阶段二）
 *
 * 职责：
 *  1. 管理画布操作的撤销/重做栈；
 *  2. 支持多种操作类型：笔画、形状、图片、图层、橡皮擦除等；
 *  3. 提供撤销/重做能力，支持操作合并（连续笔画合并为一个操作）。
 *
 * 设计原则：
 *  - 每个操作记录包含操作类型、操作数据、反向操作数据；
 *  - 撤销时执行反向操作，重做时执行正向操作；
 *  - 支持操作合并，减少撤销栈深度。
 */

import { Logger } from '../common/Logger';
import { CanvasNode } from './types/BoardModel';

const TAG_MODULE = 'UndoRedoManager';

/** 操作类型枚举 */
export enum ActionType {
  STROKE_ADD = 'stroke_add',           // 添加笔画
  STROKE_DELETE = 'stroke_delete',     // 删除笔画
  SHAPE_ADD = 'shape_add',             // 添加形状
  SHAPE_DELETE = 'shape_delete',       // 删除形状
  SHAPE_MODIFY = 'shape_modify',       // 修改形状
  IMAGE_ADD = 'image_add',             // 添加图片
  IMAGE_DELETE = 'image_delete',       // 删除图片
  IMAGE_TRANSFORM = 'image_transform', // 图片变换
  LAYER_ADD = 'layer_add',             // 添加图层
  LAYER_DELETE = 'layer_delete',       // 删除图层
  LAYER_REORDER = 'layer_reorder',     // 图层重排序
  ERASE = 'erase',                     // 橡皮擦除
  CLEAR = 'clear',                     // 清空画布
  COMPOSITE = 'composite'              // 复合操作（多个操作组合）
}

/** 笔画数据 */
export interface StrokeData {
  strokeId: string;
  points: number[];      // [x1, y1, x2, y2, ...]
  color: string;
  width: number;
  opacity: number;
  blendMode: string;
  brushShape: string;
  layerId: string;
  createdAt: number;
}

/** 形状数据 */
export interface ShapeData {
  shapeId: string;
  shapeType: 'rect' | 'circle' | 'line' | 'arrow' | 'triangle';
  bounds: number[];      // [x, y, width, height]
  color: string;
  strokeWidth: number;
  fill: boolean;
  fillColor?: string;
  opacity: number;
  layerId: string;
}

/** 图片数据 */
export interface ImageData {
  imageId: string;
  source: string;        // 图片路径或dataURL
  bounds: number[];      // [x, y, width, height]
  rotation: number;
  opacity: number;
  layerId: string;
}

/** 图层数据 */
export interface LayerData {
  layerId: string;
  name: string;
  visible: boolean;
  locked: boolean;
  opacity: number;
  blendMode: string;
  order: number;
}

/** 擦除数据 */
export interface EraseData {
  erasedStrokeIds: string[];
  erasedShapeIds: string[];
  erasedImageIds: string[];
  originalStrokes: StrokeData[];
  originalShapes: ShapeData[];
  originalImages: ImageData[];
}

/** 操作数据联合类型 */
export type ActionData =
  | StrokeData
  | StrokeData[]         // 批量笔画
  | ShapeData
  | ShapeData[]          // 批量形状
  | ImageData
  | ImageData[]          // 批量图片
  | LayerData
  | EraseData
  | null;                // 清空操作

/** 画布操作记录 */
export interface CanvasAction {
  type: ActionType;
  data: ActionData;          // 正向操作数据
  reverseData: ActionData;   // 反向操作数据（用于撤销）
  timestamp: number;
  description: string;       // 操作描述（用于UI显示）
  canMerge?: boolean;        // 是否可合并（连续笔画可合并）
  mergedActions?: CanvasAction[]; // 合并的操作列表
}

/** 操作执行器接口 */
export interface ActionExecutor {
  execute(action: CanvasAction): void;
  reverse(action: CanvasAction): void;
}

/** 撤销/重做管理器配置 */
export interface UndoRedoConfig {
  maxStackSize: number;      // 最大栈深度（默认50）
  enableMerge: boolean;      // 是否启用操作合并（默认true）
  mergeTimeWindow: number;   // 合并时间窗口（毫秒，默认500）
}

const DEFAULT_CONFIG: UndoRedoConfig = {
  maxStackSize: 50,
  enableMerge: true,
  mergeTimeWindow: 500
};

/**
 * 撤销/重做管理器
 */
export class UndoRedoManager {
  private static instance: UndoRedoManager | null = null;
  
  private undoStack: CanvasAction[] = [];
  private redoStack: CanvasAction[] = [];
  private config: UndoRedoConfig;
  private executor: ActionExecutor | null = null;
  private lastActionTime: number = 0;
  
  private constructor(config: Partial<UndoRedoConfig> = {}) {
    this.config = {
      maxStackSize: config.maxStackSize ?? DEFAULT_CONFIG.maxStackSize,
      enableMerge: config.enableMerge ?? DEFAULT_CONFIG.enableMerge,
      mergeTimeWindow: config.mergeTimeWindow ?? DEFAULT_CONFIG.mergeTimeWindow
    };
  }
  
  /** 获取单例实例 */
  static getInstance(config?: Partial<UndoRedoConfig>): UndoRedoManager {
    if (!UndoRedoManager.instance) {
      UndoRedoManager.instance = new UndoRedoManager(config);
    }
    return UndoRedoManager.instance;
  }
  
  /** 设置操作执行器 */
  setExecutor(executor: ActionExecutor): void {
    this.executor = executor;
  }
  
  /** 记录操作（推入撤销栈） */
  pushAction(action: CanvasAction): void {
    // 检查是否可合并到上一个操作
    if (this.config.enableMerge && this.canMergeWithLast(action)) {
      this.mergeWithLast(action);
      return;
    }
    
    // 推入撤销栈
    this.undoStack.push(action);
    this.lastActionTime = action.timestamp;
    
    // 清空重做栈（新操作使重做栈失效）
    this.redoStack = [];
    
    // 限制栈深度
    if (this.undoStack.length > this.config.maxStackSize) {
      this.undoStack.shift();
    }
    
    Logger.debug(TAG_MODULE, `pushAction: ${action.type}, undoStack=${this.undoStack.length}, redoStack=${this.redoStack.length}`);
  }
  
  /** 撤销操作 */
  undo(): CanvasAction | null {
    if (this.undoStack.length === 0) {
      Logger.warn(TAG_MODULE, 'undo: 撤销栈为空');
      return null;
    }
    
    const action = this.undoStack.pop()!;
    
    // 执行反向操作
    if (this.executor) {
      this.executor.reverse(action);
    }
    
    // 推入重做栈
    this.redoStack.push(action);
    
    Logger.debug(TAG_MODULE, `undo: ${action.type}, undoStack=${this.undoStack.length}, redoStack=${this.redoStack.length}`);
    return action;
  }
  
  /** 重做操作 */
  redo(): CanvasAction | null {
    if (this.redoStack.length === 0) {
      Logger.warn(TAG_MODULE, 'redo: 重做栈为空');
      return null;
    }
    
    const action = this.redoStack.pop()!;
    
    // 执行正向操作
    if (this.executor) {
      this.executor.execute(action);
    }
    
    // 推入撤销栈
    this.undoStack.push(action);
    this.lastActionTime = action.timestamp;
    
    Logger.debug(TAG_MODULE, `redo: ${action.type}, undoStack=${this.undoStack.length}, redoStack=${this.redoStack.length}`);
    return action;
  }
  
  /** 是否可撤销 */
  canUndo(): boolean {
    return this.undoStack.length > 0;
  }
  
  /** 是否可重做 */
  canRedo(): boolean {
    return this.redoStack.length > 0;
  }
  
  /** 获取撤销栈大小 */
  getUndoStackSize(): number {
    return this.undoStack.length;
  }
  
  /** 获取重做栈大小 */
  getRedoStackSize(): number {
    return this.redoStack.length;
  }
  
  /** 获取上一个操作（用于预览） */
  getLastAction(): CanvasAction | null {
    return this.undoStack.length > 0 ? this.undoStack[this.undoStack.length - 1] : null;
  }
  
  /** 清空所有栈 */
  clear(): void {
    this.undoStack = [];
    this.redoStack = [];
    this.lastActionTime = 0;
    Logger.debug(TAG_MODULE, 'clear: 清空撤销/重做栈');
  }
  
  /** 检查是否可与上一个操作合并 */
  private canMergeWithLast(action: CanvasAction): boolean {
    if (this.undoStack.length === 0) {
      return false;
    }
    
    const lastAction = this.undoStack[this.undoStack.length - 1];
    
    // 检查时间窗口
    const timeDiff = action.timestamp - lastAction.timestamp;
    if (timeDiff > this.config.mergeTimeWindow) {
      return false;
    }
    
    // 检查操作类型（只有笔画添加可以合并）
    if (action.type !== ActionType.STROKE_ADD || lastAction.type !== ActionType.STROKE_ADD) {
      return false;
    }
    
    // 检查是否标记为可合并
    if (!action.canMerge || !lastAction.canMerge) {
      return false;
    }
    
    return true;
  }
  
  /** 与上一个操作合并 */
  private mergeWithLast(action: CanvasAction): void {
    const lastAction = this.undoStack[this.undoStack.length - 1];
    
    // 创建复合操作
    if (!lastAction.mergedActions) {
      lastAction.mergedActions = [lastAction];
    }
    lastAction.mergedActions.push(action);
    
    // 更新时间戳
    lastAction.timestamp = action.timestamp;
    this.lastActionTime = action.timestamp;
    
    Logger.debug(TAG_MODULE, `mergeWithLast: 合并笔画操作，mergedActions=${lastAction.mergedActions.length}`);
  }
  
  /** 创建笔画添加操作 */
  static createStrokeAddAction(stroke: StrokeData, description: string = '添加笔画'): CanvasAction {
    return {
      type: ActionType.STROKE_ADD,
      data: stroke,
      reverseData: stroke, // 反向操作需要删除该笔画
      timestamp: Date.now(),
      description,
      canMerge: true
    };
  }
  
  /** 创建形状添加操作 */
  static createShapeAddAction(shape: ShapeData, description: string = '添加形状'): CanvasAction {
    return {
      type: ActionType.SHAPE_ADD,
      data: shape,
      reverseData: shape,
      timestamp: Date.now(),
      description
    };
  }
  
  /** 创建图片添加操作 */
  static createImageAddAction(image: ImageData, description: string = '添加图片'): CanvasAction {
    return {
      type: ActionType.IMAGE_ADD,
      data: image,
      reverseData: image,
      timestamp: Date.now(),
      description
    };
  }
  
  /** 创建擦除操作 */
  static createEraseAction(eraseData: EraseData, description: string = '擦除'): CanvasAction {
    return {
      type: ActionType.ERASE,
      data: eraseData,
      reverseData: eraseData, // 反向操作需要恢复被擦除的内容
      timestamp: Date.now(),
      description
    };
  }
  
  /** 创建清空操作 */
  static createClearAction(
    originalStrokes: StrokeData[],
    originalShapes: ShapeData[],
    originalImages: ImageData[],
    description: string = '清空画布'
  ): CanvasAction {
    return {
      type: ActionType.CLEAR,
      data: null,
      reverseData: {
        originalStrokes,
        originalShapes,
        originalImages
      } as EraseData,
      timestamp: Date.now(),
      description
    };
  }
}

/** 节点操作类型（ENG-05：便签/移动/删除/双链 的撤销重做） */
export enum NodeOpType {
  NODE_ADD = 'node_add',
  NODE_REMOVE = 'node_remove',
  NODE_MOVE = 'node_move',
  NODE_MODIFY = 'node_modify'
}

/** 节点操作记录（Command 模式：apply/reverse 由外部执行器落地到数据层） */
export interface NodeOp {
  type: NodeOpType;
  node: CanvasNode | null;
  prevX: number;
  prevY: number;
  prevW: number;
  prevH: number;
  nextX: number;
  nextY: number;
  nextW: number;
  nextH: number;
  timestamp: number;
  description: string;
}

/** 节点操作执行器接口（页面实现：把命令应用到合规 BoardData + 落盘） */
export interface NodeOpExecutor {
  apply(op: NodeOp): void;
  reverse(op: NodeOp): void;
}

/**
 * 节点级撤销/重做（ENG-05）：与既有 StrokeAction 栈并存，独立管理便签/移动/删除/双链操作。
 * 与 lamport 写操作协同——每次 push 由调用方自增 lamport。
 */
export class NodeUndoManager {
  private static instance: NodeUndoManager | null = null;
  private undoStack: NodeOp[] = [];
  private redoStack: NodeOp[] = [];
  private executor: NodeOpExecutor | null = null;
  private readonly maxStackSize: number = 20; // 连续 20 步无异常

  static getInstance(): NodeUndoManager {
    if (!NodeUndoManager.instance) {
      NodeUndoManager.instance = new NodeUndoManager();
    }
    return NodeUndoManager.instance;
  }

  setExecutor(executor: NodeOpExecutor): void {
    this.executor = executor;
  }

  /** 记录新增节点（反向=删除） */
  pushNodeAdd(node: CanvasNode): void {
    this.push({
      type: NodeOpType.NODE_ADD,
      node: node,
      prevX: 0, prevY: 0, prevW: 0, prevH: 0,
      nextX: node.x, nextY: node.y, nextW: node.w, nextH: node.h,
      timestamp: Date.now(),
      description: '新增节点'
    });
  }

  /** 记录删除节点（反向=恢复） */
  pushNodeRemove(node: CanvasNode): void {
    this.push({
      type: NodeOpType.NODE_REMOVE,
      node: node,
      prevX: node.x, prevY: node.y, prevW: node.w, prevH: node.h,
      nextX: 0, nextY: 0, nextW: 0, nextH: 0,
      timestamp: Date.now(),
      description: '删除节点'
    });
  }

  /** 记录移动/缩放节点（反向=回到旧包围盒） */
  pushNodeMove(node: CanvasNode, fromX: number, fromY: number, fromW: number, fromH: number,
    toX: number, toY: number, toW: number, toH: number): void {
    this.push({
      type: NodeOpType.NODE_MOVE,
      node: node,
      prevX: fromX, prevY: fromY, prevW: fromW, prevH: fromH,
      nextX: toX, nextY: toY, nextW: toW, nextH: toH,
      timestamp: Date.now(),
      description: '移动/缩放节点'
    });
  }

  private push(op: NodeOp): void {
    this.undoStack.push(op);
    this.redoStack = [];
    if (this.undoStack.length > this.maxStackSize) {
      this.undoStack.shift();
    }
  }

  /** 撤销（执行反向操作） */
  undo(): NodeOp | null {
    if (this.undoStack.length === 0) {
      return null;
    }
    const op: NodeOp = this.undoStack.pop() as NodeOp;
    if (this.executor) {
      this.executor.reverse(op);
    }
    this.redoStack.push(op);
    return op;
  }

  /** 重做（执行正向操作） */
  redo(): NodeOp | null {
    if (this.redoStack.length === 0) {
      return null;
    }
    const op: NodeOp = this.redoStack.pop() as NodeOp;
    if (this.executor) {
      this.executor.apply(op);
    }
    this.undoStack.push(op);
    return op;
  }

  canUndo(): boolean {
    return this.undoStack.length > 0;
  }

  canRedo(): boolean {
    return this.redoStack.length > 0;
  }

  clear(): void {
    this.undoStack = [];
    this.redoStack = [];
  }
}
