/**
 * PresentationMode.ets — 演示模式（P1）
 *
 * 功能：
 *  1. 全屏沉浸展示（隐藏工具栏/侧边栏）；
 *  2. 页面切换动画（淡入淡出/滑动）；
 *  3. 激光笔高亮（临时标记，不落盘）；
 *  4. 自动翻页（定时器）；
 *  5. 演示进度指示（当前页/总页）。
 */

import { Logger } from '../common/Logger';

const TAG = 'PresentationMode';

/** 演示状态 */
export enum PresentationState {
  IDLE = 'idle',
  ACTIVE = 'active',
  PAUSED = 'paused',
}

/** 切页动画类型 */
export enum TransitionType {
  NONE = 'none',
  FADE = 'fade',
  SLIDE = 'slide',
}

/** 激光笔位置 */
export interface LaserPointer {
  x: number;
  y: number;
  /** 显示半径 */
  radius: number;
  /** 颜色 */
  color: string;
  /** 自动消失时间戳 */
  expireAt: number;
}

/** LaserPointer 实现类 */
class LaserPointerImpl implements LaserPointer {
  x: number;
  y: number;
  radius: number;
  color: string;
  expireAt: number;

  constructor(x: number, y: number, radius: number, color: string, expireAt: number) {
    this.x = x;
    this.y = y;
    this.radius = radius;
    this.color = color;
    this.expireAt = expireAt;
  }
}

/** 演示事件回调 */
export type PresentationCallback = (state: PresentationState, pageIndex: number, totalPages: number) => void;

export class PresentationMode {
  private state: PresentationState = PresentationState.IDLE;
  private currentPageIndex: number = 0;
  private totalPages: number = 0;
  private transition: TransitionType = TransitionType.FADE;

  /** 自动翻页间隔（ms，0=关闭） */
  private autoFlipInterval: number = 0;
  private autoFlipTimer: number = -1;

  /** 激光笔标记列表 */
  private laserPointers: LaserPointer[] = [];
  /** 激光笔自动消失时间 */
  private laserDuration: number = 3000;

  private listeners: PresentationCallback[] = [];

  // ── 状态查询 ──

  get isActive(): boolean { return this.state === PresentationState.ACTIVE; }
  get currentState(): PresentationState { return this.state; }
  get currentSlide(): number { return this.currentPageIndex; }
  get slideCount(): number { return this.totalPages; }
  get transitionType(): TransitionType { return this.transition; }
  get laserMarks(): LaserPointer[] { return this.laserPointers; }

  // ── 演示控制 ──

  /** 开始演示 */
  start(totalPages: number, startIndex: number = 0): void {
    this.totalPages = totalPages;
    this.currentPageIndex = Math.max(0, Math.min(startIndex, totalPages - 1));
    this.state = PresentationState.ACTIVE;
    this.cleanupExpiredLasers();
    this.notify();
    Logger.info(TAG, `start: ${this.currentPageIndex + 1}/${this.totalPages}`);
  }

  /** 结束演示 */
  stop(): void {
    this.state = PresentationState.IDLE;
    this.stopAutoFlip();
    this.laserPointers = [];
    this.notify();
    Logger.info(TAG, 'stop');
  }

  /** 暂停（停止自动翻页但保持全屏） */
  pause(): void {
    this.state = PresentationState.PAUSED;
    this.stopAutoFlip();
    this.notify();
  }

  /** 恢复 */
  resume(): void {
    this.state = PresentationState.ACTIVE;
    if (this.autoFlipInterval > 0) {
      this.startAutoFlip();
    }
    this.notify();
  }

  // ── 翻页 ──

  nextSlide(): void {
    if (this.currentPageIndex < this.totalPages - 1) {
      this.currentPageIndex++;
      this.notify();
    }
  }

  prevSlide(): void {
    if (this.currentPageIndex > 0) {
      this.currentPageIndex--;
      this.notify();
    }
  }

  goToSlide(index: number): void {
    if (index >= 0 && index < this.totalPages) {
      this.currentPageIndex = index;
      this.notify();
    }
  }

  get hasNext(): boolean { return this.currentPageIndex < this.totalPages - 1; }
  get hasPrev(): boolean { return this.currentPageIndex > 0; }

  // ── 自动翻页 ──

  setAutoFlip(intervalMs: number): void {
    this.autoFlipInterval = intervalMs;
    if (this.state === PresentationState.ACTIVE) {
      this.stopAutoFlip();
      if (intervalMs > 0) this.startAutoFlip();
    }
  }

  private startAutoFlip(): void {
    if (this.autoFlipInterval <= 0) return;
    this.autoFlipTimer = setInterval(() => {
      if (this.hasNext) {
        this.nextSlide();
      } else {
        this.stopAutoFlip();
      }
    }, this.autoFlipInterval);
  }

  private stopAutoFlip(): void {
    if (this.autoFlipTimer !== -1) {
      clearInterval(this.autoFlipTimer);
      this.autoFlipTimer = -1;
    }
  }

  // ── 切页动画 ──

  setTransition(type: TransitionType): void {
    this.transition = type;
  }

  // ── 激光笔 ──

  /** 在当前位置添加激光笔标记 */
  addLaserPointer(x: number, y: number, color: string = '#FF0000'): void {
    this.cleanupExpiredLasers();
    this.laserPointers.push(new LaserPointerImpl(x, y, 12, color, Date.now() + this.laserDuration));
  }

  /** 设置激光笔持续时间 */
  setLaserDuration(ms: number): void {
    this.laserDuration = ms;
  }

  /** 清除所有激光笔 */
  clearLaserPointers(): void {
    this.laserPointers = [];
  }

  /** 清理过期的激光笔 */
  private cleanupExpiredLasers(): void {
    const now = Date.now();
    this.laserPointers = this.laserPointers.filter(p => p.expireAt > now);
  }

  // ── 事件 ──

  addListener(cb: PresentationCallback): void {
    this.listeners.push(cb);
  }

  removeListener(cb: PresentationCallback): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }

  private notify(): void {
    for (const cb of this.listeners) {
      cb(this.state, this.currentPageIndex, this.totalPages);
    }
  }

  /** 销毁 */
  destroy(): void {
    this.stopAutoFlip();
    this.laserPointers = [];
    this.listeners = [];
  }
}
