/**
 * ThemeManager.ets - 主题管理器（F-01 暗色模式支持）
 * 
 * 功能：
 * 1. 跟随系统深浅色自动切换
 * 2. 允许用户手动覆盖
 * 3. 提供画布深色纸张选项
 * 4. 全局状态管理
 */

import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { Logger } from '../Logger';

export enum ThemeMode {
  LIGHT = 'light',
  DARK = 'dark',
  SYSTEM = 'system'  // 跟随系统
}

export enum CanvasPaperStyle {
  LIGHT = 'light',           // 白色纸张
  DARK = 'dark',             // 深色纸张（#1A1A1A）
  DARK_ALT = 'dark_alt',     // 深色纸张变体（#252525）
  WARM = 'warm',             // 暖色纸张（护眼）
  SEPIA = 'sepia'            // 褐色纸张（复古）
}

// 主题配置接口
export interface ThemeConfig {
  mode: ThemeMode;
  canvasPaper: CanvasPaperStyle;
  isSystemDark: boolean;  // 系统当前是否为暗色
  skin: string;           // 主题皮肤（classic/night/green/warm）
}

// 主题状态管理（全局单例）
export class ThemeManager {
  private static instance: ThemeManager;
  
  // 当前主题配置
  private config: ThemeConfig = {
    mode: ThemeMode.SYSTEM,
    canvasPaper: CanvasPaperStyle.LIGHT,
    isSystemDark: false,
    skin: 'classic'
  };
  
  // 状态变更回调
  private listeners: Array<(config: ThemeConfig) => void> = [];

  /**
   * v2.7.0：由 UIAbility 在 onCreate 早期注入的 ApplicationContext。
   *   原先 applyColorMode() 只依赖 `getContext(this)`，而 ThemeManager 是普通类
   *   （非 UI 组件），在 onCreate 阶段该调用可能解析不到上下文，
   *   setColorMode 静默失败 → 重启后主题设置丢失、退回跟随系统。
   *   现在显式注入，彻底摆脱对 getContext 的脆弱依赖。
   */
  private appCtx: common.ApplicationContext | null = null;
  /** 偏好是否已从磁盘加载完成（供启动流程 await） */
  private loaded: boolean = false;
  private loadPromise: Promise<void> | null = null;
  /** 最近一次成功下发的颜色模式（防重入：同值不重复 setColorMode，避免配置回调抖动） */
  private lastApplied: string = '';
  /**
   * 🔴 v2.7.1：setColorMode 重入闸门。
   *   `ApplicationContext.setColorMode()` 会在调用栈内**同步**回调
   *   UIAbility.onConfigurationUpdate，若回调中再触发主题下发就会无限递归
   *   （v2.7.0 实测崩溃：RangeError - Stack overflow）。此闸门在调用前置位，
   *   finally 中复位，保证调用栈内任何重入都被拦截。
   */
  private applying: boolean = false;

  private constructor() {}

  static getInstance(): ThemeManager {
    if (!ThemeManager.instance) {
      ThemeManager.instance = new ThemeManager();
    }
    return ThemeManager.instance;
  }

  /** v2.7.0：注入应用上下文（UIAbility.onCreate 最早调用） */
  initWithContext(ctx: common.Context): void {
    try {
      this.appCtx = ctx.getApplicationContext();
      Logger.info('ThemeManager', '已注入 ApplicationContext');
    } catch (e) {
      Logger.error('ThemeManager', '注入 ApplicationContext 失败: ' + JSON.stringify(e));
    }
  }

  /** v2.7.0：返回偏好加载完成信号（可能为 null，表示尚未发起加载） */
  whenLoaded(): Promise<void> | null {
    return this.loadPromise;
  }

  isLoaded(): boolean {
    return this.loaded;
  }
  
  /**
   * 获取当前是否为暗色模式
   */
  isDarkMode(): boolean {
    if (this.config.mode === ThemeMode.SYSTEM) {
      return this.config.isSystemDark;
    }
    return this.config.mode === ThemeMode.DARK;
  }
  
  /**
   * 获取画布纸张颜色
   */
  getCanvasPaperColor(): string {
    const isDark = this.isDarkMode();
    
    // 如果是暗色模式且用户未特别指定纸张
    if (isDark && this.config.canvasPaper === CanvasPaperStyle.LIGHT) {
      return '#1A1A1A';  // 暗色模式下默认使用深色纸张
    }
    
    switch (this.config.canvasPaper) {
      case CanvasPaperStyle.LIGHT:
        return '#FFFFFF';
      case CanvasPaperStyle.DARK:
        return '#1A1A1A';
      case CanvasPaperStyle.DARK_ALT:
        return '#252525';
      case CanvasPaperStyle.WARM:
        return '#FFF8E7';  // 护眼暖色
      case CanvasPaperStyle.SEPIA:
        return '#F4ECD8';  // 复古褐色
      default:
        return '#FFFFFF';
    }
  }
  
  /**
   * 获取画布纸张网格线颜色
   */
  getCanvasGridColor(): string {
    const isDark = this.isDarkMode();
    
    if (isDark) {
      return '#333333';  // 暗色模式下的网格线
    }
    
    return '#E5E5E5';  // 浅色模式下的网格线
  }
  
