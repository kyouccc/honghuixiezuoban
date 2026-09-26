/**
 * 设备适配服务
 * 检测设备类型和屏幕尺寸，提供自适应布局参数
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';

const TAG = 'DeviceAdapter';
const DOMAIN = 0x0000;

export enum DeviceType {
  PHONE = 'phone',
  TABLET = 'tablet',
  LARGE_SCREEN = 'large_screen',
  TV = 'tv',
  E_INK = 'e_ink',
  UNKNOWN = 'unknown'
}

/** 折叠状态枚举 */
export enum FoldStatus {
  UNKNOWN = 0,      // 未知或不可折叠
  EXPANDED = 1,     // 完全展开
  FOLDED = 2,       // 折叠
  HALF_FOLDED = 3   // 半折叠（悬停态）
}

/** 显示模式枚举 */
export enum FoldDisplayMode {
  MAIN = 0,   // 主屏显示
  FULL = 1,   // 全屏显示
  SUB = 2     // 副屏显示
}

export interface DeviceInfo {
  type: DeviceType;
  screenWidth: number;
  screenHeight: number;
  density: number;
  isLandscape: boolean;
  isFoldable: boolean;
  foldStatus: FoldStatus;           // 当前折叠状态
  foldDisplayMode: FoldDisplayMode;  // 当前显示模式
  isEInk: boolean;                  // 是否墨水屏
  recommendedFontSize: number;
  recommendedIconSize: number;
  recommendedToolbarHeight: number;
  recommendedCanvasPadding: number;
}

/** 墨水屏专属渲染配置 */
export interface EInkRenderConfig {
  /** 是否禁用阴影（墨水屏无法渲染阴影） */
  disableShadow: boolean;
  /** 是否禁用动画（墨水屏刷新慢） */
  disableAnimation: boolean;
  /** 是否禁用抗锯齿（提升刷新速度） */
  disableAntiAlias: boolean;
  /** 笔触渲染简化级别（0=完整, 1=简化, 2=极简） */
  renderSimplifyLevel: number;
  /** 对比度增强系数（1.0=正常, >1.0=增强） */
  contrastFactor: number;
  /** 是否使用灰度模式 */
  grayscale: boolean;
}

export interface RecommendedParams {
  recommendedFontSize: number;
  recommendedIconSize: number;
  recommendedToolbarHeight: number;
  recommendedCanvasPadding: number;
}

export class DeviceAdapter {
  private static instance: DeviceAdapter;
  private context: common.UIAbilityContext | null = null;
  private deviceInfo: DeviceInfo | null = null;
  private displayListener: (() => void) | null = null;

  private constructor() {}

  static getInstance(): DeviceAdapter {
    if (!DeviceAdapter.instance) {
      DeviceAdapter.instance = new DeviceAdapter();
    }
    return DeviceAdapter.instance;
  }

  /**
   * SDK 折叠状态枚举 → 项目内 FoldStatus 枚举（数值一致 0/1/2/3，做显式映射保证类型安全）。
   */
  private static mapFoldStatus(status: display.FoldStatus): FoldStatus {
    if (status === display.FoldStatus.FOLD_STATUS_EXPANDED) {
      return FoldStatus.EXPANDED;
    }
    if (status === display.FoldStatus.FOLD_STATUS_FOLDED) {
      return FoldStatus.FOLDED;
    }
    if (status === display.FoldStatus.FOLD_STATUS_HALF_FOLDED) {
      return FoldStatus.HALF_FOLDED;
    }
    return FoldStatus.UNKNOWN;
  }

  /**
   * SDK 显示模式枚举 → 项目内 FoldDisplayMode 枚举。
   * 注意：SDK 的数值（UNKNOWN=0/FULL=1/MAIN=2/SUB=3）与项目枚举（MAIN=0/FULL=1/SUB=2）不一致，
   * 必须按成员名显式映射，不能按数值转换。
   */
  private static mapFoldDisplayMode(mode: display.FoldDisplayMode): FoldDisplayMode {
    if (mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_FULL) {
      return FoldDisplayMode.FULL;
    }
    if (mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_MAIN) {
      return FoldDisplayMode.MAIN;
    }
    if (mode === display.FoldDisplayMode.FOLD_DISPLAY_MODE_SUB) {
      return FoldDisplayMode.SUB;
    }
    // SDK UNKNOWN → 项目无 UNKNOWN，回退主屏
    return FoldDisplayMode.MAIN;
  }

