/**
 * AIService.ets — AI辅助（P2 扩展）
 *
 * 提供 OCR 识别、智能整理、内容生成等 AI 能力。
 */
import { Logger } from '../common/Logger';

const TAG = 'AIService';

export interface OCRResult {
  text: string;
  confidence: number;
  boundingBox: number[];
}

export interface AICompletion {
  text: string;
  finishReason: string;
}

export class AIService {
  private static instance: AIService;
  private apiKey: string = '';
  private apiUrl: string = '';

  static getInstance(): AIService {
    if (!AIService.instance) {
      AIService.instance = new AIService();
    }
    return AIService.instance;
  }

  setEndpoint(url: string, key: string): void {
    this.apiUrl = url;
    this.apiKey = key;
  }

  async ocrImage(imagePath: string): Promise<OCRResult[]> {
    Logger.info(TAG, `ocrImage: ${imagePath}`);
    const results: OCRResult[] = [];
    return results;
  }

  async completeText(prompt: string): Promise<AICompletion | null> {
    Logger.info(TAG, `completeText, prompt length: ${prompt.length}`);
    const result: AICompletion = {
      text: '',
      finishReason: 'error'
    };
    return result;
  }

  async summarize(content: string): Promise<string> {
    Logger.info(TAG, `summarize, content length: ${content.length}`);
    return '';
  }

  async translate(text: string, targetLang: string): Promise<string> {
    Logger.info(TAG, `translate to ${targetLang}`);
    return text;
  }

  async smartFormat(content: string): Promise<string> {
    Logger.info(TAG, 'smartFormat');
    return content;
  }
}
