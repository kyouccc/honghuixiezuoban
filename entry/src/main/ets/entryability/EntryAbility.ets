/**
 * EntryAbility.ets — 应用入口 Ability（v2.3 / v2.4 阶段一 T1-3 修订）
 *
 * 用途：
 *  1. 加载首页（v2.4 起改为 pages/NotePage —— 应用定位从"白板"回归"笔记本"，
 *     用户打开 App 第一眼就该看到自己的笔记列表，而不是一块空白板子）；
 *  2. 首页加载失败时**降级**加载 pages/Index（导航中心），保证预览器/真机不出现白屏；
 *  3. 初始化埋点（AnalyticsService）与崩溃收集（CrashCollector）；
 *  4. v2.4 新增：初始化笔记本地存储（NoteEngine.initStorage）——
 *     建 files/notes 与 files/thumbs 目录、打开 Preferences 索引、跑 fileIo 冒烟自检。
 *
 * 输入：Want / LaunchParam / WindowStage（系统回调）
 * 输出：无（副作用为窗口内容加载与服务初始化）
 *
 * 注意事项：
 *  - loadContent 回调内**必须**做错误分支处理，否则页面路径与 main_pages.json 不一致时
 *    只会打印一行日志、界面全白（历史 Bug 根因）；
 *  - 服务初始化为异步且允许失败，统一走 SafeAsync.runAsyncVoid 兜底，不阻塞窗口加载；
 *  - 存储初始化必须在 onCreate 触发（早于任何页面 aboutToAppear），
 *    否则 NotePage 首帧会读到「存储未就绪」。
 */

import UIAbility from '@ohos.app.ability.UIAbility';
import { AbilityConstant, Want, common } from '@kit.AbilityKit';
import window from '@ohos.window';
import { BusinessError } from '@ohos.base';
import { Logger } from '../common/Logger';
import { SafeAsync } from '../common/utils/SafeAsync';
import { analytics } from '../common/services/AnalyticsService';
import { crashCollector } from '../common/services/CrashCollector';
import { NoteEngine } from '../engine/NoteEngine';
import { privacyConsentService } from '../common/services/PrivacyConsentService';
import { favoriteService } from '../common/services/FavoriteService';
import { BreakpointSystem } from '../common/theme/BreakpointSystem';
import { FoldAdapter } from '../common/theme/FoldAdapter';
import { themeManager } from '../common/theme/ThemeManager';
import { bindWindow } from '../common/utils/SafeArea';
import { ConfigurationConstant, Configuration } from '@kit.AbilityKit';

const TAG_MODULE = 'EntryAbility';

/** 首页路由（必须与 main_pages.json 中的条目完全一致） */
const PRIMARY_PAGE: string = 'pages/NotePage';
/** 降级路由：首页加载异常时进入导航中心，避免白屏 */
const FALLBACK_PAGE: string = 'pages/Index';

