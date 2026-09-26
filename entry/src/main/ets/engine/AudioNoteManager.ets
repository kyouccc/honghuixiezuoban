/**
 * AudioNoteManager.ets — 录音笔记同步（P0-6）
 *
 * 功能：
 *  1. 录音开始/暂停/停止（startRecording / pauseRecording / stopRecording）；
 *  2. 录音与画布时间戳同步（每段录音关联一个 canvasTimeRange）；
 *  3. 回放指定录音段（playSegment），回放时高亮对应画布笔画；
 *  4. 录音列表管理（listSegments / deleteSegment）；
 *  5. 录音文件路径管理（沙箱目录）。
 *
 * 架构：纯逻辑管理器。实际录音/播放通过外部注入的 AudioRecorderCallback 委托系统 API。
 */

import { Logger } from '../common/Logger';

const TAG = 'AudioNoteManager';

/** 录音段 */
export interface AudioSegment {
  /** 唯一 ID */
  id: string;
  /** 所属笔记 ID */
  noteId: string;
  /** 录音文件路径（沙箱） */
  filePath: string;
  /** 录音开始时的画布时间戳（与笔画时间轴对齐） */
  canvasTimeStart: number;
  /** 录音结束时的画布时间戳 */
  canvasTimeEnd: number;
  /** 录音时长（毫秒） */
  duration: number;
  /** 创建时间 */
  createdAt: number;
  /** 显示名称 */
  label: string;
}

/** 录音状态 */
export enum RecordingState {
  IDLE = 'idle',
  RECORDING = 'recording',
  PAUSED = 'paused',
  PLAYING = 'playing',
}

/** 录音器回调接口（委托系统 @ohos.multimedia.audio） */
export interface AudioRecorderCallback {
  /** 开始录音，返回文件路径 */
  start(outputPath: string): Promise<void>;
  /** 暂停录音 */
  pause(): Promise<void>;
  /** 恢复录音 */
  resume(): Promise<void>;
  /** 停止录音，返回实际时长（ms） */
  stop(): Promise<number>;
}

/** 播放器回调接口 */
export interface AudioPlayerCallback {
  /** 播放指定文件 */
  play(filePath: string): Promise<void>;
  /** 停止播放 */
  stop(): Promise<void>;
  /** 跳转到指定位置（ms） */
  seekTo(positionMs: number): Promise<void>;
}

/** 录音事件回调 */
export type AudioEventCallback = (state: RecordingState, segment: AudioSegment | null) => void;

/** AudioSegment 实现类 */
class AudioSegmentImpl implements AudioSegment {
  id: string;
  noteId: string;
  filePath: string;
  canvasTimeStart: number;
  canvasTimeEnd: number;
  duration: number;
  createdAt: number;
  label: string;

  constructor(id: string, noteId: string, filePath: string,
    canvasTimeStart: number, canvasTimeEnd: number,
    duration: number, createdAt: number, label: string) {
    this.id = id;
    this.noteId = noteId;
    this.filePath = filePath;
    this.canvasTimeStart = canvasTimeStart;
    this.canvasTimeEnd = canvasTimeEnd;
    this.duration = duration;
    this.createdAt = createdAt;
    this.label = label;
  }
}

/** 复制录音段 */
function copySegment(src: AudioSegment): AudioSegment {
  return new AudioSegmentImpl(
    src.id, src.noteId, src.filePath,
    src.canvasTimeStart, src.canvasTimeEnd,
    src.duration, src.createdAt, src.label
  );
}

