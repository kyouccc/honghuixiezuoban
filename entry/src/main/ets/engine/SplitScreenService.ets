/**
 * SplitScreenService.ets — 分屏/多窗口（P2 扩展）
 *
 * 提供笔记分屏对比、多窗口打开功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'SplitScreenService';

export interface SplitScreenConfig {
  leftNoteId: string;
  rightNoteId: string;
  splitRatio: number;
  syncScroll: boolean;
}

export class SplitScreenService {
  private static instance: SplitScreenService;
  private _active: boolean = false;
  private _config: SplitScreenConfig | null = null;

  static getInstance(): SplitScreenService {
    if (!SplitScreenService.instance) {
      SplitScreenService.instance = new SplitScreenService();
    }
    return SplitScreenService.instance;
  }

  get active(): boolean { return this._active; }

  openSplit(leftNoteId: string, rightNoteId: string, ratio: number, syncScroll: boolean): void {
    this._config = {
      leftNoteId: leftNoteId,
      rightNoteId: rightNoteId,
      splitRatio: ratio,
      syncScroll: syncScroll
    };
    this._active = true;
    Logger.info(TAG, `openSplit: ${leftNoteId} | ${rightNoteId}`);
  }

  closeSplit(): void {
    this._active = false;
    this._config = null;
  }

  updateRatio(ratio: number): void {
    if (this._config) {
      this._config.splitRatio = ratio;
    }
  }

  getConfig(): SplitScreenConfig | null {
    return this._config;
  }
}
