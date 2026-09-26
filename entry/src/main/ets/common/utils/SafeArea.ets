/**
 * SafeArea.ets — 全设备安全区适配工具（UI-03，阶段0 P0）
 *
 * 职责：调用 window.getWindowAvoidArea 获取避让区域（刘海屏/挖孔屏/药丸屏/底部手势条），
 * 将各边 inset 写入 AppStorage，供各页面（列表/画布/设置/导入导出）做布局避让，
 * 保证输入框/按钮不被遮挡。墨水屏设备可经此关闭非必要动画（高对比模式由 ThemeManager 承接）。
 *
 * 用法：在 EntryAbility.onWindowStageCreate 中调用 SafeArea.bindWindow(windowStage.getMainWindowSync())，
 *       并在 onConfigurationUpdate 中重新拉取（折叠/旋转时避让区变化）。
 *
 * ArkTS 严格模式：显式类型，无 any/unknown。
 */

import window from '@ohos.window';
import { Logger } from '../Logger';

const TAG_MODULE = 'SafeArea';

/** AppStorage 键：安全区各边 inset（vp） */
export const SAFE_AREA_LEFT: string = 'hcSafeAreaLeft';
export const SAFE_AREA_TOP: string = 'hcSafeAreaTop';
export const SAFE_AREA_RIGHT: string = 'hcSafeAreaRight';
export const SAFE_AREA_BOTTOM: string = 'hcSafeAreaBottom';

/** 安全区快照 */
export interface SafeAreaInsets {
  left: number;
  top: number;
  right: number;
  bottom: number;
}

/**
 * 绑定窗口并拉取避让区域。幂等可重复调用（折叠/旋转/系统栏变化时重拉）。
 * @param win 主窗口实例（windowStage.getMainWindowSync()）
 */
export function bindWindow(win: window.Window): void {
  try {
    // 挖孔/刘海避让区
    const cutout = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
    // 系统栏（状态栏/导航条/手势条）避让区
    const system = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
    const left: number = Math.max(cutout.leftRect.width, system.leftRect.width);
    const top: number = Math.max(cutout.topRect.height, system.topRect.height);
    const right: number = Math.max(cutout.rightRect.width, system.rightRect.width);
    const bottom: number = Math.max(cutout.bottomRect.height, system.bottomRect.height);
    AppStorage.setOrCreate(SAFE_AREA_LEFT, left);
    AppStorage.setOrCreate(SAFE_AREA_TOP, top);
    AppStorage.setOrCreate(SAFE_AREA_RIGHT, right);
    AppStorage.setOrCreate(SAFE_AREA_BOTTOM, bottom);
    Logger.info(TAG_MODULE, `安全区更新 L=${left} T=${top} R=${right} B=${bottom}`);
  } catch (e) {
    Logger.warn(TAG_MODULE, `安全区拉取失败（预览器/非完整窗口场景），使用 0 避让: ${(e as Error).message}`);
    AppStorage.setOrCreate(SAFE_AREA_LEFT, 0);
    AppStorage.setOrCreate(SAFE_AREA_TOP, 0);
    AppStorage.setOrCreate(SAFE_AREA_RIGHT, 0);
    AppStorage.setOrCreate(SAFE_AREA_BOTTOM, 0);
  }
}

/** 读取当前安全区（供页面布局用，默认全 0） */
export function currentInsets(): SafeAreaInsets {
  return {
    left: AppStorage.get(SAFE_AREA_LEFT) as number ?? 0,
    top: AppStorage.get(SAFE_AREA_TOP) as number ?? 0,
    right: AppStorage.get(SAFE_AREA_RIGHT) as number ?? 0,
    bottom: AppStorage.get(SAFE_AREA_BOTTOM) as number ?? 0
  };
}
