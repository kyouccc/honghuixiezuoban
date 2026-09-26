/**
 * TextBlockTool.ets — 文本框工具（v2.0 增量，S1T03 / NP-04）
 *
 * 创建 TextBlock 元素（文本内容/对齐/字号/颜色），支持实时编辑。
 * TextBlockData 为 CRDT 元素（RGA 元素泛型 CanvasElement 联合类型成员，
 * 可直接 RGAEngine<CanvasElement>.localInsert(block) 入 RGA 收敛）。
 */

import { Logger } from '../common/Logger';
import { TextBlockData } from './types/CanvasElement';

const TAG_MODULE = 'TextBlockTool';

export enum TextAlign {
  LEFT = 'left',
  CENTER = 'center',
  RIGHT = 'right',
}

export class TextBlockTool {
  private currentFontSize: number = 20;
  private currentFontFamily: string = 'HarmonyOS Sans';
  private currentAlign: string = TextAlign.LEFT;
  private currentColor: string = '#000000';

  setFontSize(size: number): void {
    this.currentFontSize = Math.max(8, Math.min(120, size));
  }

  setFontFamily(family: string): void {
    if (family !== undefined && family.length > 0) {
      this.currentFontFamily = family;
    }
  }

  setAlign(align: string): void {
    if (align === TextAlign.LEFT || align === TextAlign.CENTER || align === TextAlign.RIGHT) {
      this.currentAlign = align;
    }
  }

  setColor(color: string): void {
    if (color !== undefined && color.length > 0) {
      this.currentColor = color;
    }
  }

  getFontSize(): number {
    return this.currentFontSize;
  }

  getFontFamily(): string {
    return this.currentFontFamily;
  }

  getAlign(): string {
    return this.currentAlign;
  }

  getColor(): string {
    return this.currentColor;
  }

  /** 创建文本框元素 */
  createTextBlock(text: string, x: number, y: number, layerId: string, createdBy: string): TextBlockData {
    const block: TextBlockData = {
      id: `text_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`,
      layerId: layerId,
      createdBy: createdBy,
      createdAt: Date.now(),
      text: text,
      x: x,
      y: y,
      fontSize: this.currentFontSize,
      fontFamily: this.currentFontFamily,
      align: this.currentAlign,
      color: this.currentColor,
    };
    Logger.info(TAG_MODULE, `TextBlock created: ${block.id}`);
    return block;
  }

  /** 实时编辑：更新文本内容（返回新对象，保持 CRDT 元素不可变语义） */
  updateText(block: TextBlockData, newText: string): TextBlockData {
    return {
      id: block.id,
      layerId: block.layerId,
      createdBy: block.createdBy,
      createdAt: block.createdAt,
      text: newText,
      x: block.x,
      y: block.y,
      fontSize: block.fontSize,
      fontFamily: block.fontFamily,
      align: block.align,
      color: block.color,
    };
  }

  /** 更新位置（返回新对象） */
  updatePosition(block: TextBlockData, x: number, y: number): TextBlockData {
    return {
      id: block.id,
      layerId: block.layerId,
      createdBy: block.createdBy,
      createdAt: block.createdAt,
      text: block.text,
      x: x,
      y: y,
      fontSize: block.fontSize,
      fontFamily: block.fontFamily,
      align: block.align,
      color: block.color,
    };
  }

  /** 估算文本宽度（无上下文时的近似值；精确测量由渲染层使用 ctx.measureText） */
  static estimateWidth(text: string, fontSize: number): number {
    const avgCharWidth: number = fontSize * 0.55;
    return Math.max(1, Math.round(text.length * avgCharWidth));
  }

  /** 估算文本块高度（按行数） */
  static estimateHeight(fontSize: number, lineCount: number): number {
    return Math.max(fontSize, Math.round(lineCount * fontSize * 1.4));
  }
}
