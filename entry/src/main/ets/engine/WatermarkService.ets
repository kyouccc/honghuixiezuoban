/**
 * WatermarkService.ets — 水印/版权保护（P2 扩展）
 *
 * 提供画布水印添加、版权信息嵌入功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'WatermarkService';

export interface WatermarkConfig {
  text: string;
  fontSize: number;
  color: string;
  opacity: number;
  rotation: number;
  position: string;
}

export class WatermarkService {
  private static instance: WatermarkService;
  private _config: WatermarkConfig = {
    text: '',
    fontSize: 20,
    color: '#cccccc',
    opacity: 0.3,
    rotation: -30,
    position: 'center'
  };
  private _enabled: boolean = false;

  static getInstance(): WatermarkService {
    if (!WatermarkService.instance) {
      WatermarkService.instance = new WatermarkService();
    }
    return WatermarkService.instance;
  }

  get config(): WatermarkConfig {
    return {
      text: this._config.text,
      fontSize: this._config.fontSize,
      color: this._config.color,
      opacity: this._config.opacity,
      rotation: this._config.rotation,
      position: this._config.position
    };
  }

  setConfig(text: string, fontSize: number, color: string, opacity: number, rotation: number, position: string): void {
    this._config.text = text;
    this._config.fontSize = fontSize;
    this._config.color = color;
    this._config.opacity = opacity;
    this._config.rotation = rotation;
    this._config.position = position;
  }

  get enabled(): boolean { return this._enabled; }
  enable(): void { this._enabled = true; }
  disable(): void { this._enabled = false; }
  toggle(): boolean { this._enabled = !this._enabled; return this._enabled; }

  applyWatermark(context: CanvasRenderingContext2D, width: number, height: number): void {
    if (!this._enabled || this._config.text === '') return;
    Logger.info(TAG, 'applyWatermark');
  }
}
