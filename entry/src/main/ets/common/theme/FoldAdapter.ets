/**
 * FoldAdapter.ets — 折叠态适配服务（T01 · v3 §2.3 / 约定 E/F）
 *
 * 折叠态 ≠ 断点（约定 E）：FOLDED/EXPANDED 被断点完全覆盖（外屏=sm，内屏=md/lg），
 * **只有 HALF_FOLDED（悬停）需要专门代码**。
 *
 * 职责：
 *  1. 把 display 的折叠状态/折痕区换算结果写入 AppStorage（hcFoldStatus / hcCreaseTopVp / hcCreaseBottomVp）；
 *  2. 首帧同步取值（修复现状缺陷③：首次进入即半折时取不到折痕）；
 *  3. display.on('foldStatusChange') 增量更新；每次进入 HALF_FOLDED 重算折痕区；
 *  4. px→vp 换算（修复现状缺陷④：WhiteboardPage:431 把 px 当 vp 用）。
 *
 * 不修改 DeviceAdapter.ets：其 mapFoldStatus/mapFoldDisplayMode 已验证正确（复用枚举语义），
 * 本类只消费其导出的 FoldStatus 枚举，不重复实现设备探测。
 */
import { display } from '@kit.ArkUI';
import { FoldStatus } from '../services/DeviceAdapter';

/** AppStorage key —— 折叠状态（number = FoldStatus） */
export const HC_FOLD_KEY: string = 'hcFoldStatus';
/** AppStorage key —— 折痕上边界（vp） */
export const HC_CREASE_TOP_KEY: string = 'hcCreaseTopVp';
/** AppStorage key —— 折痕下边界（vp） */
export const HC_CREASE_BOTTOM_KEY: string = 'hcCreaseBottomVp';

/** SDK 折叠状态 → 项目 FoldStatus（数值语义一致 0/1/2/3，显式映射保证类型安全） */
function mapSdkFoldStatus(status: display.FoldStatus): FoldStatus {
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

export class FoldAdapter {
  private static instance: FoldAdapter | null = null;
  private foldListener: ((status: display.FoldStatus) => void) | null = null;
  private registered: boolean = false;

  private constructor() {}

  static getInstance(): FoldAdapter {
    if (FoldAdapter.instance === null || FoldAdapter.instance === undefined) {
      FoldAdapter.instance = new FoldAdapter();
    }
    return FoldAdapter.instance;
  }

  /**
   * 在 EntryAbility.onWindowStageCreate 中调用一次。幂等。
   */
  register(): void {
    if (this.registered) {
      return;
    }
    // 首帧默认值，防止页面读取 undefined（非折叠设备/取值失败时保持 UNKNOWN）
    AppStorage.setOrCreate<number>(HC_FOLD_KEY, FoldStatus.UNKNOWN);
    AppStorage.setOrCreate<number>(HC_CREASE_TOP_KEY, 0);
    AppStorage.setOrCreate<number>(HC_CREASE_BOTTOM_KEY, 0);

    // 1) 首帧同步取值（修复现状缺陷③：首次进入即半折时取不到折痕）
    this.syncFoldStatus();

    // 2) display.on('foldStatusChange') 增量更新
    this.foldListener = (status: display.FoldStatus): void => {
      const s: FoldStatus = mapSdkFoldStatus(status);
      AppStorage.setOrCreate<number>(HC_FOLD_KEY, s);
      // 3) 每次进入 HALF_FOLDED 都重算折痕区
      if (s === FoldStatus.HALF_FOLDED) {
        this.refreshCrease();
      } else {
        // 非悬停态（FOLDED/EXPANDED）屏幕物理是平的，折痕区按 0 处理（R5）
        AppStorage.setOrCreate<number>(HC_CREASE_TOP_KEY, 0);
        AppStorage.setOrCreate<number>(HC_CREASE_BOTTOM_KEY, 0);
      }
    };
    try {
      display.on('foldStatusChange', this.foldListener);
      this.registered = true;
    } catch (err) {
      // 非折叠设备/Previewer 无折叠能力：注册失败不阻塞，保持 UNKNOWN
      this.foldListener = null;
      this.registered = false;
    }
  }

  /**
   * 在 EntryAbility.onWindowStageDestroy 中调用（防泄漏）。
   */
  unregister(): void {
    if (!this.registered) {
      return;
    }
    if (this.foldListener !== null) {
      try {
        display.off('foldStatusChange', this.foldListener);
      } catch (err) {
        // 忽略反注册异常
      }
      this.foldListener = null;
    }
    this.registered = false;
  }

  /** 首帧同步：当前折叠状态 + 若为悬停态则同步折痕区 */
  private syncFoldStatus(): void {
    try {
      const isFoldable: boolean = display.isFoldable();
      if (!isFoldable) {
        return; // 保持 UNKNOWN / 0
      }
      const s: FoldStatus = mapSdkFoldStatus(display.getFoldStatus());
      AppStorage.setOrCreate<number>(HC_FOLD_KEY, s);
      if (s === FoldStatus.HALF_FOLDED) {
        this.refreshCrease();
      }
    } catch (err) {
      // 非折叠设备/Previewer：保持默认值
    }
  }

  /**
   * 折痕区换算。
   * 【关键】display.FoldCreaseRegion.creaseRects 的 Rect 单位是 px，
   * 而 ArkUI 的 .height()/.padding() 单位是 vp，必须用 px2vp() 转换。
   * 现状 WhiteboardPage.ets:431 直接把 px 赋给 vp，是实锤 bug（H4）。
   */
  private refreshCrease(): void {
    try {
      const region: display.FoldCreaseRegion | null = display.getCurrentFoldCreaseRegion();
      if (region !== null && region !== undefined && region.creaseRects.length > 0) {
        const r: display.Rect = region.creaseRects[0];
        const topVp: number = px2vp(r.top);
        const bottomVp: number = px2vp(r.top + r.height);
        AppStorage.setOrCreate<number>(HC_CREASE_TOP_KEY, topVp);
        AppStorage.setOrCreate<number>(HC_CREASE_BOTTOM_KEY, bottomVp);
      }
    } catch (err) {
      // 取值失败保持 0（上层走 50% 兜底，不得让布局崩塌）
    }
  }
}