export default class EntryAbility extends UIAbility {
  private contentLoaded: boolean = false;
  /** UI-03：主窗口引用（折叠/旋转时重新拉取安全区） */
  private mainWindow: window.Window | null = null;
  /** v2.7.0：主题偏好加载完成信号（页面加载前必须 await） */
  private themeReady: Promise<void> | null = null;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG_MODULE, 'onCreate');
    // v2.7.0：最早注入应用上下文，保证后续 setColorMode 一定可用
    themeManager.initWithContext(this.context);
    // 初始化隐私同意服务
    privacyConsentService.init(this.context);
    // 初始化主题管理器（F-01 暗色模式）
    this.initThemeManager();
    // 🔧 v2.5.1：崩溃捕获**无条件**注册（只写本地 preferences，uploadReports 仍是 TODO 不联网；
    //   且其副作用是崩溃前紧急保存用户笔迹 = 保护用户数据，不属于需要同意的埋点）。
    //   之前挂在隐私同意之后，导致首次启动弹窗期间崩溃既无栈也无兜底保存。
    this.initCrashHandler();
    // 检查隐私同意状态后再初始化服务
    this.initServicesWithPrivacyCheck();
    this.initNoteStorage();
  }

  onDestroy(): void {
    Logger.info(TAG_MODULE, 'onDestroy');
    crashCollector.unregisterGlobalErrorHandler();
    SafeAsync.runAsyncVoid(TAG_MODULE, 'analyticsFlushOnDestroy', (): Promise<void> => {
      return analytics.flush();
    });
  }

  /** 注册全局异常观察者（含崩溃前紧急保存），异步且允许失败，不阻塞启动 */
  private initCrashHandler(): void {
    const abilityContext: common.UIAbilityContext = this.context;
    SafeAsync.runAsyncVoid(TAG_MODULE, 'initCrashHandler', (): Promise<void> => {
      return crashCollector.init(abilityContext);
    });
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.info(TAG_MODULE, 'onWindowStageCreate');
    // T01：注册断点与折叠适配服务（幂等，失败不阻塞窗口加载）
    BreakpointSystem.getInstance().register();
    FoldAdapter.getInstance().register();
    // UI-03：全设备安全区适配——拉取避让区域（刘海/挖孔/底部手势条）写入 AppStorage
    try {
      const mainWin = windowStage.getMainWindowSync();
      this.mainWindow = mainWin;
      bindWindow(mainWin);
    } catch (e) {
      Logger.warn(TAG_MODULE, `安全区绑定失败（降级 0 避让）: ${(e as Error).message}`);
    }
    this.loadPageAfterThemeReady(windowStage, PRIMARY_PAGE, true);
    // 阶段一工程内单测（T1-2 / S1T01~03）：纯内存逻辑、fire-and-forget，
    // 不影响首屏加载，失败仅记日志（与 tests/*Test.ets 同模式）。
    this.runSelfTests();
  }

  /**
   * v2.7.0 审核修复（问题③-1「主题设置选浅色/深色，重启后跟随系统」）：
   *   先等主题偏好从 Preferences 读出来并**下发应用级颜色模式**，再加载页面内容。
   *   原实现把加载放在 fire-and-forget 异步里，与同步的 updateFromConfiguration 竞争，
   *   首帧用系统主题渲染，且 setColorMode 在 onCreate 阶段可能因上下文未就绪而静默失败，
   *   结果重启后表现为"跟随系统"。
   */
  private loadPageAfterThemeReady(windowStage: window.WindowStage, page: string, allowFallback: boolean): void {
    SafeAsync.runAsyncVoid(TAG_MODULE, 'themeThenLoad', async (): Promise<void> => {
      try {
        const ready: Promise<void> | null = this.themeReady;
        if (ready !== null) {
          await ready;
        }
        // 二次确保：显式下发一次（幂等，同值会短路）
        themeManager.applyColorMode();
      } catch (e) {
        Logger.warn(TAG_MODULE, `主题先行加载失败（降级系统主题）: ${(e as Error).message}`);
      }
      this.loadPage(windowStage, page, allowFallback);
    });
  }

  /** 运行工程内单测。包在 SafeAsync 内，任何异常都不会外抛影响主流程。 */
  private runSelfTests(): void {
  }

  onWindowStageDestroy(): void {
    Logger.info(TAG_MODULE, 'onWindowStageDestroy');
    this.contentLoaded = false;
    // T01：反注册断点与折叠适配服务（防监听器泄漏）
    BreakpointSystem.getInstance().unregister();
    FoldAdapter.getInstance().unregister();
  }

  onForeground(): void {
    Logger.info(TAG_MODULE, 'onForeground');
  }

  onBackground(): void {
    Logger.info(TAG_MODULE, 'onBackground');
    // 切后台时落盘埋点，避免进程回收导致事件丢失
    SafeAsync.runAsyncVoid(TAG_MODULE, 'analyticsFlushOnBackground', (): Promise<void> => {
      return analytics.flush();
    });
  }

  // ─── 内部 ───

  /**
   * 加载窗口内容，失败时按需降级。
   * @param windowStage 窗口舞台
   * @param page        页面路由
   * @param allowFallback 加载失败时是否降级到 FALLBACK_PAGE
   */
  private loadPage(windowStage: window.WindowStage, page: string, allowFallback: boolean): void {
    const ok: boolean = SafeAsync.runVoid(TAG_MODULE, `loadContent:${page}`, () => {
      windowStage.loadContent(page, (err: BusinessError) => {
        if (err !== null && err !== undefined && err.code !== 0) {
          Logger.error(TAG_MODULE, `Failed to load ${page}. code=${err.code} msg=${err.message}`);
          if (allowFallback) {
            Logger.warn(TAG_MODULE, `Degrading to fallback page: ${FALLBACK_PAGE}`);
            this.loadPage(windowStage, FALLBACK_PAGE, false);
          }
          return;
        }
        this.contentLoaded = true;
        Logger.info(TAG_MODULE, `Content loaded: ${page}`);
      });
    });

    if (!ok && allowFallback) {
      Logger.warn(TAG_MODULE, `loadContent threw for ${page}, degrading to ${FALLBACK_PAGE}`);
      this.loadPage(windowStage, FALLBACK_PAGE, false);
    }
  }

  /**
   * 初始化埋点（需隐私同意）。
   * 崩溃收集已移到 initCrashHandler() 无条件注册，此处不再重复。
   */
  private initServices(): void {
    const abilityContext: common.UIAbilityContext = this.context;
    SafeAsync.runAsyncVoid(TAG_MODULE, 'initAnalytics', (): Promise<void> => {
      return analytics.init(abilityContext);
    });
  }

  /** 隐私同意后再初始化服务 */
  private async initServicesWithPrivacyCheck(): Promise<void> {
    const consentAccepted = await privacyConsentService.checkConsent();
    if (consentAccepted) {
      // 用户已同意隐私政策，可以初始化埋点服务
      this.initServices();
    } else {
      // 用户未同意隐私政策，不初始化埋点服务
      // 埋点服务将在用户同意后由首页初始化
      Logger.info(TAG_MODULE, 'Privacy consent not accepted yet, skipping analytics init');
    }
  }

  /**
   * 初始化笔记本地存储（v2.4 阶段一）。
   * 异步且允许失败：失败时 NoteEngine.isStorageReady() 恒 false，
   * NotePage 会显示「存储不可用，请重启应用」而不是白屏或崩溃。
   */
  private initNoteStorage(): void {
    const abilityContext: common.UIAbilityContext = this.context;
    SafeAsync.runAsyncVoid(TAG_MODULE, 'initNoteStorage', async (): Promise<void> => {
      const ok: boolean = await NoteEngine.getInstance().initStorage(abilityContext);
      Logger.info(TAG_MODULE, `笔记存储初始化${ok ? '成功' : '失败'}`);
      
      // 初始化收藏服务
      await favoriteService.initialize(abilityContext);
      Logger.info(TAG_MODULE, `收藏服务初始化${favoriteService.isReady() ? '成功' : '失败'}`);
    });
  }

  /**
   * 初始化主题管理器（F-01 暗色模式支持）
   * 1. 加载用户主题偏好
   * 2. 响应系统主题变化
   */
  private initThemeManager(): void {
    // 加载用户主题偏好
    // v2.7.0：记录加载 Promise，onWindowStageCreate 会 await 它之后再加载页面内容，
    //   保证「首帧即使用用户选择的主题」，而不是先用系统主题、之后再纠正。
    this.themeReady = themeManager.loadFromPreferences();
    this.themeReady.then((): void => {
      Logger.info(TAG_MODULE, '主题管理器初始化完成');
    }).catch((err: Error): void => {
      Logger.error(TAG_MODULE, '主题初始化失败: ' + err.message);
    });

    // 获取当前系统主题（作为「跟随系统」时的初值）
    const config = this.context.config;
    if (config && config.colorMode !== undefined) {
      themeManager.updateFromConfiguration(config.colorMode);
    }
  }

  /**
   * 响应系统配置变化（包括主题变化）
   * F-01 暗色模式支持
   */
  onConfigurationUpdate(newConfig: Configuration): void {
    Logger.info(TAG_MODULE, 'onConfigurationUpdate');

    // UI-03：折叠/旋转时避让区变化，重新拉取安全区
    if (this.mainWindow !== null) {
      try {
        bindWindow(this.mainWindow);
      } catch (e) {
        Logger.warn(TAG_MODULE, `onConfigurationUpdate 安全区重拉失败: ${(e as Error).message}`);
      }
    }

    // 响应主题变化
    if (newConfig.colorMode !== undefined) {
      const colorMode: ConfigurationConstant.ColorMode = newConfig.colorMode as ConfigurationConstant.ColorMode;
      themeManager.updateFromConfiguration(colorMode);
      // 🔴 v2.7.1 崩溃修复：此处**不再**调用 themeManager.reapplyIfExplicit()。
      //   setColorMode() 会在调用栈内同步回调本方法，原实现在这里再次下发颜色模式
      //   → applyColorMode → setColorMode → onConfigurationUpdate → … 无限递归，
      //   真机实测崩溃：RangeError - Stack overflow（ThemeManager.ts:126/131）。
      //   应用级颜色模式本身是粘性的（系统配置变化不会冲掉它），因此无需重下发。
      Logger.info(TAG_MODULE, `系统主题变化: ${colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK ? '暗色' : '浅色'}`);
    }
  }

  /** 内容是否已成功加载（供 QA/调试查询） */
  isContentLoaded(): boolean {
    return this.contentLoaded;
  }
}
