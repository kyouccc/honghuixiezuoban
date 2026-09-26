/**
 * StrokeReplay.ets — 笔画回放（P1）
 *
 * 功能：
 *  1. 按时间顺序回放笔画绘制过程；
 *  2. 播放/暂停/停止/跳转进度；
 *  3. 可调播放速度（0.5x / 1x / 2x / 4x）；
 *  4. 逐笔前进/后退（步进模式）；
 *  5. 回放进度回调（用于 UI 进度条）。
 */

import { Logger } from '../common/Logger';

const TAG = 'StrokeReplay';

/** 回放状态 */
export enum ReplayState {
  IDLE = 'idle',
  PLAYING = 'playing',
  PAUSED = 'paused',
  FINISHED = 'finished',
}

/** 单步笔画（用于回放） */
export interface ReplayStroke {
  /** 笔画 ID */
  id: string;
  /** 创建时间戳（用于排序） */
  timestamp: number;
  /** 笔画数据（由外部解释） */
  data: object;
}

/** 回放进度回调 */
export type ReplayProgressCallback = (
  state: ReplayState,
  currentStrokeIndex: number,
  totalStrokes: number,
  progress: number
) => void;

/** 笔画显示回调（由外部注入：显示/隐藏指定笔画） */
export type StrokeVisibilityCallback = (strokeId: string, visible: boolean) => void;

export class StrokeReplay {
  /** 笔画列表（按时间排序） */
  private strokes: ReplayStroke[] = [];
  /** 当前回放状态 */
  private state: ReplayState = ReplayState.IDLE;
  /** 当前已显示的笔画索引 */
  private currentStrokeIndex: number = 0;
  /** 播放速度倍率 */
  private speed: number = 1.0;
  /** 每笔间隔（ms，基于时间戳差值） */
  private baseInterval: number = 200;
  /** 回放定时器 */
  private timer: number | null = null;

  // ── 外部注入 ──
  private visibilityCb: StrokeVisibilityCallback | null = null;
  private listeners: ReplayProgressCallback[] = [];

  setVisibilityCallback(cb: StrokeVisibilityCallback): void {
    this.visibilityCb = cb;
  }

  // ── 状态查询 ──

  get currentState(): ReplayState { return this.state; }
  get isPlaying(): boolean { return this.state === ReplayState.PLAYING; }
  get isPaused(): boolean { return this.state === ReplayState.PAUSED; }
  get currentSpeed(): number { return this.speed; }
  get strokeCount(): number { return this.strokes.length; }
  get currentIndex(): number { return this.currentStrokeIndex; }
  get progress(): number {
    if (this.strokes.length === 0) return 0;
    return this.currentStrokeIndex / this.strokes.length;
  }

  // ── 数据加载 ──

  /** 加载笔画列表（自动按时间排序） */
  loadStrokes(strokes: ReplayStroke[]): void {
    this.strokes = strokes.slice().sort((a: ReplayStroke, b: ReplayStroke): number => a.timestamp - b.timestamp);
    this.currentStrokeIndex = 0;
    this.state = ReplayState.IDLE;
    Logger.debug(TAG, `loadStrokes: ${this.strokes.length} 笔画`);
  }

  /** 清空 */
  clear(): void {
    this.stop();
    this.strokes = [];
    this.currentStrokeIndex = 0;
    this.state = ReplayState.IDLE;
  }

  // ── 回放控制 ──

  /** 开始回放（从头开始） */
  play(): void {
    if (this.strokes.length === 0) return;
    if (this.state === ReplayState.FINISHED) {
      this.reset();
    }
    this.state = ReplayState.PLAYING;
    this.scheduleNext();
    this.notify();
  }

  /** 暂停 */
  pause(): void {
    if (this.state !== ReplayState.PLAYING) return;
    this.state = ReplayState.PAUSED;
    this.cancelTimer();
    this.notify();
  }

  /** 恢复 */
  resume(): void {
    if (this.state !== ReplayState.PAUSED) return;
    this.state = ReplayState.PLAYING;
    this.scheduleNext();
    this.notify();
  }

