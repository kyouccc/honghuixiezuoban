/**
 * TextToolService.ets — 文本输入工具（P0 缺失功能完善）
 *
 * 在已有 TextBlockTool + noteMode 'text' 基础上，提供：
 *  1. 完整的文本编辑面板（字体/字号/颜色/对齐/粗斜体）
 *  2. 点击画布即创建文本框并进入编辑状态
 *  3. 双击已有文本节点进入编辑
 *  4. 文本框拖拽调整位置
 */
import { Logger } from '../common/Logger';
import { TextAlign } from './TextBlockTool';

const TAG = 'TextToolService';

/** 文本样式配置 */
export interface TextStyleConfig {
  fontSize: number;
  fontFamily: string;
  align: TextAlign;
  color: string;
  bold: boolean;
  italic: boolean;
  underline: boolean;
}

/** 文本编辑状态 */
export interface TextEditState {
  nodeId: string;
  content: string;
  style: TextStyleConfig;
  x: number;
  y: number;
  width: number;
  height: number;
  editing: boolean;
}

export class TextToolService {
  private static instance: TextToolService;
  private editState: TextEditState | null = null;
  private savedStyles: Map<string, TextStyleConfig> = new Map();

  static getInstance(): TextToolService {
    if (!TextToolService.instance) {
      TextToolService.instance = new TextToolService();
    }
    return TextToolService.instance;
  }

  /** 默认文本样式 */
  getDefaultStyle(): TextStyleConfig {
    return {
      fontSize: 20,
      fontFamily: 'HarmonyOS Sans',
      align: TextAlign.LEFT,
      color: '#000000',
      bold: false,
      italic: false,
      underline: false
    };
  }

  /** 已有节点样式，或默认 */
  getStyleForNode(nodeId: string): TextStyleConfig {
    return this.savedStyles.get(nodeId) ?? this.getDefaultStyle();
  }

  /** 保存节点样式 */
  saveStyleForNode(nodeId: string, style: TextStyleConfig): void {
    const copy: TextStyleConfig = {
      fontSize: style.fontSize,
      fontFamily: style.fontFamily,
      align: style.align,
      color: style.color,
      bold: style.bold,
      italic: style.italic,
      underline: style.underline
    };
    this.savedStyles.set(nodeId, copy);
  }

  /** 开始编辑文本 */
  startEdit(nodeId: string, content: string, style: TextStyleConfig,
    x: number, y: number, w: number, h: number): void {
    const styleCopy: TextStyleConfig = {
      fontSize: style.fontSize,
      fontFamily: style.fontFamily,
      align: style.align,
      color: style.color,
      bold: style.bold,
      italic: style.italic,
      underline: style.underline
    };
    this.editState = {
      nodeId: nodeId,
      content: content,
      style: styleCopy,
      x: x,
      y: y,
      width: w,
      height: h,
      editing: true
    };
    Logger.info(TAG, `startEdit node=${nodeId}`);
  }

  /** 更新编辑内容 */
  updateContent(content: string): void {
    if (this.editState) {
      this.editState.content = content;
    }
  }

  /** 更新编辑样式 */
  updateStyle(style: TextStyleConfig): void {
    if (this.editState) {
      this.editState.style.fontSize = style.fontSize;
      this.editState.style.fontFamily = style.fontFamily;
      this.editState.style.align = style.align;
      this.editState.style.color = style.color;
      this.editState.style.bold = style.bold;
      this.editState.style.italic = style.italic;
      this.editState.style.underline = style.underline;
      this.saveStyleForNode(this.editState.nodeId, this.editState.style);
    }
  }

  /** 结束编辑，返回最终内容 */
  finishEdit(): TextEditState | null {
    const state = this.editState;
    if (state) {
      this.saveStyleForNode(state.nodeId, state.style);
    }
    this.editState = null;
    return state;
  }

  /** 取消编辑 */
  cancelEdit(): void {
    this.editState = null;
  }

  /** 当前编辑状态 */
  getEditState(): TextEditState | null {
    return this.editState;
  }

  /** 是否正在编辑 */
  isEditing(): boolean {
    return this.editState !== null && this.editState.editing;
  }

  /** 创建初始文本节点数据 */
  createTextPayload(content: string, style: TextStyleConfig): Record<string, Object> {
    const payload: Record<string, Object> = {
      'content': content,
      'md': false,
      'size': style.fontSize,
      'color': style.color,
      'fontFamily': style.fontFamily,
      'align': style.align,
      'bold': style.bold,
      'italic': style.italic,
      'underline': style.underline
    };
    return payload;
  }
}

/** 创建一个新文本节点的payload */
export function createDefaultTextPayload(x: number, y: number): Record<string, Object> {
  const payload: Record<string, Object> = {
    'content': '',
    'md': false,
    'size': 20,
    'color': '#000000',
    'fontFamily': 'HarmonyOS Sans',
    'align': 'left',
    'bold': false,
    'italic': false,
    'underline': false
  };
  return payload;
}
