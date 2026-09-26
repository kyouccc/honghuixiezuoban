import { Logger } from '../common/Logger';

/**
 * PressureSampler.ets — 压感采样器（T2-2 / S2-A 新建）
 *
 * 压感来源优先级（A2-3：压感连续变化、无压感回退无跳变）：
 *  ① TouchEvent.getHistoricalPoints().force —— 真实压感，Move 事件的历史点含更细的 force 曲线；
 *  ② 当前触点 TouchObject.force —— 部分设备仅当前点有值；
 *  ③ 无压感设备回退**速度模拟** —— 由相邻点位移/时间估计压力（速度连续则压力连续，无跳变）。
 *
 * 本模块为纯逻辑/纯函数，不持有画布状态；速度模拟所需的上一点坐标/时间由调用方（WhiteboardPage / StrokeEngine）传入。
 *
 * ArkTS 严格模式：无 any/unknown、显式类型。
 */

/** 无效压感标记（无压感设备 / force 非法） */
const FORCE_INVALID: number = -1;

/** 设备压感能力级别 */
export enum PressureCapability {
  /** 无压感设备，完全依赖速度模拟 */
  NONE = 0,
  /** 基础压感设备，仅当前触点有force值 */
  BASIC = 1,
  /** 高级压感设备，历史点包含详细force曲线 */
  ADVANCED = 2
}

/** 扩展 TouchObject 以包含 force 属性（部分设备支持） */
interface TouchObjectWithForce extends TouchObject {
  force?: number;
}

export class PressureSampler {
  /** 设备压感能力缓存 */
  private static cachedCapability: PressureCapability | null = null;

  /**
   * 检测设备压感能力。
   * 通过测试TouchEvent是否包含有效的force值来判断设备能力。
   * @param testEvent 可选的测试事件，用于检测压感能力
   * @returns 设备压感能力级别
   */
  static detectCapability(testEvent?: TouchEvent): PressureCapability {
    // 如果已缓存，直接返回
    if (PressureSampler.cachedCapability !== null) {
      return PressureSampler.cachedCapability;
    }

    // 如果没有测试事件，暂时假设为基础压感设备
    if (testEvent === undefined || testEvent === null) {
      return PressureCapability.BASIC;
    }

    // 检测历史点是否有force值
    const history: Array<HistoricalPoint> = testEvent.getHistoricalPoints();
    if (history !== undefined && history !== null && history.length > 0) {
      for (let i = 0; i < history.length; i++) {
        const f: number = history[i].force;
        if (f !== undefined && f !== null && Number.isFinite(f) && f >= 0 && f <= 1) {
          PressureSampler.cachedCapability = PressureCapability.ADVANCED;
          return PressureCapability.ADVANCED;
        }
      }
    }

    // 检测当前触点是否有force值
    const touchList: TouchObject[] =
      testEvent.touches !== undefined && testEvent.touches !== null && testEvent.touches.length > 0
        ? testEvent.touches
        : testEvent.changedTouches;
    if (touchList !== undefined && touchList !== null && touchList.length > 0) {
      const touchWithForce: TouchObjectWithForce = touchList[0] as TouchObjectWithForce;
      const forceValue: number | undefined = touchWithForce.force;
      if (forceValue !== undefined && forceValue !== null && Number.isFinite(forceValue)) {
        PressureSampler.cachedCapability = PressureCapability.BASIC;
        return PressureCapability.BASIC;
      }
    }

    // 无压感设备
    PressureSampler.cachedCapability = PressureCapability.NONE;
    return PressureCapability.NONE;
  }

  /**
   * 重置设备压感能力缓存（用于设备切换等场景）
   */
  static resetCapability(): void {
    PressureSampler.cachedCapability = null;
  }

  /**
   * clamp 原始 force 到 [0,1]。
   * @returns 有效压力（0-1）；raw 为空/非有限数 → FORCE_INVALID（-1，调用方视为无压感）
   */
  static clampForce(raw: number): number {
    if (raw === undefined || raw === null || !Number.isFinite(raw)) {
      return FORCE_INVALID;
    }
    return Math.max(0, Math.min(1, raw));
  }

  /**
   * 从 TouchEvent 取最可信的触点压感（0-1）。
   * 历史点 force 优先（取最大值——历史点可能含更细的采样），其次当前触点。
   * @returns 有效压力（0-1）；无压感设备返回 FORCE_INVALID（-1）
   */
  static sampleForce(event: TouchEvent): number {
    try {
      // ① 历史点优先
      const history: Array<HistoricalPoint> = event.getHistoricalPoints();
      if (history !== undefined && history !== null && history.length > 0) {
        let best: number = FORCE_INVALID;
        for (let i = 0; i < history.length; i++) {
          const f: number = PressureSampler.clampForce(history[i].force);
          if (f >= 0 && f > best) {
            best = f;
          }
        }
        if (best >= 0) {
          return best;
        }
      }
      // ② 当前触点
      const touchList: TouchObject[] =
        event.touches !== undefined && event.touches !== null && event.touches.length > 0
          ? event.touches
          : event.changedTouches;
      if (touchList !== undefined && touchList !== null && touchList.length > 0) {
        const touchWithForce: TouchObjectWithForce = touchList[0] as TouchObjectWithForce;
        const forceValue: number | undefined = touchWithForce.force;
        if (forceValue !== undefined && forceValue !== null) {
          const f: number = PressureSampler.clampForce(forceValue);
          if (f >= 0) {
            return f;
          }
        }
      }
      return FORCE_INVALID;
    } catch (e) {
      Logger.error('PressureSampler', `sampleForce异常: ${e}`);
      return FORCE_INVALID;
    }
  }

  /**
   * 速度模拟（无压感设备回退）：由相邻点位移/时间估计压力（0-1）。
   * 速度越快压力越大（符合"快写用力"直觉），映射连续 → 压力曲线无跳变。
   * @param distance 相邻点欧氏距离（vp）
   * @param dtMs     相邻点时间差（ms）
   * @returns 模拟压力（0.1-1.0）
   */
  static estimateVelocityPressure(distance: number, dtMs: number): number {
    try {
      // 参数验证
      if (distance < 0 || dtMs <= 0 || !Number.isFinite(distance) || !Number.isFinite(dtMs)) {
        Logger.warn('PressureSampler', `estimateVelocityPressure参数异常: distance=${distance}, dtMs=${dtMs}`);
        return 0.5;
      }
      const speed: number = distance / dtMs; // vp/ms
      // 经验映射：0 速度 → 0.35（轻落笔），速度线性放大 → 趋近 1.0；clamp 保连续
      const raw: number = 0.35 + speed * 0.8;
      return Math.max(0.1, Math.min(1.0, raw));
    } catch (e) {
      Logger.error('PressureSampler', `estimateVelocityPressure异常: ${e}`);
      return 0.5;
    }
  }

  /** 便捷：事件级采样，无效时回退给定默认压力（Down 起笔用 0.5 或速度模拟值） */
  static resolveForce(event: TouchEvent, fallback: number): number {
    const sampled: number = PressureSampler.sampleForce(event);
    return sampled >= 0 ? sampled : Math.max(0.1, Math.min(1.0, fallback));
  }
}
