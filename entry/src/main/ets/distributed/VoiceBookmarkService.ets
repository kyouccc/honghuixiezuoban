/**
 * VoiceBookmarkService.ets — 分布式场景二：手表语音标考点，画布自动加书签（阶段3 P1）
 *
 * 考研场景：考研人在背诵/听课过程中，用手表语音说出「这个是必背知识点」，
 *           画布自动在当前位置生成便签 + 书签锚点，无需放下笔/切应用。
 *
 * 技术方案：
 *  1. 手表原子化服务接收语音输入 → 端侧语音转文字（@kit.SpeechServicesKit）
 *  2. 通过分布式数据对象同步文字 + 书签类型到手机/平板
 *  3. 手机/平板端监听 → 在当前视口中心生成 sticky 节点 + bookmark 节点
 *  4. 书签类型通过语音关键词自动判断：「必背」→必背、「易错」→易错、默认→真题
 *
 * 约束：原子化服务包体积 ≤8MB，不申请非必要权限，退出后自动清理临时数据。
 */

import { distributedDataObject } from '@kit.DistributedDataKit';
import { Logger } from '../common/Logger';
import { BookmarkType } from '../engine/types/BoardModel';

const TAG = 'VoiceBookmarkService';

/** 语音书签同步数据结构 */
export interface VoiceBookmarkData {
  /** 语音转文字结果 */
  text: string;
  /** 书签类型（必背/易错/真题） */
  bookmarkType: string;
  /** 时间戳 */
  timestamp: number;
  /** 源设备 ID */
  sourceDeviceId: string;
}

/** 语音书签回调（由 WhiteboardPage 注入） */
export interface VoiceBookmarkListener {
  onVoiceBookmarkReceived: (data: VoiceBookmarkData) => void;
}

export class VoiceBookmarkService {
  private listener: VoiceBookmarkListener | null = null;
  private dataObject: distributedDataObject.DataObject | null = null;
  private active: boolean = false;

  /** 设置监听器 */
  setListener(listener: VoiceBookmarkListener): void {
    this.listener = listener;
  }

  /**
   * 初始化分布式数据对象，加入语音书签同步会话。
   * @param sessionId 会话 ID
   */
  async start(sessionId: string): Promise<void> {
    if (this.active) {
      Logger.info(TAG, '已在运行，跳过重复启动');
      return;
    }
    try {
      this.dataObject = distributedDataObject.create({
        sessionId: sessionId,
        data: {
          voiceText: '',
          voiceBookmarkType: '',
          voiceTimestamp: 0,
          voiceSourceDevice: ''
        }
      });

      this.dataObject.on('change', (data: Record<string, Object>) => {
        this.onDataChange(data);
      });

      this.active = true;
      Logger.info(TAG, `语音书签同步已启动，sessionId=${sessionId}`);
    } catch (e) {
      Logger.error(TAG, `启动失败: ${(e as Error).message}`);
    }
  }

  /**
   * 手表端：发送语音识别结果 + 书签类型到画布设备。
   * @param text 语音转文字结果
   * @param bookmarkType 书签类型
   */
  async sendVoiceBookmark(text: string, bookmarkType: string): Promise<void> {
    if (this.dataObject === null) {
      Logger.error(TAG, '数据对象未初始化');
      return;
    }
    try {
      this.dataObject.setProperty('voiceText', text);
      this.dataObject.setProperty('voiceBookmarkType', bookmarkType);
      this.dataObject.setProperty('voiceTimestamp', Date.now());
      this.dataObject.setProperty('voiceSourceDevice', this.getLocalDeviceId());
      Logger.info(TAG, `已发送语音书签: "${text}", type=${bookmarkType}`);
    } catch (e) {
      Logger.error(TAG, `发送失败: ${(e as Error).message}`);
    }
  }

  /**
   * 从语音文本中自动推断书签类型。
   * 关键词匹配：「必背/背诵/重要」→必背，「易错/注意/小心」→易错，默认→真题
   */
  static inferBookmarkType(text: string): string {
    const lower: string = text.toLowerCase();
    if (lower.includes('必背') || lower.includes('背诵') || lower.includes('重要') || lower.includes('关键')) {
      return BookmarkType.MUST_RECITE;
    }
    if (lower.includes('易错') || lower.includes('注意') || lower.includes('小心') || lower.includes('陷阱')) {
      return BookmarkType.EASY_WRONG;
    }
    return BookmarkType.REAL_QUESTION;
  }

  /** 画布端：监听到远端语音书签数据变化 */
  private onDataChange(data: Record<string, Object>): void {
    const text: string = data['voiceText'] as string;
    const bookmarkType: string = data['voiceBookmarkType'] as string;
    const timestamp: number = data['voiceTimestamp'] as number;
    const sourceDevice: string = data['voiceSourceDevice'] as string;

    if (text.length === 0 || timestamp === 0) {
      return;
    }
    if (sourceDevice === this.getLocalDeviceId()) {
      return;
    }

    Logger.info(TAG, `收到远端语音书签: "${text}", type=${bookmarkType}`);

    if (this.listener !== null) {
      const voiceData: VoiceBookmarkData = {
        text: text,
        bookmarkType: bookmarkType.length > 0 ? bookmarkType : VoiceBookmarkService.inferBookmarkType(text),
        timestamp: timestamp,
        sourceDeviceId: sourceDevice
      };
      this.listener.onVoiceBookmarkReceived(voiceData);
    }
  }

  /** 停止同步 */
  stop(): void {
    if (this.dataObject !== null) {
      try {
        this.dataObject.off('change');
      } catch (e) {
        Logger.error(TAG, `移除监听失败: ${(e as Error).message}`);
      }
      this.dataObject = null;
    }
    this.active = false;
    Logger.info(TAG, '语音书签同步已停止');
  }

  private getLocalDeviceId(): string {
    return 'local_device';
  }

  isRunning(): boolean {
    return this.active;
  }
}
