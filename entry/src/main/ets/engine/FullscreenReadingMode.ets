/**
 * FullscreenReadingMode.ets — 全屏阅读模式（P0 缺失功能）
 *
 * 功能：
 *  1. 一键隐藏全部工具栏/面板/状态栏，纯画布展示
 *  2. 点击屏幕边缘翻页（多页笔记）
 *  3. 底部轻触显示简易进度条+退出按钮
 *  4. 手势：单指平移，双指缩放
 */
import { Logger } from '../common/Logger';

const TAG = 'FullscreenReadingMode';

/** 阅读模式状态 */
export enum ReadingState {
  INACTIVE = 'inactive',
  ACTIVE = 'active',
  SHOW_OVERLAY = 'show_overlay'  // 显示底部叠加层
}

export interface ReadingConfig {
  /** 是否显示页码 */
  showPageNumber: boolean;
  /** 是否允许双指缩放 */
  allowPinchZoom: boolean;
  /** 是否锁定平移 */
  lockPan: boolean;
  /** 点击翻页 */
  tapToTurnPage: boolean;
  /** 自动翻页间隔（秒），0=不自动 */
  autoTurnInterval: number;
}

export class FullscreenReadingMode {
  private static instance: FullscreenReadingMode;
  private _state: ReadingState = ReadingState.INACTIVE;
  private _config: ReadingConfig = {
    showPageNumber: true,
    allowPinchZoom: true,
    lockPan: false,
    tapToTurnPage: true,
    autoTurnInterval: 0
  };
  private autoTurnTimer: number = -1;
  private overlayHideTimer: number = -1;

  static getInstance(): FullscreenReadingMode {
    if (!FullscreenReadingMode.instance) {
      FullscreenReadingMode.instance = new FullscreenReadingMode();
    }
    return FullscreenReadingMode.instance;
  }

  get state(): ReadingState { return this._state; }
  get config(): ReadingConfig {
    return {
      showPageNumber: this._config.showPageNumber,
      allowPinchZoom: this._config.allowPinchZoom,
      lockPan: this._config.lockPan,
      tapToTurnPage: this._config.tapToTurnPage,
      autoTurnInterval: this._config.autoTurnInterval
    };
  }

  /** 进入阅读模式 */
  enter(): void {
    this._state = ReadingState.ACTIVE;
    this.startAutoTurn();
    Logger.info(TAG, '进入全屏阅读模式');
  }

  /** 退出阅读模式 */
  exit(): void {
    this._state = ReadingState.INACTIVE;
    this.stopAutoTurn();
    this.clearOverlayTimer();
    Logger.info(TAG, '退出全屏阅读模式');
  }

  /** 切换阅读模式 */
  toggle(): boolean {
    if (this._state === ReadingState.INACTIVE) {
      this.enter();
      return true;
    } else {
      this.exit();
      return false;
    }
  }

  /** 显示叠加层（底部进度条+控制） */
  showOverlay(): void {
    if (this._state === ReadingState.ACTIVE) {
      this._state = ReadingState.SHOW_OVERLAY;
      this.clearOverlayTimer();
      this.overlayHideTimer = setTimeout(() => {
        if (this._state === ReadingState.SHOW_OVERLAY) {
          this._state = ReadingState.ACTIVE;
        }
      }, 3000);
    }
  }

  /** 隐藏叠加层 */
  hideOverlay(): void {
    if (this._state === ReadingState.SHOW_OVERLAY) {
      this._state = ReadingState.ACTIVE;
    }
  }

  /** 点击处理：返回 'prev' | 'next' | null */
  handleTap(tapX: number, containerWidth: number): string | null {
    if (!this._config.tapToTurnPage) return null;
    const third = containerWidth / 3;
    if (tapX < third) return 'prev';
    if (tapX > third * 2) return 'next';
    return null;
  }

  /** 更新配置 - 逐字段复制以避免Object.assign */
  updateConfig(showPageNumber: boolean, allowPinchZoom: boolean,
    lockPan: boolean, tapToTurnPage: boolean, autoTurnInterval: number): void {
    this._config.showPageNumber = showPageNumber;
    this._config.allowPinchZoom = allowPinchZoom;
    this._config.lockPan = lockPan;
    this._config.tapToTurnPage = tapToTurnPage;
    this._config.autoTurnInterval = autoTurnInterval;
    if (autoTurnInterval > 0) {
      this.restartAutoTurn();
    }
  }

  private startAutoTurn(): void {
    if (this._config.autoTurnInterval > 0) {
      this.autoTurnTimer = setInterval(() => {
        // 触发翻页回调，由外部注入
        if (this.onAutoTurn) {
          this.onAutoTurn();
        }
      }, this._config.autoTurnInterval * 1000);
    }
  }

  private stopAutoTurn(): void {
    if (this.autoTurnTimer > 0) {
      clearInterval(this.autoTurnTimer);
      this.autoTurnTimer = -1;
    }
  }

  private restartAutoTurn(): void {
    this.stopAutoTurn();
    this.startAutoTurn();
  }

  private clearOverlayTimer(): void {
    if (this.overlayHideTimer > 0) {
      clearTimeout(this.overlayHideTimer);
      this.overlayHideTimer = -1;
    }
  }

  /** 自动翻页回调（由外部设置） */
  onAutoTurn: (() => void) | null = null;
}
