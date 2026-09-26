/**
 * BreakpointSystem.ets — 全局断点服务（T01 · v3 §1.3 / 约定 A/B/D）
 *
 * 断点唯一来源（约定 B/D）：本单例写入 AppStorage['hcBreakpoint']，
 * 页面统一 `@StorageProp('hcBreakpoint') bp: string = 'sm'` + if/else 拆三档。
 * 禁止页面内各自 new mediaquery 监听器（多监听器竞态与内存泄漏）。
 *
 * 断点（华为官方 320/600/840vp，已核对）：
 *   xs [0,320)   → 不启用（并入 sm，约定 A；deviceTypes 无 wearable）
 *   sm [320,600) → 手机竖屏 / 折叠屏外屏
 *   md [600,840) → 折叠屏内屏 / 手机横屏 / 小平板
 *   lg [840,+∞)  → 平板 / 2in1
 *
 * API 兼容：compatibleSdkVersion 5.0.0(12)，用全局 mediaquery.matchMediaSync
 * （API 18+ 推荐 getUIContext().getMediaQuery()，本项目不用）。
 */
import { mediaquery } from '@kit.ArkUI';

/** 断点字符串类型（对外只暴露三档） */
export type HCBreakpoint = 'sm' | 'md' | 'lg';

/** AppStorage key —— 全项目唯一断点来源 */
export const HC_BP_KEY: string = 'hcBreakpoint';

export class BreakpointSystem {
  private static instance: BreakpointSystem | null = null;
  private smListener: mediaquery.MediaQueryListener | null = null;
  private mdListener: mediaquery.MediaQueryListener | null = null;
  private lgListener: mediaquery.MediaQueryListener | null = null;
  private registered: boolean = false;

  private constructor() {}

  static getInstance(): BreakpointSystem {
    if (BreakpointSystem.instance === null || BreakpointSystem.instance === undefined) {
      BreakpointSystem.instance = new BreakpointSystem();
    }
    return BreakpointSystem.instance;
  }

  /**
   * 在 EntryAbility.onWindowStageCreate 中调用一次。
   * 幂等：重复 register 直接返回，防止多窗口/热重载重复监听。
   */
  register(): void {
    if (this.registered) {
      return;
    }
    // 首帧默认值，防止页面读取 undefined（约定 D：断点必有值）
    AppStorage.setOrCreate<string>(HC_BP_KEY, 'sm');

    this.smListener = mediaquery.matchMediaSync('(width<600vp)');
    this.mdListener = mediaquery.matchMediaSync('(600vp<=width<840vp)');
    this.lgListener = mediaquery.matchMediaSync('(840vp<=width)');

    this.smListener.on('change', (result: mediaquery.MediaQueryResult): void => {
      if (result.matches) {
        AppStorage.setOrCreate<string>(HC_BP_KEY, 'sm');
      }
    });
    this.mdListener.on('change', (result: mediaquery.MediaQueryResult): void => {
      if (result.matches) {
        AppStorage.setOrCreate<string>(HC_BP_KEY, 'md');
      }
    });
    this.lgListener.on('change', (result: mediaquery.MediaQueryResult): void => {
      if (result.matches) {
        AppStorage.setOrCreate<string>(HC_BP_KEY, 'lg');
      }
    });
    this.registered = true;
  }

  /**
   * 在 EntryAbility.onWindowStageDestroy 中调用（防泄漏）。
   */
  unregister(): void {
    if (!this.registered) {
      return;
    }
    if (this.smListener !== null) {
      this.smListener.off('change');
      this.smListener = null;
    }
    if (this.mdListener !== null) {
      this.mdListener.off('change');
      this.mdListener = null;
    }
    if (this.lgListener !== null) {
      this.lgListener.off('change');
      this.lgListener = null;
    }
    this.registered = false;
  }

  /** 当前断点（调试/单测用；页面统一走 @StorageProp，不直接调本方法） */
  current(): HCBreakpoint {
    const v: string | undefined = AppStorage.get<string>(HC_BP_KEY);
    if (v === 'md') { return 'md'; }
    if (v === 'lg') { return 'lg'; }
    return 'sm';
  }
}