  /**
   * 设置主题模式
   *
   * 🔧 v2.6.0 审核修复（问题②-1 真因）：
   *   之前只改内部 config + notifyListeners，**从未调用应用级 setColorMode**。
   *   而全项目 600+ 处 HCColor.* 均为 `$r('app.color.hc_xxx')` Resource 引用，
   *   ArkUI 只按【系统】colorMode 解析 base/dark 资源 —— 所以用户在「主题设置」里
   *   选「浅色 / 深色」后，主页面深浅仍然跟随系统。审核员实测即为此现象。
   *   现在同步下发应用级颜色模式：浅色→LIGHT，深色→DARK，跟随系统→NOT_SET。
   */
  setThemeMode(mode: ThemeMode): void {
    this.config.mode = mode;
    this.applyColorMode();
    this.notifyListeners();
    // v2.7.0：切换即落盘（不再依赖调用方额外调 saveToPreferences），
    //   避免"应用内生效但重启丢失"。
    this.saveToPreferences().catch((err: Error): void => {
      Logger.error('ThemeManager', '保存主题模式失败: ' + err.message);
    });
  }

  /**
   * 应用应用级颜色模式（ApplicationContext.setColorMode）。
   * 这是让「主题模式」真正作用于全应用（含所有 Resource 颜色）的唯一途径。
   *
   * ══════════════════════════════════════════════════════════════════════
   * 🔴 v2.7.1 崩溃修复（问题②「JsCrash: RangeError - Stack overflow」）
   *
   * 真因（v2.7.0 引入的死循环）：
   *   `ApplicationContext.setColorMode()` 会在**调用栈内部同步回调**
   *   UIAbility.onConfigurationUpdate()，而该回调里调用了 `reapplyIfExplicit()`
   *   → `applyColorMode()` → `setColorMode()` → … 无限递归 → 栈溢出崩溃。
   *
   *   原写的 `lastApplied` 防重入为何失效：
   *     target.setColorMode(colorMode);       // ← 在这行【内部】就同步递归回去了
   *     this.lastApplied = `${colorMode}`;    // ← 这行永远晚一步，守卫形同虚设
   *
   * 修法（三重防护，缺一不可）：
   *   ① **先记账再下发**：把 lastApplied / applying 都在调用 setColorMode **之前**置好；
   *   ② **applying 重入闸门**：重入时直接 return，不做任何事；
   *   ③ **配置回调不再触发重下发**：从 onConfigurationUpdate 中移除 reapplyIfExplicit 调用
   *      （应用级颜色模式本身是粘性的，系统不会冲掉它，重下发既无必要又危险）。
   * ══════════════════════════════════════════════════════════════════════
   */
  applyColorMode(): void {
    // ② 重入闸门：任何路径的重入都直接返回，绝不进入 setColorMode 调用栈
    if (this.applying) {
      Logger.warn('ThemeManager', 'applyColorMode 重入被拦截（防止 setColorMode 递归）');
      return;
    }

    let colorMode: ConfigurationConstant.ColorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (this.config.mode === ThemeMode.LIGHT) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (this.config.mode === ThemeMode.DARK) {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    const key: string = `${colorMode}`;

    // 同值短路（放在闸门判定之后，避免误判"正在应用"为"已完成"）
    if (this.lastApplied === key) {
      return;
    }

    try {
      let target: common.ApplicationContext | null = this.appCtx;
      if (target === null) {
        try {
          const ctx: common.Context = getContext(this) as common.Context;
          target = ctx.getApplicationContext();
          this.appCtx = target;
        } catch (e) {
          Logger.error('ThemeManager', 'getContext 回退失败: ' + JSON.stringify(e));
        }
      }
      if (target === null) {
        Logger.error('ThemeManager', '无可用 ApplicationContext，颜色模式未下发');
        return;
      }

      // ① 先记账 + 开闸门，**然后**才调用（setColorMode 会同步回调 onConfigurationUpdate）
      this.lastApplied = key;
      this.applying = true;
      try {
        target.setColorMode(colorMode);
      } finally {
        this.applying = false;
      }
      Logger.info('ThemeManager', `应用级颜色模式已下发: mode=${this.config.mode} → ${key}`);
    } catch (error) {
      // 下发失败则回滚记账，允许下次重试
      this.lastApplied = '';
      this.applying = false;
      Logger.error('ThemeManager', 'setColorMode 下发失败: ' + JSON.stringify(error));
    }
  }

  /**
   * v2.7.1：保留方法以兼容既有调用点，但**不再主动重下发**。
   *   原实现会在系统配置变化时再次调用 applyColorMode，而 setColorMode 会同步触发
   *   onConfigurationUpdate → 又回到这里 → 栈溢出崩溃（见 applyColorMode 注释）。
   *   应用级颜色模式是粘性的，系统配置变化不会冲掉它，因此无需重下发。
   */
  reapplyIfExplicit(): void {
    // 有意留空：防重入由 applyColorMode 的 applying 闸门统一兜底。
    // 若将来确需在配置变化后纠正主题，请仅在**非 setColorMode 调用栈内**执行，
    // 例如用 setTimeout(…, 0) 让出当前栈后再调用 applyColorMode。
  }
  
  /**
   * 设置画布纸张样式
   */
  setCanvasPaper(paper: CanvasPaperStyle): void {
    this.config.canvasPaper = paper;
    this.notifyListeners();
  }
  
  /**
   * 设置主题皮肤（U-05）
   * v2.5.2 审核修复：同步写入 AppStorage，让其他页面打开时能读到当前皮肤。
   */
  setSkin(skin: string): void {
    this.config.skin = skin;
    // 同步到 AppStorage，让其他页面 onPageShow 时能即时读取（修复"修改皮肤无效果"）
    try {
      AppStorage.setOrCreate<string>('app_skin', skin);
    } catch (_e) { /* AppStorage 在 UIAbility 上下文外可能不可用 */ }
    this.notifyListeners();
  }
  
  /**
   * 获取当前主题皮肤
   */
  getSkin(): string {
    return this.config.skin;
  }
  
  /**
   * 更新系统主题状态（由 EntryAbility 调用）
   */
  updateSystemTheme(isDark: boolean): void {
    const oldIsDark = this.isDarkMode();
    this.config.isSystemDark = isDark;
    
    // 只有实际暗色状态变化时才通知
    if (oldIsDark !== this.isDarkMode()) {
      this.notifyListeners();
    }
  }
  
  /**
   * 从 ConfigurationConstant 转换
   */
  updateFromConfiguration(colorMode: ConfigurationConstant.ColorMode): void {
    const isDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    this.updateSystemTheme(isDark);
  }
  
  /**
   * 获取当前配置
   */
  getConfig(): ThemeConfig {
    // ArkTS不支持对象展开运算符，手动复制属性
    return {
      mode: this.config.mode,
      canvasPaper: this.config.canvasPaper,
      isSystemDark: this.config.isSystemDark,
      skin: this.config.skin
    };
  }
  
  /**
   * 添加主题变更监听器
   */
  addListener(listener: (config: ThemeConfig) => void): void {
    this.listeners.push(listener);
  }
  
  /**
   * 移除主题变更监听器
   */
  removeListener(listener: (config: ThemeConfig) => void): void {
    const index = this.listeners.indexOf(listener);
    if (index !== -1) {
      this.listeners.splice(index, 1);
    }
  }
  
  /**
   * 通知所有监听器
   */
  private notifyListeners(): void {
    const config = this.getConfig();
    this.listeners.forEach(listener => {
      listener(config);
    });
  }
  
  /**
   * 持久化主题设置（保存到 Preferences）
   */
  async saveToPreferences(): Promise<void> {
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, 'theme_settings');
      await pref.put('theme_mode', this.config.mode);
      await pref.put('theme_canvas_paper', this.config.canvasPaper);
      await pref.put('theme_skin', this.config.skin);
      await pref.flush();
    } catch (error) {
      Logger.error('ThemeManager', 'Failed to save theme: ' + JSON.stringify(error));
    }
  }
  
  /**
   * 加载用户主题偏好
   * v2.5.2 审核修复：同步到 AppStorage
   */
  /**
   * 加载用户主题偏好（幂等，并记录 Promise 供启动流程 await）。
   * v2.7.0：新增 loaded 标记与 loadPromise —— 让 EntryAbility 能在
   * 「加载页面内容之前」先等主题确定，避免首帧用系统主题、之后才纠正。
   */
  async loadFromPreferences(): Promise<void> {
    if (this.loadPromise !== null) {
      return this.loadPromise;
    }
    this.loadPromise = this.doLoadFromPreferences();
    return this.loadPromise;
  }

  private async doLoadFromPreferences(): Promise<void> {
    try {
      const ctx = getContext(this);
      const pref = await preferences.getPreferences(ctx, 'theme_settings');
      const mode: string = await pref.get('theme_mode', ThemeMode.SYSTEM) as string;
      const canvasPaper: string = await pref.get('theme_canvas_paper', CanvasPaperStyle.LIGHT) as string;
      const skin: string = await pref.get('theme_skin', 'classic') as string;
      this.config.mode = mode as ThemeMode;
      this.config.canvasPaper = canvasPaper as CanvasPaperStyle;
      this.config.skin = skin;
      this.loaded = true;
      // 🔧 v2.6.0/v2.7.0：启动即下发应用级颜色模式，避免冷启动后「主题模式」设置丢失。
      this.applyColorMode();
      // 同步到 AppStorage，让其他页面 onPageShow 时能即时读取
      try {
        AppStorage.setOrCreate<string>('app_skin', skin);
      } catch (_e) { /* AppStorage 在 UIAbility 上下文外可能不可用 */ }
      Logger.info('ThemeManager', `Loaded theme: mode=${mode}, paper=${canvasPaper}, skin=${skin}`);
    } catch (error) {
      this.loaded = true;
      Logger.error('ThemeManager', 'Failed to load theme: ' + JSON.stringify(error));
    }
  }
}

// 导出单例便捷方法
export const themeManager = ThemeManager.getInstance();
