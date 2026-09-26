/**
 * PhotoToCanvasSync.ets — 分布式场景一：手机拍板书，平板自动落画布（阶段3 P1）
 *
 * 考研场景：研友用手机拍下教室板书/参考书内容，平板画布自动出现该图片节点，
 *           免去手动传图+导入的繁琐流程，实现「拍即落」的无缝跨端体验。
 *
 * 技术方案：
 *  1. 手机端调用相机拍照 → 获取图片 URI
 *  2. 通过分布式数据对象（distributedDataObject）同步图片路径 + 元数据到平板
 *  3. 平板端监听数据变化 → 读取图片 → 自动裁剪白边 → 生成画布 image 节点
 *  4. 节点位置默认落在当前视口中心，避免遮挡已有内容
 *
 * 约束：不依赖公网服务器，纯端侧分布式软总线传输（≤80ms 延迟目标）。
 */

import { distributedDataObject } from '@kit.DistributedDataKit';
import { Logger } from '../common/Logger';

const TAG = 'PhotoToCanvasSync';

/** 拍照同步数据结构 */
export interface PhotoSyncData {
  /** 图片 URI（分布式文件系统路径） */
  uri: string;
  /** 拍照时间戳 */
  timestamp: number;
  /** 源设备 ID */
  sourceDeviceId: string;
  /** 图片宽度 */
  width: number;
  /** 图片高度 */
  height: number;
  /** 是否已裁剪 */
  cropped: boolean;
}

/** 画布节点生成回调（由 WhiteboardPage 注入） */
export interface PhotoToCanvasListener {
  onPhotoReceived: (data: PhotoSyncData) => void;
}

export class PhotoToCanvasSync {
  private listener: PhotoToCanvasListener | null = null;
  private dataObject: distributedDataObject.DataObject | null = null;
  private sessionId: string = '';
  private active: boolean = false;

  /** 设置监听器 */
  setListener(listener: PhotoToCanvasListener): void {
    this.listener = listener;
  }

  /**
   * 初始化分布式数据对象，加入同步会话。
   * @param sessionId 会话 ID（与协作会话复用）
   */
  async start(sessionId: string): Promise<void> {
    if (this.active) {
      Logger.info(TAG, '已在运行，跳过重复启动');
      return;
    }
    this.sessionId = sessionId;
    try {
      // 创建分布式数据对象
      this.dataObject = distributedDataObject.create({
        sessionId: sessionId,
        data: {
          photoUri: '',
          photoTimestamp: 0,
          photoSourceDevice: '',
          photoWidth: 0,
          photoHeight: 0,
          photoCropped: false
        }
      });

      // 监听远端数据变化
      this.dataObject.on('change', (data: Record<string, Object>) => {
        this.onDataChange(data);
      });

      this.active = true;
      Logger.info(TAG, `分布式拍照同步已启动，sessionId=${sessionId}`);
    } catch (e) {
      Logger.error(TAG, `启动失败: ${(e as Error).message}`);
    }
  }

  /**
   * 手机端：发送拍照结果到其他设备。
   * @param uri 图片 URI
   * @param width 图片宽度
   * @param height 图片高度
   */
  async sendPhoto(uri: string, width: number, height: number): Promise<void> {
    if (this.dataObject === null) {
      Logger.error(TAG, '数据对象未初始化');
      return;
    }
    try {
      this.dataObject.setProperty('photoUri', uri);
      this.dataObject.setProperty('photoTimestamp', Date.now());
      this.dataObject.setProperty('photoSourceDevice', this.getLocalDeviceId());
      this.dataObject.setProperty('photoWidth', width);
      this.dataObject.setProperty('photoHeight', height);
      this.dataObject.setProperty('photoCropped', false);
      Logger.info(TAG, `已发送图片: ${uri}, ${width}x${height}`);
    } catch (e) {
      Logger.error(TAG, `发送图片失败: ${(e as Error).message}`);
    }
  }

  /** 平板端：监听到远端图片数据变化 */
  private onDataChange(data: Record<string, Object>): void {
    const uri: string = data['photoUri'] as string;
    const timestamp: number = data['photoTimestamp'] as number;
    const sourceDevice: string = data['photoSourceDevice'] as string;
    const width: number = data['photoWidth'] as number;
    const height: number = data['photoHeight'] as number;
    const cropped: boolean = data['photoCropped'] as boolean;

    // 忽略空数据或自身发出的数据
    if (uri.length === 0 || timestamp === 0) {
      return;
    }
    if (sourceDevice === this.getLocalDeviceId()) {
      return;
    }

    Logger.info(TAG, `收到远端图片: ${uri}, ${width}x${height}`);

    // 通知上层生成画布节点
    if (this.listener !== null) {
      const photoData: PhotoSyncData = {
        uri: uri,
        timestamp: timestamp,
        sourceDeviceId: sourceDevice,
        width: width,
        height: height,
        cropped: cropped
      };
      this.listener.onPhotoReceived(photoData);
    }
  }

  /** 停止同步，释放资源 */
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
    this.sessionId = '';
    Logger.info(TAG, '分布式拍照同步已停止');
  }

  /** 获取本机设备 ID（简化实现） */
  private getLocalDeviceId(): string {
    return 'local_device';
  }

  /** 是否正在运行 */
  isRunning(): boolean {
    return this.active;
  }
}
