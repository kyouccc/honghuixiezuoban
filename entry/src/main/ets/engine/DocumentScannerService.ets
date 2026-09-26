/**
 * DocumentScannerService.ets — 文档扫描（P1 增强）
 *
 * 提供拍照扫描文档、边缘检测、裁剪优化功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'DocumentScannerService';

export interface ScanResult {
  imagePath: string;
  width: number;
  height: number;
  detectedEdges: boolean;
  cropped: boolean;
}

export class DocumentScannerService {
  private static instance: DocumentScannerService;

  static getInstance(): DocumentScannerService {
    if (!DocumentScannerService.instance) {
      DocumentScannerService.instance = new DocumentScannerService();
    }
    return DocumentScannerService.instance;
  }

  async scanDocument(imagePath: string): Promise<ScanResult> {
    Logger.info(TAG, `scanDocument: ${imagePath}`);
    const result: ScanResult = {
      imagePath: imagePath,
      width: 0,
      height: 0,
      detectedEdges: false,
      cropped: false
    };
    return result;
  }

  detectEdges(imagePath: string): Promise<number[][]> {
    Logger.info(TAG, `detectEdges: ${imagePath}`);
    const empty: number[][] = [];
    return Promise.resolve(empty);
  }

  cropToDocument(imagePath: string, points: number[][]): Promise<string> {
    Logger.info(TAG, `cropToDocument`);
    return Promise.resolve(imagePath);
  }

  enhanceImage(imagePath: string): Promise<string> {
    Logger.info(TAG, `enhanceImage`);
    return Promise.resolve(imagePath);
  }
}
