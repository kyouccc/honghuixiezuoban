/**
 * 用户偏好服务
 * 持久化用户的工具选择、颜色、线宽、暗色模式等偏好
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { analytics } from './AnalyticsService';

const TAG = 'UserPreferences';
const DOMAIN = 0x0000;

export interface UserPreferences {
  // 工具偏好
  defaultTool: 'pen' | 'eraser' | 'shape';
  defaultColor: string;
  defaultWidth: number;
  defaultShape: 'rectangle' | 'circle' | 'arrow' | 'line';
  
  // 界面偏好
  darkMode: boolean;
  showGrid: boolean;
  autoSave: boolean;
  
  // 协作偏好
  autoJoinRoom: boolean;
  lastRoomId: string;
  
  // 高级偏好
  pressureSensitivity: number; // 0-1
  palmRejection: boolean;
  smoothStroke: boolean;

  // 隐私偏好：埋点采集总开关（用户可随时关闭）
  analyticsEnabled: boolean;
}

export interface PreferencesTrackProps extends Record<string, string | number | boolean> {
  changes: string;
  old_values: string;
  new_values: string;
}

const DEFAULT_PREFERENCES: UserPreferences = {
  defaultTool: 'pen',
  defaultColor: '#000000',
  defaultWidth: 3,
  defaultShape: 'rectangle',
  darkMode: false,
  showGrid: false,
  autoSave: true,
  autoJoinRoom: false,
  lastRoomId: '',
  pressureSensitivity: 0.8,
  palmRejection: true,
  smoothStroke: true,
  // 说明：真正的"未同意不采集"由 PrivacyConsentService 门禁保证，
  // 本开关是同意之后的 opt-out 选项，故默认打开（与 AnalyticsService 常量保持一致）
  analyticsEnabled: true
};

export class UserPreferencesService {
  private static instance: UserPreferencesService;
  private context: common.UIAbilityContext | null = null;
  private preferences: UserPreferences = {
    defaultTool: DEFAULT_PREFERENCES.defaultTool,
    defaultColor: DEFAULT_PREFERENCES.defaultColor,
    defaultWidth: DEFAULT_PREFERENCES.defaultWidth,
    defaultShape: DEFAULT_PREFERENCES.defaultShape,
    darkMode: DEFAULT_PREFERENCES.darkMode,
    showGrid: DEFAULT_PREFERENCES.showGrid,
    autoSave: DEFAULT_PREFERENCES.autoSave,
    autoJoinRoom: DEFAULT_PREFERENCES.autoJoinRoom,
    lastRoomId: DEFAULT_PREFERENCES.lastRoomId,
    pressureSensitivity: DEFAULT_PREFERENCES.pressureSensitivity,
    palmRejection: DEFAULT_PREFERENCES.palmRejection,
    smoothStroke: DEFAULT_PREFERENCES.smoothStroke,
    analyticsEnabled: DEFAULT_PREFERENCES.analyticsEnabled
  };
  private isLoaded: boolean = false;

  private constructor() {}

  static getInstance(): UserPreferencesService {
    if (!UserPreferencesService.instance) {
      UserPreferencesService.instance = new UserPreferencesService();
    }
    return UserPreferencesService.instance;
  }

  /**
   * 初始化服务
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    await this.load();
    hilog.info(DOMAIN, TAG, 'UserPreferencesService initialized');
  }

  /**
   * 从本地存储加载偏好
   */
  private async load(): Promise<void> {
    if (!this.context) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'user_preferences');
      
      // 加载各项偏好
      this.preferences.defaultTool = await prefs.get('defaultTool', DEFAULT_PREFERENCES.defaultTool) as 'pen' | 'eraser' | 'shape';
      this.preferences.defaultColor = await prefs.get('defaultColor', DEFAULT_PREFERENCES.defaultColor) as string;
      this.preferences.defaultWidth = await prefs.get('defaultWidth', DEFAULT_PREFERENCES.defaultWidth) as number;
      this.preferences.defaultShape = await prefs.get('defaultShape', DEFAULT_PREFERENCES.defaultShape) as 'rectangle' | 'circle' | 'arrow' | 'line';
      
      this.preferences.darkMode = await prefs.get('darkMode', DEFAULT_PREFERENCES.darkMode) as boolean;
      this.preferences.showGrid = await prefs.get('showGrid', DEFAULT_PREFERENCES.showGrid) as boolean;
      this.preferences.autoSave = await prefs.get('autoSave', DEFAULT_PREFERENCES.autoSave) as boolean;
      
      this.preferences.autoJoinRoom = await prefs.get('autoJoinRoom', DEFAULT_PREFERENCES.autoJoinRoom) as boolean;
      this.preferences.lastRoomId = await prefs.get('lastRoomId', DEFAULT_PREFERENCES.lastRoomId) as string;
      
      this.preferences.pressureSensitivity = await prefs.get('pressureSensitivity', DEFAULT_PREFERENCES.pressureSensitivity) as number;
      this.preferences.palmRejection = await prefs.get('palmRejection', DEFAULT_PREFERENCES.palmRejection) as boolean;
      this.preferences.smoothStroke = await prefs.get('smoothStroke', DEFAULT_PREFERENCES.smoothStroke) as boolean;

      this.preferences.analyticsEnabled =
        await prefs.get('analyticsEnabled', DEFAULT_PREFERENCES.analyticsEnabled) as boolean;
      // 把开关推给埋点服务（单向依赖，避免与 AnalyticsService 形成循环 import）
      analytics.setAnalyticsEnabled(this.preferences.analyticsEnabled);
      
      this.isLoaded = true;
      hilog.info(DOMAIN, TAG, 'Preferences loaded');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to load preferences: ${JSON.stringify(error)}`);
      this.preferences = {
        defaultTool: DEFAULT_PREFERENCES.defaultTool,
        defaultColor: DEFAULT_PREFERENCES.defaultColor,
        defaultWidth: DEFAULT_PREFERENCES.defaultWidth,
        defaultShape: DEFAULT_PREFERENCES.defaultShape,
        darkMode: DEFAULT_PREFERENCES.darkMode,
        showGrid: DEFAULT_PREFERENCES.showGrid,
        autoSave: DEFAULT_PREFERENCES.autoSave,
        autoJoinRoom: DEFAULT_PREFERENCES.autoJoinRoom,
        lastRoomId: DEFAULT_PREFERENCES.lastRoomId,
        pressureSensitivity: DEFAULT_PREFERENCES.pressureSensitivity,
        palmRejection: DEFAULT_PREFERENCES.palmRejection,
        smoothStroke: DEFAULT_PREFERENCES.smoothStroke,
        analyticsEnabled: DEFAULT_PREFERENCES.analyticsEnabled
      };
    }
  }

  /**
   * 保存偏好到本地存储
   */
  private async save(): Promise<void> {
    if (!this.context) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'user_preferences');
      
      await prefs.put('defaultTool', this.preferences.defaultTool);
      await prefs.put('defaultColor', this.preferences.defaultColor);
      await prefs.put('defaultWidth', this.preferences.defaultWidth);
      await prefs.put('defaultShape', this.preferences.defaultShape);
      
      await prefs.put('darkMode', this.preferences.darkMode);
      await prefs.put('showGrid', this.preferences.showGrid);
      await prefs.put('autoSave', this.preferences.autoSave);
      
      await prefs.put('autoJoinRoom', this.preferences.autoJoinRoom);
      await prefs.put('lastRoomId', this.preferences.lastRoomId);
      
      await prefs.put('pressureSensitivity', this.preferences.pressureSensitivity);
      await prefs.put('palmRejection', this.preferences.palmRejection);
      await prefs.put('smoothStroke', this.preferences.smoothStroke);

      await prefs.put('analyticsEnabled', this.preferences.analyticsEnabled);
      
      await prefs.flush();
      hilog.debug(DOMAIN, TAG, 'Preferences saved');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to save preferences: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 获取所有偏好
   */
  getPreferences(): UserPreferences {
    return {
      defaultTool: this.preferences.defaultTool,
      defaultColor: this.preferences.defaultColor,
      defaultWidth: this.preferences.defaultWidth,
      defaultShape: this.preferences.defaultShape,
      darkMode: this.preferences.darkMode,
      showGrid: this.preferences.showGrid,
      autoSave: this.preferences.autoSave,
      autoJoinRoom: this.preferences.autoJoinRoom,
      lastRoomId: this.preferences.lastRoomId,
      pressureSensitivity: this.preferences.pressureSensitivity,
      palmRejection: this.preferences.palmRejection,
      smoothStroke: this.preferences.smoothStroke,
      analyticsEnabled: this.preferences.analyticsEnabled
    };
  }

  /**
   * 更新偏好
   */
  async updatePreferences(updates: Partial<UserPreferences>): Promise<void> {
    // 记录旧值用于埋点
    const oldValues: Record<string, string | number | boolean> = {};
    
    // 更新各个属性
    if (updates.defaultTool !== undefined) {
      oldValues['defaultTool'] = this.preferences.defaultTool;
      this.preferences.defaultTool = updates.defaultTool;
    }
    if (updates.defaultColor !== undefined) {
      oldValues['defaultColor'] = this.preferences.defaultColor;
      this.preferences.defaultColor = updates.defaultColor;
    }
    if (updates.defaultWidth !== undefined) {
      oldValues['defaultWidth'] = this.preferences.defaultWidth;
      this.preferences.defaultWidth = updates.defaultWidth;
    }
    if (updates.defaultShape !== undefined) {
      oldValues['defaultShape'] = this.preferences.defaultShape;
      this.preferences.defaultShape = updates.defaultShape;
    }
    if (updates.darkMode !== undefined) {
      oldValues['darkMode'] = this.preferences.darkMode;
      this.preferences.darkMode = updates.darkMode;
    }
    if (updates.showGrid !== undefined) {
      oldValues['showGrid'] = this.preferences.showGrid;
      this.preferences.showGrid = updates.showGrid;
    }
    if (updates.autoSave !== undefined) {
      oldValues['autoSave'] = this.preferences.autoSave;
      this.preferences.autoSave = updates.autoSave;
    }
    if (updates.autoJoinRoom !== undefined) {
      oldValues['autoJoinRoom'] = this.preferences.autoJoinRoom;
      this.preferences.autoJoinRoom = updates.autoJoinRoom;
    }
    if (updates.lastRoomId !== undefined) {
      oldValues['lastRoomId'] = this.preferences.lastRoomId;
      this.preferences.lastRoomId = updates.lastRoomId;
    }
    if (updates.pressureSensitivity !== undefined) {
      oldValues['pressureSensitivity'] = this.preferences.pressureSensitivity;
      this.preferences.pressureSensitivity = updates.pressureSensitivity;
    }
    if (updates.palmRejection !== undefined) {
      oldValues['palmRejection'] = this.preferences.palmRejection;
      this.preferences.palmRejection = updates.palmRejection;
    }
    if (updates.smoothStroke !== undefined) {
      oldValues['smoothStroke'] = this.preferences.smoothStroke;
      this.preferences.smoothStroke = updates.smoothStroke;
    }
    if (updates.analyticsEnabled !== undefined) {
      oldValues['analyticsEnabled'] = this.preferences.analyticsEnabled;
      this.preferences.analyticsEnabled = updates.analyticsEnabled;
      // 先推给埋点服务再落盘：关闭时下面那条 preferences_updated 埋点会被门禁挡掉，
      // 保证"用户点了关闭"这个动作本身也不会被采集。
      analytics.setAnalyticsEnabled(updates.analyticsEnabled);
    }
    
    // 保存
    await this.save();
    
    // 记录埋点
    const trackProps: PreferencesTrackProps = {
      changes: Object.keys(updates).join(','),
      old_values: JSON.stringify(oldValues),
      new_values: JSON.stringify(updates)
    };
    analytics.track('preferences_updated', trackProps);
    
    hilog.info(DOMAIN, TAG, `Preferences updated: ${Object.keys(updates).join(', ')}`);
  }

  /**
   * 设置默认工具
   */
  async setDefaultTool(tool: 'pen' | 'eraser' | 'shape'): Promise<void> {
    await this.updatePreferences({ defaultTool: tool });
  }

  /**
   * 设置默认颜色
   */
  async setDefaultColor(color: string): Promise<void> {
    await this.updatePreferences({ defaultColor: color });
  }

  /**
   * 设置默认线宽
   */
  async setDefaultWidth(width: number): Promise<void> {
    await this.updatePreferences({ defaultWidth: width });
  }

  /**
   * 设置默认形状
   */
  async setDefaultShape(shape: 'rectangle' | 'circle' | 'arrow' | 'line'): Promise<void> {
    await this.updatePreferences({ defaultShape: shape });
  }

  /**
   * 设置暗色模式
   */
  async setDarkMode(enabled: boolean): Promise<void> {
    await this.updatePreferences({ darkMode: enabled });
    
    // 更新 AppStorage
    AppStorage.setOrCreate<boolean>('darkMode', enabled);
  }

  /**
   * 设置显示网格
   */
  async setShowGrid(show: boolean): Promise<void> {
    await this.updatePreferences({ showGrid: show });
  }

  /**
   * 设置上次房间 ID
   */
  async setLastRoomId(roomId: string): Promise<void> {
    await this.updatePreferences({ lastRoomId: roomId });
  }

  /**
   * 设置埋点采集开关（隐私设置项）
   */
  async setAnalyticsEnabled(enabled: boolean): Promise<void> {
    await this.updatePreferences({ analyticsEnabled: enabled });
  }

  /**
   * 当前埋点采集开关
   */
  isAnalyticsEnabled(): boolean {
    return this.preferences.analyticsEnabled;
  }

  /**
   * 重置为默认值
   */
  async reset(): Promise<void> {
    this.preferences = {
      defaultTool: DEFAULT_PREFERENCES.defaultTool,
      defaultColor: DEFAULT_PREFERENCES.defaultColor,
      defaultWidth: DEFAULT_PREFERENCES.defaultWidth,
      defaultShape: DEFAULT_PREFERENCES.defaultShape,
      darkMode: DEFAULT_PREFERENCES.darkMode,
      showGrid: DEFAULT_PREFERENCES.showGrid,
      autoSave: DEFAULT_PREFERENCES.autoSave,
      autoJoinRoom: DEFAULT_PREFERENCES.autoJoinRoom,
      lastRoomId: DEFAULT_PREFERENCES.lastRoomId,
      pressureSensitivity: DEFAULT_PREFERENCES.pressureSensitivity,
      palmRejection: DEFAULT_PREFERENCES.palmRejection,
      smoothStroke: DEFAULT_PREFERENCES.smoothStroke,
      analyticsEnabled: DEFAULT_PREFERENCES.analyticsEnabled
    };
    await this.save();
    analytics.setAnalyticsEnabled(this.preferences.analyticsEnabled);
    
    analytics.track('preferences_reset');
    hilog.info(DOMAIN, TAG, 'Preferences reset to defaults');
  }

  /**
   * 导出偏好（用于备份）
   */
  exportPreferences(): string {
    return JSON.stringify(this.preferences);
  }

  /**
   * 导入偏好（用于恢复）
   */
  async importPreferences(json: string): Promise<boolean> {
    try {
      const imported = JSON.parse(json) as Partial<UserPreferences>;
      await this.updatePreferences(imported);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to import preferences: ${JSON.stringify(error)}`);
      return false;
    }
  }
}

// 导出单例
export const userPreferences = UserPreferencesService.getInstance();