  /**
   * 初始化服务
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    
    // 获取设备信息
    await this.updateDeviceInfo();
    
    // 监听屏幕变化
    this.setupDisplayListener();
    
    hilog.info(DOMAIN, TAG, `DeviceAdapter initialized: ${this.deviceInfo?.type}`);
  }

  /**
   * 更新设备信息
   */
  private async updateDeviceInfo(): Promise<void> {
    try {
      const displayInfo = display.getDefaultDisplaySync();
      
      const width = displayInfo.width;
      const height = displayInfo.height;
      const density = displayInfo.densityDPI / 160; // 标准化为 mdpi (160 DPI)
      
      // 判断设备类型
      const type = this.determineDeviceType(width, height, density);
      
      // 计算推荐的 UI 参数
      const recommendedParams = this.calculateRecommendedParams(type, width, height, density);
      
      // 检测折叠屏状态
      let isFoldable = false;
      let foldStatus = FoldStatus.UNKNOWN;
      let foldDisplayMode = FoldDisplayMode.MAIN;
      
      try {
        isFoldable = display.isFoldable();
        if (isFoldable) {
          foldStatus = DeviceAdapter.mapFoldStatus(display.getFoldStatus());
          foldDisplayMode = DeviceAdapter.mapFoldDisplayMode(display.getFoldDisplayMode());
          hilog.info(DOMAIN, TAG, `Foldable device detected: status=${foldStatus}, mode=${foldDisplayMode}`);
        }
      } catch (error) {
        hilog.warn(DOMAIN, TAG, `Failed to detect fold status: ${JSON.stringify(error)}`);
      }
      
      this.deviceInfo = {
        type,
        screenWidth: width,
        screenHeight: height,
        density,
        isLandscape: width > height,
        isFoldable,
        foldStatus,
        foldDisplayMode,
        isEInk: type === DeviceType.E_INK,
        recommendedFontSize: recommendedParams.recommendedFontSize,
        recommendedIconSize: recommendedParams.recommendedIconSize,
        recommendedToolbarHeight: recommendedParams.recommendedToolbarHeight,
        recommendedCanvasPadding: recommendedParams.recommendedCanvasPadding
      };
      
      // 更新 AppStorage
      AppStorage.setOrCreate<string>('deviceType', type);
      AppStorage.setOrCreate<number>('screenWidth', width);
      AppStorage.setOrCreate<number>('screenHeight', height);
      
      hilog.info(DOMAIN, TAG, `Device info updated: ${JSON.stringify(this.deviceInfo)}`);
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to update device info: ${JSON.stringify(error)}`);
      
      // 使用默认值
      this.deviceInfo = {
        type: DeviceType.PHONE,
        screenWidth: 1080,
        screenHeight: 1920,
        density: 2,
        isLandscape: false,
        isFoldable: false,
        foldStatus: FoldStatus.UNKNOWN,
        foldDisplayMode: FoldDisplayMode.MAIN,
        isEInk: false,
        recommendedFontSize: 14,
        recommendedIconSize: 24,
        recommendedToolbarHeight: 56,
        recommendedCanvasPadding: 0
      };
    }
  }

  /**
   * 判断设备类型
   */
  private determineDeviceType(width: number, height: number, density: number): DeviceType {
    const minDimension = Math.min(width, height);
    const maxDimension = Math.max(width, height);
    
    // 根据屏幕尺寸判断
    // 手机：< 600dp 短边
    // 平板：600dp - 840dp 短边
    // 大屏：> 840dp 短边
    
    const minDp = minDimension / density;
    
    if (minDp < 600) {
      return DeviceType.PHONE;
    } else if (minDp < 840) {
      return DeviceType.TABLET;
    } else {
      return DeviceType.LARGE_SCREEN;
    }
  }

  /**
   * 计算推荐的 UI 参数
   */
  private calculateRecommendedParams(
    type: DeviceType,
    width: number,
    height: number,
    density: number
  ): RecommendedParams {
    switch (type) {
      case DeviceType.PHONE: {
        const result: RecommendedParams = {
          recommendedFontSize: 14,
          recommendedIconSize: 24,
          recommendedToolbarHeight: 56,
          recommendedCanvasPadding: 0
        };
        return result;
      }
        
      case DeviceType.TABLET: {
        const result: RecommendedParams = {
          recommendedFontSize: 16,
          recommendedIconSize: 32,
          recommendedToolbarHeight: 64,
          recommendedCanvasPadding: 16
        };
        return result;
      }
        
      case DeviceType.LARGE_SCREEN: {
        const result: RecommendedParams = {
          recommendedFontSize: 18,
          recommendedIconSize: 40,
          recommendedToolbarHeight: 72,
          recommendedCanvasPadding: 32
        };
        return result;
      }

      case DeviceType.E_INK: {
        // 墨水屏：大字号、高对比度、无阴影动画
        const result: RecommendedParams = {
          recommendedFontSize: 18,
          recommendedIconSize: 36,
          recommendedToolbarHeight: 64,
          recommendedCanvasPadding: 12
        };
        return result;
      }
        
      default: {
        const result: RecommendedParams = {
          recommendedFontSize: 14,
          recommendedIconSize: 24,
          recommendedToolbarHeight: 56,
          recommendedCanvasPadding: 0
        };
        return result;
      }
    }
  }

  /**
   * 设置屏幕变化监听（包括折叠状态变化）
   */
  private setupDisplayListener(): void {
    try {
      // 监听显示变化
      this.displayListener = () => {
        hilog.info(DOMAIN, TAG, 'Display changed, updating device info');
        this.updateDeviceInfo();
      };
      display.on('change', this.displayListener);
      
      // 监听折叠状态变化
      display.on('foldStatusChange', (foldStatus: display.FoldStatus) => {
        const s: FoldStatus = DeviceAdapter.mapFoldStatus(foldStatus);
        hilog.info(DOMAIN, TAG, `Fold status changed: ${s}`);
        if (this.deviceInfo) {
          this.deviceInfo.foldStatus = s;
          // 通知UI更新
          this.notifyFoldStatusChange(s);
        }
      });
      
      // 监听显示模式变化
      display.on('foldDisplayModeChange', (displayMode: display.FoldDisplayMode) => {
        const m: FoldDisplayMode = DeviceAdapter.mapFoldDisplayMode(displayMode);
        hilog.info(DOMAIN, TAG, `Fold display mode changed: ${m}`);
        if (this.deviceInfo) {
          this.deviceInfo.foldDisplayMode = m;
        }
      });
      
      hilog.info(DOMAIN, TAG, 'Display and fold listeners setup successfully');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to setup display listener: ${JSON.stringify(error)}`);
    }
  }
  
  /**
   * 通知折叠状态变化（子类可重写）
   */
  protected notifyFoldStatusChange(foldStatus: FoldStatus): void {
    // 默认实现：记录日志
    hilog.info(DOMAIN, TAG, `Fold status changed to: ${foldStatus}`);
  }

  /**
   * 获取设备信息
   */
  getDeviceInfo(): DeviceInfo | null {
    return this.deviceInfo;
  }

  /**
   * 获取设备类型
   */
  getDeviceType(): DeviceType {
    return this.deviceInfo?.type || DeviceType.PHONE;
  }

  /**
   * 是否为手机
   */
  isPhone(): boolean {
    return this.deviceInfo?.type === DeviceType.PHONE;
  }

  /**
   * 是否为平板
   */
  isTablet(): boolean {
    return this.deviceInfo?.type === DeviceType.TABLET;
  }

  /**
   * 是否为大屏
   */
  isLargeScreen(): boolean {
    return this.deviceInfo?.type === DeviceType.LARGE_SCREEN;
  }

  /**
   * 是否为墨水屏设备
   * 墨水屏专属适配：禁用阴影/动画、增强对比度、简化笔触渲染
   */
  isEInk(): boolean {
    return this.deviceInfo?.type === DeviceType.E_INK;
  }

  /**
   * 获取墨水屏专属渲染配置。
   * 非墨水屏设备返回默认配置（全部启用）。
   * 墨水屏设备：禁用阴影/动画/抗锯齿，对比度增强1.3x，灰度模式。
   */
  getEInkRenderConfig(): EInkRenderConfig {
    if (this.isEInk()) {
      return {
        disableShadow: true,
        disableAnimation: true,
        disableAntiAlias: true,
        renderSimplifyLevel: 2,
        contrastFactor: 1.3,
        grayscale: true
      };
    }
    return {
      disableShadow: false,
      disableAnimation: false,
      disableAntiAlias: false,
      renderSimplifyLevel: 0,
      contrastFactor: 1.0,
      grayscale: false
    };
  }

  /**
   * 获取推荐的字体大小
   */
  getRecommendedFontSize(): number {
    return this.deviceInfo?.recommendedFontSize || 14;
  }

  /**
   * 获取推荐的图标大小
   */
  getRecommendedIconSize(): number {
    return this.deviceInfo?.recommendedIconSize || 24;
  }

  /**
   * 获取推荐的工具栏高度
   */
  getRecommendedToolbarHeight(): number {
    return this.deviceInfo?.recommendedToolbarHeight || 56;
  }

  /**
   * 获取推荐的画布内边距
   */
  getRecommendedCanvasPadding(): number {
    return this.deviceInfo?.recommendedCanvasPadding || 0;
  }

  /**
   * 根据设备类型调整尺寸
   */
  scaleSize(baseSize: number): number {
    if (!this.deviceInfo) return baseSize;
    
    const scaleFactor = this.deviceInfo.density / 2; // 以 2x 为基准
    
    switch (this.deviceInfo.type) {
      case DeviceType.PHONE:
        return baseSize;
      case DeviceType.TABLET:
        return baseSize * 1.2;
      case DeviceType.LARGE_SCREEN:
        return baseSize * 1.5;
      default:
        return baseSize;
    }
  }

  /**
   * 获取列数（用于网格布局）
   */
  getGridColumns(): number {
    if (!this.deviceInfo) return 4;
    
    const widthDp = this.deviceInfo.screenWidth / this.deviceInfo.density;
    
    if (widthDp < 360) return 3;
    if (widthDp < 600) return 4;
    if (widthDp < 840) return 6;
    return 8;
  }

  /**
   * 销毁服务
   */
  destroy(): void {
    if (this.displayListener !== null) {
      display.off('change', this.displayListener);
      this.displayListener = null;
    }
  }
}

// 导出单例
export const deviceAdapter = DeviceAdapter.getInstance();
