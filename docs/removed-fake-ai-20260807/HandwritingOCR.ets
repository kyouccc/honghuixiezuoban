// ============================================================
// HandwritingOCR.ets
// 手写文字OCR识别（云端服务）
// 说明：本地AI模型功能暂未开放，当前使用云端服务
// ============================================================

import { Logger } from '../common/Logger';
import { CloudAIClient } from './CloudAIClient';

const TAG_MODULE = 'HandwritingOCR';

export interface OCRResult {
  text: string;
  confidence: number;
  regions: OCRRegion[];
  source: 'cloud' | 'unavailable';
  latencyMs: number;
}

export interface OCRRegion {
  x: number;
  y: number;
  width: number;
  height: number;
  text: string;
  confidence: number;
}

export class HandwritingOCR {
  private isAvailable: boolean = false;

  async initialize(): Promise<void> {
    try {
      // 尝试初始化云端服务，但默认设为不可用
      // 实际项目中应实现checkAvailability方法
      const cloudClient = CloudAIClient.getInstance();
      // 暂时设置为可用，实际使用时会进行网络检查
      this.isAvailable = true;
      Logger.info(TAG_MODULE, 'OCR service initialized (cloud mode)');
    } catch (err) {
      Logger.error(TAG_MODULE, `OCR service initialization failed: ${err}`);
      this.isAvailable = false;
    }
  }

  /**
   * 识别画布上的手写文字
   * @param strokeBitmaps 每个笔画区域对应的位图数据
   */
  async recognize(strokeBitmaps: ArrayBuffer[]): Promise<OCRResult> {
    const startTime = performance.now();

    if (!this.isAvailable) {
      return {
        text: '手写识别功能暂不可用\n请检查网络连接或稍后重试',
        confidence: 0,
        regions: [],
        source: 'unavailable',
        latencyMs: performance.now() - startTime
      };
    }

    try {
      const cloudClient = CloudAIClient.getInstance();
      const mergedBitmap = this.mergeBitmaps(strokeBitmaps);
      const result = await cloudClient.ocr(mergedBitmap, 'zh-CN');

      return {
        text: result.text,
        confidence: result.confidence,
        regions: result.regions || [],
        source: 'cloud',
        latencyMs: performance.now() - startTime
      };
    } catch (err) {
      Logger.error(TAG_MODULE, `Cloud OCR failed: ${err}`);
      return {
        text: '识别失败，请重试',
        confidence: 0,
        regions: [],
        source: 'unavailable',
        latencyMs: performance.now() - startTime
      };
    }
  }

  private mergeBitmaps(bitmaps: ArrayBuffer[]): ArrayBuffer {
    // 合并多行bitmap为单张图片上传云端
    if (bitmaps.length === 0) return new ArrayBuffer(0);
    if (bitmaps.length === 1) return bitmaps[0];

    const totalSize = bitmaps.reduce((s, b) => s + b.byteLength, 0);
    const merged = new Uint8Array(totalSize);
    let offset = 0;
    for (const bmp of bitmaps) {
      merged.set(new Uint8Array(bmp), offset);
      offset += bmp.byteLength;
    }
    return merged.buffer;
  }
}
