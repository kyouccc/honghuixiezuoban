/**
 * MemoryMonitor.ets — 内存监控工具
 *
 * 功能：
 * 1. 监控Canvas内存使用情况
 * 2. 大画布时（> 4096x4096）触发预警
 * 3. 提供内存使用统计接口
 *
 * ArkTS 严格模式：无 any/unknown、显式类型。
 */

/** 内存预警级别 */
export enum MemoryWarningLevel {
  /** 正常，无需预警 */
  NORMAL = 0,
  /** 警告，内存使用较高 */
  WARNING = 1,
  /** 危险，内存使用过高 */
  CRITICAL = 2
}

/** 内存统计信息 */
export interface MemoryStats {
  /** 画布宽度（像素） */
  canvasWidth: number;
  /** 画布高度（像素） */
  canvasHeight: number;
  /** 画布总像素数 */
  totalPixels: number;
  /** 预估内存占用（字节） */
  estimatedMemory: number;
  /** 预估内存占用（MB） */
  estimatedMemoryMB: number;
  /** 预警级别 */
  warningLevel: MemoryWarningLevel;
  /** 预警消息 */
  warningMessage: string;
}

/** 内存监控配置 */
export interface MemoryMonitorConfig {
  /** 警告阈值（MB），默认 100MB */
  warningThresholdMB: number;
  /** 危险阈值（MB），默认 200MB */
  criticalThresholdMB: number;
  /** 大画布阈值（像素），默认 4096 */
  largeCanvasThreshold: number;
}

/** 推荐画布尺寸 */
export interface RecommendedSize {
  /** 宽度 */
  width: number;
  /** 高度 */
  height: number;
}

export class MemoryMonitor {
  /** 默认配置 */
  private static readonly DEFAULT_CONFIG: MemoryMonitorConfig = {
    warningThresholdMB: 100,
    criticalThresholdMB: 200,
    largeCanvasThreshold: 4096
  };

  /**
   * 计算Canvas内存使用情况。
   * @param width 画布宽度（像素）
   * @param height 画布高度（像素）
   * @param bytesPerPixel 每像素字节数，默认 4（RGBA）
   * @param config 监控配置
   * @returns 内存统计信息
   */
  static calculateMemoryUsage(
    width: number,
    height: number,
    bytesPerPixel: number = 4,
    config: MemoryMonitorConfig = MemoryMonitor.DEFAULT_CONFIG
  ): MemoryStats {
    const totalPixels: number = width * height;
    const estimatedMemory: number = totalPixels * bytesPerPixel;
    const estimatedMemoryMB: number = estimatedMemory / (1024 * 1024);

    let warningLevel: MemoryWarningLevel = MemoryWarningLevel.NORMAL;
    let warningMessage: string = '';

    // 判断预警级别
    if (estimatedMemoryMB >= config.criticalThresholdMB) {
      warningLevel = MemoryWarningLevel.CRITICAL;
      warningMessage = `⚠️ 内存使用过高：${estimatedMemoryMB.toFixed(2)}MB，建议减小画布尺寸`;
    } else if (estimatedMemoryMB >= config.warningThresholdMB) {
      warningLevel = MemoryWarningLevel.WARNING;
      warningMessage = `⚡ 内存使用较高：${estimatedMemoryMB.toFixed(2)}MB，请注意性能`;
    } else if (width > config.largeCanvasThreshold || height > config.largeCanvasThreshold) {
      warningLevel = MemoryWarningLevel.WARNING;
      warningMessage = `📐 大画布尺寸：${width}x${height}，可能影响性能`;
    }

    return {
      canvasWidth: width,
      canvasHeight: height,
      totalPixels: totalPixels,
      estimatedMemory: estimatedMemory,
      estimatedMemoryMB: estimatedMemoryMB,
      warningLevel: warningLevel,
      warningMessage: warningMessage
    };
  }

  /**
   * 检查画布尺寸是否合理。
   * @param width 画布宽度（像素）
   * @param height 画布高度（像素）
   * @param maxWidth 最大宽度，默认 8192
   * @param maxHeight 最大高度，默认 8192
   * @returns 是否合理
   */
  static isCanvasSizeReasonable(
    width: number,
    height: number,
    maxWidth: number = 8192,
    maxHeight: number = 8192
  ): boolean {
    return width > 0 && height > 0 && width <= maxWidth && height <= maxHeight;
  }

  /**
   * 获取推荐的画布尺寸。
   * 如果当前尺寸过大，返回推荐的较小尺寸。
   * @param width 当前宽度（像素）
   * @param height 当前高度（像素）
   * @param targetMemoryMB 目标内存占用（MB），默认 50MB
   * @returns 推荐的画布尺寸
   */
  static getRecommendedSize(
    width: number,
    height: number,
    targetMemoryMB: number = 50
  ): RecommendedSize {
    const currentMemoryMB: number = (width * height * 4) / (1024 * 1024);
    
    if (currentMemoryMB <= targetMemoryMB) {
      const result: RecommendedSize = { width: width, height: height };
      return result;
    }

    // 计算缩放比例
    const scale: number = Math.sqrt(targetMemoryMB / currentMemoryMB);
    const recommendedWidth: number = Math.floor(width * scale);
    const recommendedHeight: number = Math.floor(height * scale);

    const result: RecommendedSize = {
      width: recommendedWidth,
      height: recommendedHeight
    };
    return result;
  }

  /**
   * 格式化内存统计信息为字符串。
   * @param stats 内存统计信息
   * @returns 格式化字符串
   */
  static formatMemoryStats(stats: MemoryStats): string {
    const lines: string[] = [
      `📊 Canvas内存统计：`,
      `  尺寸：${stats.canvasWidth}x${stats.canvasHeight}`,
      `  总像素：${stats.totalPixels.toLocaleString()}`,
      `  预估内存：${stats.estimatedMemoryMB.toFixed(2)}MB`
    ];

    if (stats.warningMessage !== '') {
      lines.push(`  ${stats.warningMessage}`);
    }

    return lines.join('\n');
  }
}
