/**
 * GestureEnhancer.ets — 手势操作增强（P2 扩展）
 *
 * 提供高级手势识别：三指手势、长按右键菜单、自定义手势等。
 */
import { Logger } from '../common/Logger';

const TAG = 'GestureEnhancer';

export interface GestureEvent {
  type: string;
  x: number;
  y: number;
  fingers: number;
  timestamp: number;
  scale?: number;
}

/** 手势类型常量（ArkTS 跨模块用 class static 替代 enum） */
export class GestureType {
  static readonly THREE_FINGER_UNDO: string = 'THREE_FINGER_UNDO';
  static readonly THREE_FINGER_REDO: string = 'THREE_FINGER_REDO';
  static readonly DOUBLE_TAP: string = 'DOUBLE_TAP';
  static readonly LONG_PRESS: string = 'LONG_PRESS';
  static readonly SWIPE_LEFT: string = 'SWIPE_LEFT';
  static readonly SWIPE_RIGHT: string = 'SWIPE_RIGHT';
  static readonly PINCH_ZOOM: string = 'PINCH_ZOOM';
}

export interface GestureAction {
  name: string;
  description: string;
  gestureType: string;
  action: string;
}

export class GestureEnhancer {
  private static instance: GestureEnhancer;
  private actions: GestureAction[] = [];

  static getInstance(): GestureEnhancer {
    if (!GestureEnhancer.instance) {
      GestureEnhancer.instance = new GestureEnhancer();
    }
    return GestureEnhancer.instance;
  }

  registerAction(name: string, description: string, gestureType: string, action: string): void {
    const ga: GestureAction = {
      name: name,
      description: description,
      gestureType: gestureType,
      action: action
    };
    this.actions.push(ga);
  }

  getActions(): GestureAction[] {
    return this.actions;
  }

  matchGesture(event: GestureEvent): GestureAction | null {
    for (const a of this.actions) {
      if (a.gestureType === event.type) {
        return a;
      }
    }
    return null;
  }

  /** 三指手势检测 */
  detectThreeFingerTap(touches: number): boolean {
    return touches >= 3;
  }

  /** 长按检测 */
  detectLongPress(pressDuration: number, threshold: number): boolean {
    return pressDuration >= threshold;
  }

  /** 获取默认手势配置 */
  getDefaultActions(): GestureAction[] {
    const defaults: GestureAction[] = [
      { name: '撤销', description: '双指左滑撤销', gestureType: 'two_finger_swipe_left', action: 'undo' },
      { name: '重做', description: '双指右滑重做', gestureType: 'two_finger_swipe_right', action: 'redo' },
      { name: '保存', description: '三指下滑保存', gestureType: 'three_finger_swipe_down', action: 'save' }
    ];
    return defaults;
  }
}