function genId(): string {
  return `aud_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
}

export class AudioNoteManager {
  /** 录音段列表 */
  private segments: AudioSegment[] = [];
  /** 当前状态 */
  private state: RecordingState = RecordingState.IDLE;
  /** 当前录音的笔记 ID */
  private currentNoteId: string = '';
  /** 当前录音段 */
  private currentSegment: AudioSegment | null = null;
  /** 录音开始时间（墙钟） */
  private recordStartTime: number = 0;
  /** 录音开始时的画布时间戳 */
  private canvasTimeAtStart: number = 0;
  /** 暂停累计时长 */
  private pausedDuration: number = 0;
  /** 暂停开始时间 */
  private pauseStartTime: number = 0;

  // ── 外部注入 ──
  private recorder: AudioRecorderCallback | null = null;
  private player: AudioPlayerCallback | null = null;
  private listeners: AudioEventCallback[] = [];

  /** 沙箱目录路径（外部注入） */
  public getAudioDir: () => string = () => '/data/storage/el2/base/haps/entry/files/audio';

  // ── 依赖注入 ──

  setRecorder(cb: AudioRecorderCallback): void { this.recorder = cb; }
  setPlayer(cb: AudioPlayerCallback): void { this.player = cb; }

  // ── 状态查询 ──

  get currentState(): RecordingState { return this.state; }
  get isRecording(): boolean { return this.state === RecordingState.RECORDING; }
  get isPaused(): boolean { return this.state === RecordingState.PAUSED; }
  get isPlaying(): boolean { return this.state === RecordingState.PLAYING; }
  get activeSegment(): AudioSegment | null { return this.currentSegment; }

  // ── 录音段管理 ──

  /** 列出指定笔记的所有录音段 */
  listSegments(noteId: string): AudioSegment[] {
    return this.segments.filter(s => s.noteId === noteId).map(s => copySegment(s));
  }

  /** 获取所有录音段 */
  listAll(): AudioSegment[] {
    return this.segments.map(s => copySegment(s));
  }

  /** 删除录音段 */
  deleteSegment(segmentId: string): boolean {
    const idx = this.segments.findIndex(s => s.id === segmentId);
    if (idx < 0) return false;
    this.segments.splice(idx, 1);
    Logger.info(TAG, `deleteSegment: ${segmentId}`);
    return true;
  }

  /** 从外部数据恢复 */
  restore(segments: AudioSegment[]): void {
    this.segments = segments.map(s => copySegment(s));
  }

  /** 导出（持久化） */
  exportSegments(): AudioSegment[] {
    return this.segments.map(s => copySegment(s));
  }

  // ── 录音操作 ──

  /**
   * 开始录音。
   * @param noteId 笔记 ID
   * @param canvasTime 当前画布时间戳（用于同步）
   */
  async startRecording(noteId: string, canvasTime: number): Promise<boolean> {
    if (this.state !== RecordingState.IDLE) {
      Logger.warn(TAG, `startRecording: 状态非 IDLE (${this.state})`);
      return false;
    }
    if (!this.recorder) {
      Logger.error(TAG, 'startRecording: 未注入 recorder');
      return false;
    }

    const audioDir = this.getAudioDir();
    const fileName = `${genId()}.m4a`;
    const filePath = `${audioDir}/${fileName}`;

    try {
      await this.recorder.start(filePath);
    } catch (e) {
      Logger.error(TAG, `startRecording 失败: ${e}`);
      return false;
    }

    this.currentNoteId = noteId;
    this.recordStartTime = Date.now();
    this.canvasTimeAtStart = canvasTime;
    this.pausedDuration = 0;

    this.currentSegment = new AudioSegmentImpl(
      genId(), noteId, filePath,
      canvasTime, canvasTime, 0, Date.now(),
      `录音 ${this.segments.filter(s => s.noteId === noteId).length + 1}`
    );

    this.state = RecordingState.RECORDING;
    this.notify();
    Logger.info(TAG, `startRecording: noteId=${noteId}, canvasTime=${canvasTime}`);
    return true;
  }

  /** 暂停录音 */
  async pauseRecording(): Promise<boolean> {
    if (this.state !== RecordingState.RECORDING) return false;
    if (!this.recorder) return false;

    try {
      await this.recorder.pause();
    } catch (e) {
      Logger.error(TAG, `pauseRecording 失败: ${e}`);
      return false;
    }

    this.pauseStartTime = Date.now();
    this.state = RecordingState.PAUSED;
    this.notify();
    return true;
  }

  /** 恢复录音 */
  async resumeRecording(): Promise<boolean> {
    if (this.state !== RecordingState.PAUSED) return false;
    if (!this.recorder) return false;

    try {
      await this.recorder.resume();
    } catch (e) {
      Logger.error(TAG, `resumeRecording 失败: ${e}`);
      return false;
    }

    this.pausedDuration += Date.now() - this.pauseStartTime;
    this.state = RecordingState.RECORDING;
    this.notify();
    return true;
  }

  /**
   * 停止录音。
   * @param canvasTime 当前画布时间戳
   */
  async stopRecording(canvasTime: number): Promise<AudioSegment | null> {
    if (this.state === RecordingState.IDLE) return null;
    if (!this.recorder || !this.currentSegment) return null;

    let actualDuration = 0;
    try {
      actualDuration = await this.recorder.stop();
    } catch (e) {
      Logger.error(TAG, `stopRecording 失败: ${e}`);
      this.state = RecordingState.IDLE;
      this.currentSegment = null;
      this.notify();
      return null;
    }

    // 计算总时长
    if (actualDuration <= 0) {
      actualDuration = Date.now() - this.recordStartTime - this.pausedDuration;
    }

    this.currentSegment.duration = actualDuration;
    this.currentSegment.canvasTimeEnd = canvasTime;

    this.segments.push(this.currentSegment);
    const result = this.currentSegment;

    this.state = RecordingState.IDLE;
    this.currentSegment = null;
    this.notify();
    Logger.info(TAG, `stopRecording: duration=${actualDuration}ms, segments=${this.segments.length}`);
    return result;
  }

  // ── 回放 ──

  /** 播放指定录音段 */
  async playSegment(segmentId: string): Promise<boolean> {
    if (!this.player) {
      Logger.error(TAG, 'playSegment: 未注入 player');
      return false;
    }
    const segment = this.segments.find(s => s.id === segmentId);
    if (!segment) return false;

    try {
      await this.player.play(segment.filePath);
    } catch (e) {
      Logger.error(TAG, `playSegment 失败: ${e}`);
      return false;
    }

    this.state = RecordingState.PLAYING;
    this.currentSegment = segment;
    this.notify();
    return true;
  }

  /** 停止回放 */
  async stopPlayback(): Promise<boolean> {
    if (this.state !== RecordingState.PLAYING) return false;
    if (!this.player) return false;

    try {
      await this.player.stop();
    } catch (e) {
      Logger.error(TAG, `stopPlayback 失败: ${e}`);
      return false;
    }

    this.state = RecordingState.IDLE;
    this.currentSegment = null;
    this.notify();
    return true;
  }

  /**
   * 根据画布时间戳查找对应的录音段。
   * 用于回放画布动画时同步播放对应录音。
   */
  findSegmentByCanvasTime(canvasTime: number): AudioSegment | null {
    for (const s of this.segments) {
      if (canvasTime >= s.canvasTimeStart && canvasTime <= s.canvasTimeEnd) {
        return s;
      }
    }
    return null;
  }

  /**
   * 将画布时间戳转换为录音内的时间位置（ms）。
   * 用于在回放录音时跳转到对应位置。
   */
  canvasTimeToAudioPosition(segment: AudioSegment, canvasTime: number): number {
    const ratio = segment.duration / Math.max(1, segment.canvasTimeEnd - segment.canvasTimeStart);
    return (canvasTime - segment.canvasTimeStart) * ratio;
  }

  // ── 事件 ──

  addListener(cb: AudioEventCallback): void {
    this.listeners.push(cb);
  }

  removeListener(cb: AudioEventCallback): void {
    const idx = this.listeners.indexOf(cb);
    if (idx >= 0) this.listeners.splice(idx, 1);
  }

  private notify(): void {
    for (const cb of this.listeners) {
      cb(this.state, this.currentSegment);
    }
  }
}
