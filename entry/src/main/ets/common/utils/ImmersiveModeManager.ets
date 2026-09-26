/**
 * ImmersiveModeManager.ets - 沉浸模式管理器（F-03 编辑器沉浸模式）
 * 
 * 功能：
 * 1. 书写开始后自动淡出工具栏（1.5s延迟）
 * 2. 点击空白唤回工具栏
 * 3. 手动收起/展开开关
 * 4. 记住用户偏好
 */

import { Logger } from '../Logger';

export enum ImmersiveMode {
  NORMAL = 'normal',      // 正常模式：工具栏常驻
  AUTO_HIDE = 'auto_hide', // 自动隐藏模式：书写时自动隐藏
  ALWAYS_HIDE = 'always_hide' // 始终隐藏模式：手动隐藏
}
export interface ImmersiveConfig {
  mode: ImmersiveMode;
  autoHideDelay: number;  // 自动隐藏延迟（毫秒）
  toolbarVisible: boolean;
  headerVisible: boolean;
}

export class ImmersiveModeManager {
  private static instance: ImmersiveModeManager;
  
  // 当前配置
  private config: ImmersiveConfig = {
    mode: ImmersiveMode.AUTO_HIDE,
    autoHideDelay: 1500,  // 默认1.5秒
    toolbarVisible: true,
    headerVisible: true
  };
  
  // 状态变更回调
  private listeners: Array<(config: ImmersiveConfig) => void> = [];
  
  // 自动隐藏定时器
  private autoHideTimer: number = -1;
  
  // 最后一次触摸时间
  private lastTouchTime: number = 0;
  
  // 是否正在书写
  private isDrawing: boolean = false;
  
  private constructor() {}
  
  static getInstance(): ImmersiveModeManager {
    if (!ImmersiveModeManager.instance) {
      ImmersiveModeManager.instance = new ImmersiveModeManager();
    }
    return ImmersiveModeManager.instance;
  }
  
  /**
   * 获取当前配置
   */
  getConfig(): ImmersiveConfig {
    // ArkTS不支持对象展开运算符，手动复制属性
    return {
      mode: this.config.mode,
      autoHideDelay: this.config.autoHideDelay,
      toolbarVisible: this.config.toolbarVisible,
      headerVisible: this.config.headerVisible
    };
  }
  
  /**
   * 设置沉浸模式
   */
  setMode(mode: ImmersiveMode): void {
    this.config.mode = mode;
    
    // 根据模式更新可见性
    if (mode === ImmersiveMode.ALWAYS_HIDE) {
      this.config.toolbarVisible = false;
      this.config.headerVisible = false;
    } else if (mode === ImmersiveMode.NORMAL) {
      this.config.toolbarVisible = true;
      this.config.headerVisible = true;
    }
    
    this.notifyListeners();
  }
  
  /**
   * 手动切换工具栏可见性
   */
  toggleToolbar(): void {
    this.config.toolbarVisible = !this.config.toolbarVisible;
    this.config.headerVisible = this.config.toolbarVisible;
    this.notifyListeners();
  }
  
  /**
   * 显示工具栏（点击空白时调用）
   */
  showToolbar(): void {
    if (!this.config.toolbarVisible) {
      this.config.toolbarVisible = true;
      this.config.headerVisible = true;
      this.notifyListeners();
    }
    
    // 如果是自动隐藏模式，重新启动定时器
    if (this.config.mode === ImmersiveMode.AUTO_HIDE) {
      this.startAutoHideTimer();
    }
  }
  
  /**
   * 隐藏工具栏
   */
  hideToolbar(): void {
    if (this.config.toolbarVisible) {
      this.config.toolbarVisible = false;
      this.config.headerVisible = false;
      this.notifyListeners();
    }
  }
  
  /**
   * 触摸开始（书写开始）
   */
  onTouchStart(): void {
    this.isDrawing = true;
    this.lastTouchTime = Date.now();
    
    // 如果是自动隐藏模式，启动定时器
    if (this.config.mode === ImmersiveMode.AUTO_HIDE) {
      this.startAutoHideTimer();
    }
  }
  
  /**
   * 触摸结束（书写结束）
   */
  onTouchEnd(): void {
    this.isDrawing = false;
  }
  
  /**
   * 启动自动隐藏定时器
   */
  private startAutoHideTimer(): void {
    // 清除之前的定时器
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
    }
    
    // 设置新的定时器
    this.autoHideTimer = setTimeout(() => {
      // 如果仍在书写，隐藏工具栏
      if (this.isDrawing || (Date.now() - this.lastTouchTime < this.config.autoHideDelay)) {
        this.hideToolbar();
      }
      this.autoHideTimer = -1;
    }, this.config.autoHideDelay);
  }
  
  /**
   * 添加配置变更监听器
   */
  addListener(listener: (config: ImmersiveConfig) => void): void {
    this.listeners.push(listener);
  }
  
  /**
   * 移除配置变更监听器
   */
  removeListener(listener: (config: ImmersiveConfig) => void): void {
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
   * 保存配置到 Preferences
   */
  async saveToPreferences(): Promise<void> {
    try {
      // TODO: 实现 Preferences 存储
    } catch (error) {
      Logger.error('ImmersiveModeManager', 'Failed to save config: ' + JSON.stringify(error));
    }
  }
  
  /**
   * 从 Preferences 加载配置
   */
  async loadFromPreferences(): Promise<void> {
    try {
      // TODO: 实现 Preferences 加载
    } catch (error) {
      Logger.error('ImmersiveModeManager', 'Failed to load config: ' + JSON.stringify(error));
    }
  }
}

// 导出单例便捷方法
export const immersiveModeManager = ImmersiveModeManager.getInstance();
