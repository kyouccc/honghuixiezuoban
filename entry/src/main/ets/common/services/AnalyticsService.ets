/**
 * 埋点分析服务
 * 用于收集用户行为数据，支持产品优化和用户留存分析
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { privacyConsentService } from './PrivacyConsentService';

const TAG = 'AnalyticsService';
const DOMAIN = 0x0000;

/** 设备标识独立存储，避免与事件队列混在一个 preferences 文件里 */
const DEVICE_PREFS_NAME = 'analytics_profile';
const DEVICE_ID_KEY = 'device_id';

/** 埋点开关存放在用户偏好里，键名与 UserPreferences 保持一致 */
const USER_PREFS_NAME = 'user_preferences';
const ANALYTICS_ENABLED_KEY = 'analyticsEnabled';

/**
 * 埋点开关默认值。
 * 语义说明：真正的"未同意不收集"由隐私同意门禁（privacyConsentService）保证；
 * 本开关是用户在**已同意之后**的二次退出（opt-out）选项，故默认为 true。
 * 二者相与后的实际默认表现 = 未同意时不收集，与 PrivacyConsentService 语义一致。
 * 若产品口径要求"同意后也默认不收集"，只需把这一个常量改成 false。
 */
const DEFAULT_ANALYTICS_ENABLED = true;

export enum AnalyticsEvent {
  // 页面访问
  PAGE_VIEW = 'page_view',
  PAGE_EXIT = 'page_exit',
  
  // 工具操作
  TOOL_SWITCH = 'tool_switch',
  COLOR_CHANGE = 'color_change',
  STROKE_WIDTH_CHANGE = 'stroke_width_change',
  
  // 绘制操作
  STROKE_START = 'stroke_start',
  STROKE_END = 'stroke_end',
  SHAPE_CREATE = 'shape_create',
  ERASE_ACTION = 'erase_action',
  
  // 编辑操作
  UNDO = 'undo',
  REDO = 'redo',
  CLEAR_CANVAS = 'clear_canvas',
  
  // 导出操作
  EXPORT_IMAGE = 'export_image',
  EXPORT_SVG = 'export_svg',
  EXPORT_PDF = 'export_pdf',
  
  // 协作操作
  ROOM_JOIN = 'room_join',
  ROOM_LEAVE = 'room_leave',
  ROOM_CREATE = 'room_create',
  NFC_JOIN = 'nfc_join',
  
  // 设备管理
  DEVICE_DISCOVER = 'device_discover',
  DEVICE_CONNECT = 'device_connect',
  ROLE_ASSIGN = 'role_assign',
  
  // AI 功能
  AI_SKETCH_RECOGNIZE = 'ai_sketch_recognize',
  AI_OCR = 'ai_ocr',
  
  // 用户反馈
  FEEDBACK_SUBMIT = 'feedback_submit',
  RATING_SUBMIT = 'rating_submit',
  
  // 错误
  ERROR_OCCURRED = 'error_occurred',
  CRASH_OCCURRED = 'crash_occurred'
}

export interface AnalyticsEventData {
  event: AnalyticsEvent | string;
  timestamp: number;
  properties?: object;
  userId?: string;
  deviceId?: string;
  sessionId: string;
}

export interface EventStats {
  total: number;
  byType: Record<string, number>;
}

export interface AnalyticsProps {
  page_name?: string;
  duration_ms?: number;
  from_tool?: string;
  to_tool?: string;
  error_type?: string;
  error_message?: string;
  stack_trace?: string;
}

export class AnalyticsService {
  private static instance: AnalyticsService;
  private context: common.UIAbilityContext | null = null;
  private eventQueue: AnalyticsEventData[] = [];
  private sessionId: string = '';
  private userId: string = '';
  private deviceId: string = '';
  private isInitialized: boolean = false;
  private flushInterval: number = 30000; // 30秒
  private maxQueueSize: number = 100;
  private timer: number = -1;
  /** 埋点总开关（用户可关闭）；与隐私同意状态相与后才允许采集 */
  private analyticsEnabled: boolean = DEFAULT_ANALYTICS_ENABLED;

  private constructor() {
    this.sessionId = this.generateSessionId();
  }

  static getInstance(): AnalyticsService {
    if (!AnalyticsService.instance) {
      AnalyticsService.instance = new AnalyticsService();
    }
    return AnalyticsService.instance;
  }

