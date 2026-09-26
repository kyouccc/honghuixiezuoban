/**
 * BrushBoxService.ets — 笔盒/自定义笔刷（P1 增强）
 *
 * 提供笔刷预设管理、自定义笔刷保存/加载。
 */
import { Logger } from '../common/Logger';

const TAG = 'BrushBoxService';

export interface BrushPreset {
  name: string;
  type: string;
  color: string;
  width: number;
  opacity: number;
  pressureSensitivity: boolean;
}

export class BrushBoxService {
  private static instance: BrushBoxService;
  private presets: BrushPreset[] = [];
  private activePresetIndex: number = 0;

  static getInstance(): BrushBoxService {
    if (!BrushBoxService.instance) {
      BrushBoxService.instance = new BrushBoxService();
    }
    return BrushBoxService.instance;
  }

  getPresets(): BrushPreset[] {
    return this.presets;
  }

  getActivePreset(): BrushPreset | null {
    if (this.presets.length === 0) return null;
    return this.presets[this.activePresetIndex];
  }

  addPreset(preset: BrushPreset): void {
    this.presets.push(preset);
  }

  removePreset(name: string): void {
    this.presets = this.presets.filter(p => p.name !== name);
  }

  setActivePreset(index: number): void {
    if (index >= 0 && index < this.presets.length) {
      this.activePresetIndex = index;
    }
  }

  /** 笔刷预览 - 使用显式颜色数组而非对象字面量 */
  getPresetColors(): string[] {
    return ['#000000', '#ffffff', '#ff0000', '#00ff00', '#0000ff', '#ffff00'];
  }

  /** 默认预设 */
  loadDefaults(): void {
    const defaultPresets: BrushPreset[] = [
      {
        name: '钢笔',
        type: 'pen',
        color: '#000000',
        width: 2,
        opacity: 1.0,
        pressureSensitivity: true
      },
      {
        name: '马克笔',
        type: 'marker',
        color: '#000000',
        width: 8,
        opacity: 0.6,
        pressureSensitivity: false
      },
      {
        name: '荧光笔',
        type: 'highlighter',
        color: '#ffff00',
        width: 12,
        opacity: 0.3,
        pressureSensitivity: false
      }
    ];
    this.presets = defaultPresets;
  }
}
