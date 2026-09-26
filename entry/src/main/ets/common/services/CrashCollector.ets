/**
 * 崩溃收集服务
 * 使用 @ohos.faultLogger 收集应用崩溃信息
 */
import faultLogger from '@ohos.faultLogger';
import errorManager from '@ohos.app.ability.errorManager';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { emergencySaveService } from './EmergencySaveService';

const TAG = 'CrashCollector';
const DOMAIN = 0x0000;

/** 崩溃报告版本标记（发版时与 AppScope/app.json5 的 versionName 同步） */
const APP_VERSION: string = '2.5.1';

export interface CrashReport {
  timestamp: number;
  type: string;
  message: string;
  stackTrace?: string;
  deviceInfo?: string;
  appVersion: string;
}

export class CrashCollector {
  private static instance: CrashCollector;
  private context: common.UIAbilityContext | null = null;
  private crashReports: CrashReport[] = [];
  private maxReports: number = 50;
  /** 全局异常观察者句柄（销毁时 off，防重复注册） */
  private observerId: number = -1;

  private constructor() {}

  static getInstance(): CrashCollector {
    if (!CrashCollector.instance) {
      CrashCollector.instance = new CrashCollector();
    }
    return CrashCollector.instance;
  }

  /**
   * 初始化崩溃收集器
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    hilog.info(DOMAIN, TAG, 'CrashCollector initialized');

    // 🔧 v2.5.1：先注册全局异常观察者，再做耗时的历史故障查询。
    //   原顺序是先 await queryHistoricalFaults() 再注册，那段 await 期间崩溃完全捕获不到。
    this.setupGlobalErrorHandler();

    // 查询历史崩溃记录（仅为信息展示，允许失败）
    await this.queryHistoricalFaults();
  }

  /**
   * 查询历史崩溃记录
   */
  private async queryHistoricalFaults(): Promise<void> {
    try {
      // 查询 JS 崩溃
      const jsFaults = await faultLogger.query(faultLogger.FaultType.JS_CRASH);
      if (jsFaults && jsFaults.length > 0) {
        hilog.warn(DOMAIN, TAG, `Found ${jsFaults.length} JS crash records`);
        for (const fault of jsFaults) {
          this.addCrashReport({
            timestamp: fault.timestamp ?? Date.now(),
            type: 'JS_CRASH',
            message: fault.reason ?? 'Unknown JS crash',
            stackTrace: fault.fullLog,
            appVersion: APP_VERSION
          });
        }
      }

      // 查询应用冻结
      const appFreeze = await faultLogger.query(faultLogger.FaultType.APP_FREEZE);
      if (appFreeze && appFreeze.length > 0) {
        hilog.warn(DOMAIN, TAG, `Found ${appFreeze.length} app freeze records`);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to query faults: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 设置全局错误处理器
   */
  private setupGlobalErrorHandler(): void {
    // 幂等：已注册过就不再注册（Abliity 重建 / init 重复调用时防重复观察者）
    if (this.observerId !== -1) {
      return;
    }
    try {
      const observer: errorManager.ErrorObserver = {
        onUnhandledException: (errMsg: string): Promise<void> => {
          return this.handleFatal(errMsg, 'UNHANDLED_EXCEPTION');
        },
        onException: (errObj: Error): Promise<void> => {
          return this.handleFatal(`${errObj.message}\n${errObj.stack ?? ''}`, 'JS_EXCEPTION');
        }
      };
      this.observerId = errorManager.on('error', observer);
      hilog.info(DOMAIN, TAG, `Global error observer registered, id=${this.observerId}`);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, `Global error handler setup failed: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 致命错误处理：先落崩溃报告，再触发紧急保存。
   *
   * 返回 Promise 是**关键**——errorManager 会等它 resolve 后才终止进程，
   * 因此这里有机会把未保存笔迹写盘，直接缓解审核视频(2)"崩后残留 99 笔未保存"。
   */
  private async handleFatal(errMsg: string, type: string): Promise<void> {
    hilog.error(DOMAIN, TAG, `[FATAL] ${type}`);
    await this.addCrashReport({
      timestamp: Date.now(),
      type: type,
      message: errMsg.length > 2000 ? errMsg.substring(0, 2000) : errMsg,
      stackTrace: errMsg,
      appVersion: APP_VERSION
    });
    try {
      await emergencySaveService.triggerEmergencySave();
      hilog.info(DOMAIN, TAG, '崩溃前紧急保存完成');
    } catch (e) {
      hilog.warn(DOMAIN, TAG, `崩溃前紧急保存失败: ${JSON.stringify(e)}`);
    }
  }

  /** 注销全局异常观察者（Ability 销毁时调用） */
  unregisterGlobalErrorHandler(): void {
    if (this.observerId !== -1) {
      try {
        errorManager.off('error', this.observerId);
        hilog.info(DOMAIN, TAG, 'Global error observer unregistered');
      } catch (error) {
        hilog.warn(DOMAIN, TAG, `Unregister failed: ${JSON.stringify(error)}`);
      }
      this.observerId = -1;
    }
  }

  /**
   * 记录错误
   */
  recordError(error: Error, type: string = 'MANUAL_REPORT'): void {
    const report: CrashReport = {
      timestamp: Date.now(),
      type: type,
      message: error.message,
      stackTrace: error.stack,
      appVersion: APP_VERSION
    };

    this.addCrashReport(report);
    hilog.error(DOMAIN, TAG, `Error recorded: ${type} - ${error.message}`);
  }

  /**
   * 添加崩溃报告
   */
  private addCrashReport(report: CrashReport): Promise<void> {
    this.crashReports.push(report);

    // 保持最大记录数限制
    if (this.crashReports.length > this.maxReports) {
      this.crashReports.shift();
    }

    // 持久化到本地（返回 Promise —— 崩溃路径可 await，确保进程终止前写完）
    return this.persistReports();
  }

  /**
   * 持久化崩溃报告
   */
  private async persistReports(): Promise<void> {
    if (!this.context) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'crash_reports');
      await prefs.put('reports', JSON.stringify(this.crashReports));
      await prefs.flush();
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to persist reports: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 获取崩溃报告列表
   */
  getCrashReports(): CrashReport[] {
    return [...this.crashReports];
  }

  /**
   * 清除崩溃报告
   */
  async clearReports(): Promise<void> {
    this.crashReports = [];
    if (this.context) {
      try {
        const prefs = await preferences.getPreferences(this.context, 'crash_reports');
        await prefs.delete('reports');
        await prefs.flush();
      } catch (error) {
        hilog.error(DOMAIN, TAG, `Failed to clear reports: ${JSON.stringify(error)}`);
      }
    }
  }

  /**
   * 上传崩溃报告到服务器（用于生产环境）
   */
  async uploadReports(): Promise<void> {
    if (this.crashReports.length === 0) {
      hilog.info(DOMAIN, TAG, 'No crash reports to upload');
      return;
    }

    // TODO: 实现上传到崩溃收集服务（如 Sentry、Bugly 等）
    hilog.info(DOMAIN, TAG, `Uploading ${this.crashReports.length} crash reports`);
    
    // 上传成功后清除本地报告
    // await this.clearReports();
  }
}

// 导出单例
export const crashCollector = CrashCollector.getInstance();