  /**
   * 初始化埋点服务
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.isInitialized) return;
    
    this.context = context;

    // 隐私同意门禁：注入 context（幂等）并预热同意状态缓存，
    // 之后 track() 直接读 isConsentAccepted() 同步判断，不阻塞调用方。
    privacyConsentService.init(context);
    await privacyConsentService.checkConsent();

    // 埋点开关（用户偏好，持久化）
    this.analyticsEnabled = await this.loadAnalyticsEnabled();

    // 安装级设备标识：首次生成随机 UUID 后落盘复用，不含任何设备硬件信息
    this.deviceId = await this.loadOrCreateDeviceId();
    this.userId = AppStorage.get<string>('userId') || '';
    
    // 启动定时刷新
    this.startFlushTimer();
    
    // 加载未上传的事件
    await this.loadPendingEvents();
    
    this.isInitialized = true;
    hilog.info(DOMAIN, TAG,
      `AnalyticsService initialized, sessionId: ${this.sessionId}, enabled: ${this.analyticsEnabled}`);
  }

  /**
   * 生成会话 ID
   */
  private generateSessionId(): string {
    return `session_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
  }

  /**
   * 生成设备 ID（安装级随机 UUID）。
   * 用 util.generateRandomUUID 而非时间戳+随机数：不可反推安装时间，且不涉及任何设备指纹。
   */
  private generateDeviceId(): string {
    return `device_${util.generateRandomUUID(true)}`;
  }

  /**
   * 读取埋点开关；读取失败回落到默认值
   */
  private async loadAnalyticsEnabled(): Promise<boolean> {
    if (!this.context) {
      return DEFAULT_ANALYTICS_ENABLED;
    }
    try {
      const prefs = await preferences.getPreferences(this.context, USER_PREFS_NAME);
      return await prefs.get(ANALYTICS_ENABLED_KEY, DEFAULT_ANALYTICS_ENABLED) as boolean;
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to load analytics switch: ${JSON.stringify(error)}`);
      return DEFAULT_ANALYTICS_ENABLED;
    }
  }

  /**
   * 取安装级设备 ID：已有则复用，没有则生成一次并落盘。
   * 卸载重装会得到新 ID，这正是"安装级"的预期语义。
   */
  private async loadOrCreateDeviceId(): Promise<string> {
    if (!this.context) {
      return this.generateDeviceId();
    }
    try {
      const prefs = await preferences.getPreferences(this.context, DEVICE_PREFS_NAME);
      const saved = await prefs.get(DEVICE_ID_KEY, '') as string;
      if (saved.length > 0) {
        return saved;
      }
      const generated: string = this.generateDeviceId();
      await prefs.put(DEVICE_ID_KEY, generated);
      await prefs.flush();
      hilog.info(DOMAIN, TAG, 'Install-level device id generated');
      return generated;
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to load device id: ${JSON.stringify(error)}`);
      // 落盘失败时给一个内存态 ID，保证事件结构完整，不影响主流程
      return this.generateDeviceId();
    }
  }

  /**
   * 重置设备 ID（隐私诉求：用户可切断历史数据关联）。
   * 同时清空尚未落盘的事件队列，避免新旧 ID 混在同一批数据里。
   */
  async resetDeviceId(): Promise<string> {
    const next: string = this.generateDeviceId();
    this.deviceId = next;
    this.eventQueue = [];

    if (!this.context) {
      return next;
    }
    try {
      const prefs = await preferences.getPreferences(this.context, DEVICE_PREFS_NAME);
      await prefs.put(DEVICE_ID_KEY, next);
      await prefs.flush();
      hilog.info(DOMAIN, TAG, 'Device id reset');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to reset device id: ${JSON.stringify(error)}`);
    }
    return next;
  }

  /**
   * 获取当前设备 ID（供设置页/隐私页展示或调试）
   */
  getDeviceId(): string {
    return this.deviceId;
  }

  /**
   * 设置埋点开关。由 UserPreferencesService 在开关变更时推入，
   * 保持依赖单向（UserPreferences → Analytics），避免循环 import。
   * 关闭时立即丢弃内存中未落盘的事件。
   */
  setAnalyticsEnabled(enabled: boolean): void {
    this.analyticsEnabled = enabled;
    if (!enabled) {
      this.eventQueue = [];
    }
    hilog.info(DOMAIN, TAG, `Analytics switch set: ${enabled}`);
  }

  /**
   * 当前埋点开关状态
   */
  isAnalyticsEnabled(): boolean {
    return this.analyticsEnabled;
  }

  /**
   * 是否允许采集：必须「已同意隐私政策」且「埋点开关打开」。
   * 所有写入路径（track / flush）都要先过这道闸。
   */
  private isTrackingAllowed(): boolean {
    return privacyConsentService.isConsentAccepted() && this.analyticsEnabled;
  }

  /**
   * 设置用户 ID
   */
  setUserId(userId: string): void {
    this.userId = userId;
    hilog.info(DOMAIN, TAG, `User ID set: ${userId}`);
  }

  /**
   * 记录事件
   */
  track(event: AnalyticsEvent | string, properties?: object): void {
    if (!this.isInitialized) {
      hilog.warn(DOMAIN, TAG, 'AnalyticsService not initialized');
      return;
    }

    // 合规门禁：未同意隐私政策或用户已关闭埋点时，直接丢弃，不入队、不落盘
    if (!this.isTrackingAllowed()) {
      return;
    }

    const eventData: AnalyticsEventData = {
      event,
      timestamp: Date.now(),
      properties,
      userId: this.userId,
      deviceId: this.deviceId,
      sessionId: this.sessionId
    };

    this.eventQueue.push(eventData);
    hilog.debug(DOMAIN, TAG, `Event tracked: ${event}, queue size: ${this.eventQueue.length}`);

    // 队列达到最大值时立即刷新
    if (this.eventQueue.length >= this.maxQueueSize) {
      this.flush();
    }
  }

  /**
   * 记录页面访问
   */
  trackPageView(pageName: string, properties?: Record<string, string | number | boolean>): void {
    const props: AnalyticsProps = {
      page_name: pageName
    };
    if (properties && properties.duration_ms !== undefined) {
      props.duration_ms = properties.duration_ms as number;
    }
    this.track(AnalyticsEvent.PAGE_VIEW, props);
  }

  /**
   * 记录页面退出
   */
  trackPageExit(pageName: string, duration: number): void {
    const props: AnalyticsProps = {
      page_name: pageName,
      duration_ms: duration
    };
    this.track(AnalyticsEvent.PAGE_EXIT, props);
  }

  /**
   * 记录工具切换
   */
  trackToolSwitch(fromTool: string, toTool: string): void {
    const props: AnalyticsProps = {
      from_tool: fromTool,
      to_tool: toTool
    };
    this.track(AnalyticsEvent.TOOL_SWITCH, props);
  }

  /**
   * 记录绘制操作
   */
  trackDrawAction(action: string, properties?: Record<string, string | number | boolean>): void {
    this.track(action as AnalyticsEvent, properties);
  }

  /**
   * 记录错误
   */
  trackError(errorType: string, errorMessage: string, stackTrace?: string): void {
    const props: AnalyticsProps = {
      error_type: errorType,
      error_message: errorMessage
    };
    if (stackTrace !== undefined) {
      props.stack_trace = stackTrace;
    }
    this.track(AnalyticsEvent.ERROR_OCCURRED, props);
  }

  /**
   * 启动定时刷新
   */
  private startFlushTimer(): void {
    this.timer = setInterval(() => {
      this.flush();
    }, this.flushInterval);
  }

  /**
   * 停止定时刷新
   */
  private stopFlushTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /**
   * 刷新事件队列（上传到服务器）
   */
  async flush(): Promise<void> {
    if (this.eventQueue.length === 0) return;

    // 合规门禁：同意被撤回或开关被关闭时，队列直接丢弃，绝不写入本地
    if (!this.isTrackingAllowed()) {
      this.eventQueue = [];
      hilog.info(DOMAIN, TAG, 'Flush skipped: tracking not allowed, queue dropped');
      return;
    }

    const eventsToSend = [...this.eventQueue];
    hilog.info(DOMAIN, TAG, `Flushing ${eventsToSend.length} events`);

    try {
      // 在生产环境中，这里应该上传到埋点服务器
      // 目前先保存到本地
      await this.saveEventsToLocal(eventsToSend);
      
      // 清空队列
      this.eventQueue = [];
      
      hilog.info(DOMAIN, TAG, 'Events flushed successfully');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to flush events: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 保存事件到本地
   */
  private async saveEventsToLocal(events: AnalyticsEventData[]): Promise<void> {
    if (!this.context) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'analytics_events');
      const existingEventsStr = await prefs.get('events', '[]') as string;
      const existingEvents: AnalyticsEventData[] = JSON.parse(existingEventsStr);
      
      // 合并事件，保持最多 1000 条
      const allEvents = [...existingEvents, ...events].slice(-1000);
      
      await prefs.put('events', JSON.stringify(allEvents));
      await prefs.flush();
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to save events: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 加载未上传的事件
   */
  private async loadPendingEvents(): Promise<void> {
    if (!this.context) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'analytics_events');
      const eventsStr = await prefs.get('events', '[]') as string;
      const events: AnalyticsEventData[] = JSON.parse(eventsStr);
      
      if (events.length > 0) {
        hilog.info(DOMAIN, TAG, `Loaded ${events.length} pending events`);
        // 这里可以选择重新上传或丢弃
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to load pending events: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 获取事件统计
   */
  getEventStats(): EventStats {
    const byType: Record<string, number> = {};
    
    for (const event of this.eventQueue) {
      const eventName = event.event.toString();
      byType[eventName] = (byType[eventName] || 0) + 1;
    }

    const result: EventStats = {
      total: this.eventQueue.length,
      byType: byType
    };
    return result;
  }

  /**
   * 销毁服务
   */
  destroy(): void {
    this.stopFlushTimer();
    this.flush();
    this.isInitialized = false;
    hilog.info(DOMAIN, TAG, 'AnalyticsService destroyed');
  }
}

// 导出单例
export const analytics = AnalyticsService.getInstance();
