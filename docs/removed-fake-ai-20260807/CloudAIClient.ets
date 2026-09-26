import { http } from '@kit.NetworkKit';
import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';

const TAG_MODULE = 'CloudAIClient';

export interface CloudOCRRegion {
  x: number;
  y: number;
  width: number;
  height: number;
  text: string;
  confidence: number;
}

export interface CloudOCRResult {
  text: string;
  confidence: number;
  regions: CloudOCRRegion[];
}

export interface CloudSketchResult {
  svg: string;
  confidence: number;
  needsCloudRefinement: boolean;
}

export interface CloudAIResponse {
  code: number;
  message: string;
  data: Record<string, Object>;
}

export class CloudAIClient {
  private static instance: CloudAIClient | null = null;
  private baseUrl: string = Constants.API_BASE_URL;

  static getInstance(): CloudAIClient {
    if (!CloudAIClient.instance) {
      CloudAIClient.instance = new CloudAIClient();
    }
    return CloudAIClient.instance;
  }

  async sketchToVector(imageData: ArrayBuffer, strokeCount: number): Promise<CloudSketchResult> {
    const params: Record<string, Object> = {};
    params['stroke_count'] = strokeCount;
    const data: Record<string, Object> = await this.upload('/ai/sketch-to-vector', imageData, params);
    return {
      svg: String(data['svg']),
      confidence: Number(data['confidence']),
      needsCloudRefinement: Boolean(data['needsCloudRefinement'])
    };
  }

  async ocr(imageData: ArrayBuffer, language: string = 'zh-CN'): Promise<CloudOCRResult> {
    const params: Record<string, Object> = {};
    params['language'] = language;
    const data: Record<string, Object> = await this.upload('/ai/ocr', imageData, params);
    return {
      text: String(data['text']),
      confidence: Number(data['confidence']),
      regions: (data['regions'] as CloudOCRRegion[]) || []
    };
  }

  private async upload(path: string, imageData: ArrayBuffer, params: Record<string, Object>): Promise<Record<string, Object>> {
    const url = `${this.baseUrl}${path}`;
    const token = AppStorage.get<string>('authToken') ?? '';

    try {
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(url, {
        method: http.RequestMethod.POST,
        header: {
          'Content-Type': 'multipart/form-data',
          'Authorization': token ? `Bearer ${token}` : ''
        },
        extraData: imageData,
        connectTimeout: Constants.AI_INFERENCE_TIMEOUT_MS,
        readTimeout: Constants.AI_INFERENCE_TIMEOUT_MS
      });

      httpRequest.destroy();

      if (response.responseCode === 200) {
        const result: CloudAIResponse = JSON.parse(response.result as string) as CloudAIResponse;
        Logger.info(TAG_MODULE, `Cloud AI success: ${path} → confidence=${String(result.data['confidence'])}`);
        return result.data;
      }

      Logger.error(TAG_MODULE, `Cloud AI failed: HTTP ${response.responseCode}`);
      throw new Error(`Cloud AI HTTP ${response.responseCode}`);
    } catch (err) {
      Logger.error(TAG_MODULE, `Cloud AI error: ${err}`);
      throw err;
    }
  }
}
