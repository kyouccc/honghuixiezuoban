/**
 * SM2Scheduler.ets — SM-2 间隔重复调度器（S2-B / T2-4 新建）
 *
 * 经典 SM-2 算法（SuperMemo-2）：
 *  - 按回答质量 q∈{0..5} 调整 ease 与 interval；
 *  - q>=3 视为"记得"（推进 interval 并升 box），q<3 视为"忘记"（interval 归 1、降 box、lapses+1）；
 *  - 返回更新后的闪卡状态（box/ease/interval/dueAt/reps/lapses）。
 *
 * 纯函数 + 显式类型（ArkTS 严格模式），不持有状态；状态由 FlashcardStore / HCFlashcard 承载。
 */

const TAG_MODULE = 'SM2Scheduler';

/** 回答质量档位：0=完全忘记，3=勉强记得，5=完美 */
export type ReviewQuality = number;

/** 复习结果（与 HCFlashcard 同构的增量更新） */
export interface ReviewOutcome {
  box: number;
  ease: number;
  interval: number;
  dueAt: number;
  reps: number;
  lapses: number;
}

export class SM2Scheduler {
  /** 初始 ease（新卡默认） */
  static readonly INITIAL_EASE: number = 2.5;
  /** ease 下界（防止无限膨胀/塌缩） */
  static readonly MIN_EASE: number = 1.3;
  /** ease 上界 */
  static readonly MAX_EASE: number = 2.5;
  /** 最大 box（6 个盒子：0-5） */
  static readonly MAX_BOX: number = 5;

  /**
   * 按回答质量更新卡片状态（纯函数）。
   * @param box    当前盒子（0=新卡/学习中）
   * @param ease   当前 ease（1.3-2.5）
   * @param interval 当前间隔（天）
   * @param reps   累计复习次数
   * @param lapses 累计遗忘次数
   * @param quality 本次回答质量（0-5 整数）
   * @returns 更新后的状态（含下次到期时间戳 dueAt = now + interval 天）
   */
  static review(box: number, ease: number, interval: number, reps: number, lapses: number,
                quality: ReviewQuality): ReviewOutcome {
    const q: number = Math.max(0, Math.min(5, Math.round(quality)));
    const nextReps: number = reps + 1;

    if (q < 3) {
      // 忘记：interval 归 1 天，降 box，lapses+1；ease 不变（SM-2 对失败不改 ease）
      return {
        box: 0,
        ease: SM2Scheduler.clampEase(ease),
        interval: 1,
        dueAt: Date.now() + 86400000,
        reps: nextReps,
        lapses: lapses + 1,
      };
    }

    // 记得：按 SM-2 公式推进
    const nextEase: number = SM2Scheduler.clampEase(ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)));
    let nextInterval: number;
    let nextBox: number;
    if (box === 0) {
      nextInterval = 1;
      nextBox = 1;
    } else if (box === 1) {
      nextInterval = 6;
      nextBox = 2;
    } else {
      // box>=2：interval *= ease
      const mul: number = nextEase * (box >= 4 ? 1.5 : 1.0);
      nextInterval = Math.max(6, Math.round(interval * mul));
      nextBox = Math.min(SM2Scheduler.MAX_BOX, box + 1);
    }
    return {
      box: nextBox,
      ease: nextEase,
      interval: nextInterval,
      dueAt: Date.now() + nextInterval * 86400000,
      reps: nextReps,
      lapses: lapses,
    };
  }

  /** ease clamp 到 [MIN, MAX]（1 位小数） */
  static clampEase(ease: number): number {
    const raw: number = ease > 0 ? ease : SM2Scheduler.INITIAL_EASE;
    const clamped: number = Math.max(SM2Scheduler.MIN_EASE, Math.min(SM2Scheduler.MAX_EASE, raw));
    return Math.round(clamped * 10) / 10;
  }

  /** 是否到期（dueAt <= now） */
  static isDue(dueAt: number, now: number): boolean {
    return dueAt > 0 && dueAt <= now;
  }
}
