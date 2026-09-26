/**
 * BrushRegistry.ets — 笔刷注册表（v2.0 增量，S1T01 / NP-02）
 *
 * 定义全套笔型参数：钢笔/铅笔/荧光笔/马克笔/毛笔/激光笔。
 * 每个笔型包含：笔尖形状 brushShape、压感曲线 pressureCurve、
 * 透明度 opacity、混合模式 blendMode（normal/multiply）、纹理 texture。
 * StrokeEngine 在 setTool / finalizeStroke / renderStrokeToContext 时接入本注册表。
 */

export enum BrushTool {
  PEN = 'pen',
  PENCIL = 'pencil',
  HIGHLIGHTER = 'highlighter',
  MARKER = 'marker',
  BRUSH = 'brush',
  LASER = 'laser',
  CALLIGRAPHY = 'calligraphy',
}

export enum BrushShape {
  ROUND = 'round',
  FLAT = 'flat',
  TEXTURE = 'texture',
}

export enum BlendMode {
  NORMAL = 'normal',
  MULTIPLY = 'multiply',
}

/** 笔刷配置（与 proto StrokeData field 10-14 对齐） */
export interface BrushConfig {
  tool: string;
  name: string;
  brushShape: string;       // round | flat | texture
  pressureCurve: number[];  // 压感曲线控制点（t∈[0,1] → 粗细系数）
  opacity: number;          // 0-1
  blendMode: string;        // normal | multiply
  texture: string;          // 笔刷纹理 id（''=无，grain/flat/soft 为 P0 近似纹理）
  minWidth: number;
  maxWidth: number;
  pressureSensitivity: number;  // 0=忽略压感，1=强压感
}

export class BrushRegistry {
  private static readonly configs: BrushConfig[] = [
    {
      tool: BrushTool.PEN,
      name: '钢笔',
      brushShape: BrushShape.ROUND,
      pressureCurve: [0, 0.3, 0.7, 1.0],
      opacity: 1.0,
      blendMode: BlendMode.NORMAL,
      texture: '',
      minWidth: 1,
      maxWidth: 12,
      pressureSensitivity: 0.8,
    },
    {
      tool: BrushTool.PENCIL,
      name: '铅笔',
      brushShape: BrushShape.ROUND,
      pressureCurve: [0, 0.1, 0.4, 0.9],
      opacity: 0.9,
      blendMode: BlendMode.NORMAL,
      texture: 'grain',
      minWidth: 1,
      maxWidth: 8,
      pressureSensitivity: 0.9,
    },
    {
      tool: BrushTool.HIGHLIGHTER,
      name: '荧光笔',
      brushShape: BrushShape.FLAT,
      pressureCurve: [0, 0.8, 1.0, 1.0],
      opacity: 0.4,
      blendMode: BlendMode.MULTIPLY,
      texture: '',
      minWidth: 6,
      maxWidth: 24,
      pressureSensitivity: 0.2,
    },
    {
      tool: BrushTool.MARKER,
      name: '马克笔',
      brushShape: BrushShape.FLAT,
      pressureCurve: [0, 0.6, 0.9, 1.0],
      opacity: 0.7,
      blendMode: BlendMode.NORMAL,
      texture: 'flat',
      minWidth: 4,
      maxWidth: 20,
      pressureSensitivity: 0.5,
    },
    {
      tool: BrushTool.BRUSH,
      name: '毛笔',
      brushShape: BrushShape.ROUND,
      pressureCurve: [0, 0.5, 0.8, 1.0],
      opacity: 0.85,
      blendMode: BlendMode.NORMAL,
      texture: 'soft',
      minWidth: 2,
      maxWidth: 18,
      pressureSensitivity: 1.0,
    },
    {
      tool: BrushTool.LASER,
      name: '激光笔',
      brushShape: BrushShape.ROUND,
      pressureCurve: [0, 1.0, 1.0, 1.0],
      opacity: 0.6,
      blendMode: BlendMode.NORMAL,
      texture: '',
      minWidth: 1,
      maxWidth: 6,
      pressureSensitivity: 0.0,
    },
    {
      tool: BrushTool.CALLIGRAPHY,
      name: '书法笔',
      brushShape: BrushShape.FLAT,
      pressureCurve: [0, 0.3, 1.0, 0.6],
      opacity: 0.95,
      blendMode: BlendMode.NORMAL,
      texture: 'grain',
      minWidth: 1,
      maxWidth: 24,
      pressureSensitivity: 1.2,
    },
  ];

  /** 获取笔刷配置（未知工具回退到钢笔配置） */
  static getBrushConfig(tool: string): BrushConfig {
    for (let i = 0; i < BrushRegistry.configs.length; i++) {
      const cfg: BrushConfig = BrushRegistry.configs[i];
      if (cfg.tool === tool) {
        return BrushRegistry.cloneConfig(cfg);
      }
    }
    return BrushRegistry.cloneConfig(BrushRegistry.configs[0]);
  }

  /** 获取全部笔刷配置（副本，防止外部篡改） */
  static getBrushConfigs(): BrushConfig[] {
    const result: BrushConfig[] = [];
    for (let i = 0; i < BrushRegistry.configs.length; i++) {
      result.push(BrushRegistry.cloneConfig(BrushRegistry.configs[i]));
    }
    return result;
  }

  /** 获取全部笔刷名称（UI 面板展示用） */
  static getBrushNames(): string[] {
    const names: string[] = [];
    for (let i = 0; i < BrushRegistry.configs.length; i++) {
      names.push(BrushRegistry.configs[i].name);
    }
    return names;
  }

  /** 判断是否为已注册笔型 */
  static isSupportedTool(tool: string): boolean {
    for (let i = 0; i < BrushRegistry.configs.length; i++) {
      if (BrushRegistry.configs[i].tool === tool) {
        return true;
      }
    }
    return false;
  }

  /**
   * 按压力 t∈[0,1] 对压感曲线分段线性采样，返回粗细系数（0-1）。
   * 曲线控制点横坐标均匀分布：curve[0]=t=0 处系数，curve[last]=t=1 处系数。
   */
  static samplePressureCurve(curve: number[], t: number): number {
    if (curve.length === 0) {
      return 1.0;
    }
    if (curve.length === 1) {
      return Math.max(0, Math.min(1, curve[0]));
    }
    const clampedT: number = Math.max(0, Math.min(1, t));
    const segCount: number = curve.length - 1;
    const pos: number = clampedT * segCount;
    const idx: number = Math.min(segCount - 1, Math.floor(pos));
    const frac: number = pos - idx;
    const a: number = curve[idx];
    const b: number = curve[idx + 1];
    return a + (b - a) * frac;
  }

  private static cloneConfig(cfg: BrushConfig): BrushConfig {
    return {
      tool: cfg.tool,
      name: cfg.name,
      brushShape: cfg.brushShape,
      pressureCurve: cfg.pressureCurve.slice(),
      opacity: cfg.opacity,
      blendMode: cfg.blendMode,
      texture: cfg.texture,
      minWidth: cfg.minWidth,
      maxWidth: cfg.maxWidth,
      pressureSensitivity: cfg.pressureSensitivity,
    };
  }
}
