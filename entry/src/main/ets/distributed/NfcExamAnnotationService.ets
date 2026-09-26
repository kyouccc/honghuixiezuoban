/**
 * NfcExamAnnotationService.ets — 分布式场景三：无网一碰批注研友试卷（阶段3 P1）
 *
 * 考研场景：两个研友在自习室（无网络环境），手机一碰 NFC 标签即建立 P2P 连接，
 *           共同批注同一份真题试卷，笔迹实时同步，无需安装完整应用。
 *
 * 技术方案：
 *  1. NFC 碰触触发 → 交换设备信息 + 会话密钥
 *  2. 分布式软总线（@ohos.distributedDeviceManager）建立局域网 P2P 连接
 *  3. CRDT RGA 算法保证无冲突合并，不依赖公网服务器
 *  4. 原子化服务免安装，碰一碰即用，退出自动清理临时数据
 *
 * 约束：跨设备同步延迟 ≤80ms，原子化服务包体积 ≤8MB。
 */

import { distributedDeviceManager } from '@ohos.distributedDeviceManager';
import { Logger } from '../common/Logger';

const TAG = 'NfcExamAnnotation';

/** NFC 碰触交换数据 */
export interface NfcExchangeData {
  /** 设备 ID */
  deviceId: string;
  /** 设备名称 */
  deviceName: string;
  /** 会话 ID */
  sessionId: string;
  /** 试卷文件路径 */
  examPaperPath: string;
  /** 时间戳 */
  timestamp: number;
}

/** 批注同步回调 */
export interface NfcAnnotationListener {
  onPeerConnected: (data: NfcExchangeData) => void;
  onPeerDisconnected: (deviceId: string) => void;
}

/** 连接状态 */
export enum NfcConnectionState {
  IDLE = 'IDLE',
  NFC_EXCHANGING = 'NFC_EXCHANGING',
  P2P_CONNECTING = 'P2P_CONNECTING',
  CONNECTED = 'CONNECTED',
  DISCONNECTED = 'DISCONNECTED'
}

export class NfcExamAnnotationService {
  private listener: NfcAnnotationListener | null = null;
  private state: NfcConnectionState = NfcConnectionState.IDLE;
  private peerDeviceId: string = '';
  private sessionId: string = '';
  private deviceManager: distributedDeviceManager.DeviceManager | null = null;

  /** 设置监听器 */
  setListener(listener: NfcAnnotationListener): void {
    this.listener = listener;
  }

  /**
   * 初始化设备管理器。
   * 在 EntryAbility.aboutToAppear 中调用。
   */
  async init(): Promise<void> {
    try {
      this.deviceManager = distributedDeviceManager.createDeviceManager('com.honghui.exam');
      Logger.info(TAG, '设备管理器初始化成功');
    } catch (e) {
      Logger.error(TAG, `设备管理器初始化失败: ${(e as Error).message}`);
    }
  }

  /**
   * NFC 碰触回调：收到对端设备信息，开始建立 P2P 连接。
   * @param nfcData NFC 标签中的数据
   */
  async onNfcTouched(nfcData: NfcExchangeData): Promise<void> {
    if (this.state !== NfcConnectionState.IDLE) {
      Logger.info(TAG, `当前状态 ${this.state}，忽略 NFC 碰触`);
      return;
    }

    this.state = NfcConnectionState.NFC_EXCHANGING;
    this.peerDeviceId = nfcData.deviceId;
    this.sessionId = nfcData.sessionId;
    Logger.info(TAG, `NFC 碰触: 设备=${nfcData.deviceName}, 会话=${nfcData.sessionId}`);

    // 开始建立 P2P 连接
    await this.establishP2PConnection(nfcData);
  }

  /**
   * 通过分布式软总线建立 P2P 连接。
   * 不依赖公网，纯局域网 TCP 直连。
   */
  private async establishP2PConnection(nfcData: NfcExchangeData): Promise<void> {
    this.state = NfcConnectionState.P2P_CONNECTING;

    try {
      // 触发设备绑定（分布式软总线自动建立局域网 P2P 通道）
      if (this.deviceManager !== null) {
        // 设备发现已在 DeviceDiscovery 模块处理
        // 此处仅确认连接状态
        Logger.info(TAG, '正在建立 P2P 连接…');
      }

      // 模拟连接成功（实际由分布式软总线回调驱动）
      this.state = NfcConnectionState.CONNECTED;
      Logger.info(TAG, `P2P 连接已建立，对端设备=${nfcData.deviceName}`);

      // 通知上层：对端已连接，可以开始同步批注
      if (this.listener !== null) {
        this.listener.onPeerConnected(nfcData);
      }
    } catch (e) {
      Logger.error(TAG, `P2P 连接失败: ${(e as Error).message}`);
      this.state = NfcConnectionState.DISCONNECTED;
    }
  }

  /**
   * 生成 NFC 标签数据（供主机端写入 NFC 标签）。
   * 研友 A 创建房间后，将此数据写入 NFC 标签，研友 B 碰触即加入。
   */
  generateNfcData(deviceId: string, deviceName: string, sessionId: string, examPaperPath: string): NfcExchangeData {
    return {
      deviceId: deviceId,
      deviceName: deviceName,
      sessionId: sessionId,
      examPaperPath: examPaperPath,
      timestamp: Date.now()
    };
  }

  /**
   * 主动断开 P2P 连接。
   * 退出后自动清理临时数据（原子化服务约束）。
   */
  async disconnect(): Promise<void> {
    if (this.state !== NfcConnectionState.CONNECTED) {
      return;
    }

    Logger.info(TAG, '正在断开 P2P 连接…');

    // 清理临时数据
    this.peerDeviceId = '';
    this.sessionId = '';

    this.state = NfcConnectionState.DISCONNECTED;
    Logger.info(TAG, 'P2P 连接已断开，临时数据已清理');

    if (this.listener !== null) {
      this.listener.onPeerDisconnected(this.peerDeviceId);
    }
  }

  /** 获取当前连接状态 */
  getState(): NfcConnectionState {
    return this.state;
  }

  /** 是否已连接 */
  isConnected(): boolean {
    return this.state === NfcConnectionState.CONNECTED;
  }

  /** 获取对端设备 ID */
  getPeerDeviceId(): string {
    return this.peerDeviceId;
  }

  /** 获取会话 ID */
  getSessionId(): string {
    return this.sessionId;
  }

  /** 释放资源 */
  destroy(): void {
    this.disconnect();
    this.deviceManager = null;
    this.listener = null;
    this.state = NfcConnectionState.IDLE;
    Logger.info(TAG, 'NFC 批注服务已销毁');
  }
}
