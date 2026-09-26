import { VectorClock } from './types/CRDTOp';

/**
 * VectorClock.ets — 扁平化向量时钟工具 v1.1 + v2.0 修复（S2T03）
 *
 * v2.0 修复：移除对象展开（{ ...a } / { ...clock }），ArkTS 严格模式
 * arkts-no-spread 禁止非数组对象展开；改用逐字段 clone（Record 索引访问例外允许）。
 * RGAEngine 经 CollaborationManager 进入 ArkTS 编译图后，本文件将被完整编译，
 * 必须符合严格模式约束。
 */
export class VectorClockHelper {
  static compare(a: VectorClock, b: VectorClock): 'CONCURRENT' | 'A_AFTER_B' | 'B_AFTER_A' | 'EQUAL' {

    const allSites: string[] = VectorClockHelper.uniqueKeys(a, b);
    let aGreater = false;
    let bGreater = false;
    for (let i = 0; i < allSites.length; i++) {
      const site: string = allSites[i];
      const av = a[site] || 0;
      const bv = b[site] || 0;
      if (av > bv) aGreater = true;
      if (bv > av) bGreater = true;
    }
    if (aGreater && !bGreater) return 'A_AFTER_B';
    if (bGreater && !aGreater) return 'B_AFTER_A';
    if (!aGreater && !bGreater) return 'EQUAL';
    return 'CONCURRENT';
  }

  static merge(a: VectorClock, b: VectorClock): VectorClock {
    const result: VectorClock = VectorClockHelper.clone(a);
    const bKeys: string[] = Object.keys(b);
    for (let i = 0; i < bKeys.length; i++) {
      const site: string = bKeys[i];
      result[site] = Math.max(result[site] || 0, b[site]);
    }
    return result;
  }

  static increment(clock: VectorClock, siteId: string): VectorClock {
    const result: VectorClock = VectorClockHelper.clone(clock);
    result[siteId] = (result[siteId] || 0) + 1;
    return result;
  }

  /** 逐字段复制向量时钟（替代对象展开，符合 arkts-no-spread） */
  static clone(clock: VectorClock): VectorClock {
    const result: VectorClock = {};
    const keys: string[] = Object.keys(clock);
    for (let i = 0; i < keys.length; i++) {
      result[keys[i]] = clock[keys[i]];
    }
    return result;
  }

  static create(): VectorClock {
    return {};
  }

  private static uniqueKeys(a: VectorClock, b: VectorClock): string[] {
    const seen: Set<string> = new Set();
    const keysA: string[] = Object.keys(a);
    for (let i = 0; i < keysA.length; i++) {
      seen.add(keysA[i]);
    }
    const keysB: string[] = Object.keys(b);
    for (let i = 0; i < keysB.length; i++) {
      seen.add(keysB[i]);
    }
    return Array.from(seen);
  }
}