  /** 停止并重置 */
  stop(): void {
    this.cancelTimer();
    this.state = ReplayState.IDLE;
    // 隐藏所有笔画
    this.reset();
    this.notify();
  }

  /** 重置到起点 */
  reset(): void {
    this.cancelTimer();
    this.currentStrokeIndex = 0;
    this.state = ReplayState.IDLE;
    // 隐藏所有笔画
    for (const s of this.strokes) {
      if (this.visibilityCb) this.visibilityCb(s.id, false);
    }
    this.notify();
  }

  /** 设置播放速度 */
  setSpeed(speed: number): void {
    this.speed = Math.max(0.25, Math.min(8, speed));
  }

  // ── 步进模式 ──

  /** 前进一步（显示下一笔） */
  stepForward(): void {
    if (this.currentStrokeIndex >= this.strokes.length) return;
    this.cancelTimer();
    this.state = ReplayState.PAUSED;
    this.showStroke(this.currentStrokeIndex);
    this.currentStrokeIndex++;
    if (this.currentStrokeIndex >= this.strokes.length) {
      this.state = ReplayState.FINISHED;
    }
    this.notify();
  }

  /** 后退一步（隐藏最后一笔） */
  stepBackward(): void {
    if (this.currentStrokeIndex <= 0) return;
    this.cancelTimer();
    this.state = ReplayState.PAUSED;
    this.currentStrokeIndex--;
    this.hideStroke(this.currentStrokeIndex);
    this.notify();
  }

  /** 跳转到指定进度（0-1） */
  seekTo(progress: number): void {
    this.cancelTimer();
    const target = Math.round(progress * this.strokes.length);
    // 显示前 target 笔，隐藏其余
    for (let i = 0; i < this.strokes.length; i++) {
      if (this.visibilityCb) {
        this.visibilityCb(this.strokes[i].id, i < target);
      }
    }
    this.currentStrokeIndex = target;
    if (this.currentStrokeIndex >= this.strokes.length) {
      this.state = ReplayState.FINISHED;
    } else {
      this.state = ReplayState.PAUSED;
    }
    this.notify();
  }

  // ── 内部 ──

  private showStroke(index: number): void {
    if (index < 0 || index >= this.strokes.length) return;
    if (this.visibilityCb) {
      this.visibilityCb(this.strokes[index].id, true);
    }
  }

  private hideStroke(index: number): void {
    if (index < 0 || index >= this.strokes.length) return;
    if (this.visibilityCb) {
      this.visibilityCb(this.strokes[index].id, false);
    }
  }

  private scheduleNext(): void {
    if (this.state !== ReplayState.PLAYING) return;
    if (this.currentStrokeIndex >= this.strokes.length) {
      this.state = ReplayState.FINISHED;
      this.notify();
      return;
    }

    // 计算间隔
    let interval = this.baseInterval;
    if (this.currentStrokeIndex > 0 && this.currentStrokeIndex < this.strokes.length) {
      const dt = this.strokes[this.currentStrokeIndex].timestamp -
        this.strokes[this.currentStrokeIndex - 1].timestamp;
      if (dt > 0) interval = Math.min(dt, 2000); // 上限 2s
    }
    interval = interval / this.speed;

    this.timer = setTimeout(() => {
      this.showStroke(this.currentStrokeIndex);
      this.currentStrokeIndex++;
      this.notify();
      this.scheduleNext();
    }, interval);
  }

  private cancelTimer(): void {
    if (this.timer !== null) {
      clearTimeout(this.timer);
      this.timer = null;
    }
  }

  // ── 事件 ──

  addListener(cb: ReplayProgressCallback): void {
    this.listeners.push(cb);
  }

  removeListener(cb: ReplayProgressCallback): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }

  private notify(): void {
    for (const cb of this.listeners) {
      cb(this.state, this.currentStrokeIndex, this.strokes.length, this.progress);
    }
  }

  destroy(): void {
    this.cancelTimer();
    this.listeners = [];
  }
}
