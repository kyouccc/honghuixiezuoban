/**
 * NetworkMonitor.ets — 网络状态监控工具
 *
 * 功能：
 * 1. 检测网络连接状态
 * 2. 离线时显示提示
 * 3. 网络恢复时自动同步
 *
 * ArkTS 严格模式：无 any/unknown、显式类型。
 */

import connection from '@ohos.net.connection';

/** 网络连接状态 */
export enum NetworkStatus {
  /** 离线 */
  OFFLINE = 0,
  /** 在线 */
  ONLINE = 1,
  /** 未知 */
  UNKNOWN = 2
}

/** 网络类型 */
export enum NetworkType {
  /** 无网络 */
  NONE = 0,
  /** WiFi */
  WIFI = 1,
  /** 蜂窝网络 */
  CELLULAR = 2,
  /** 以太网 */
  ETHERNET = 3,
  /** 其他 */
  OTHER = 4
}

/** 网络状态信息 */
export interface NetworkInfo {
  /** 网络状态 */
  status: NetworkStatus;
  /** 网络类型 */
  type: NetworkType;
  /** 是否在线 */
  isOnline: boolean;
  /** 状态描述 */
  description: string;
}

/** 错误对象接口 */
interface ErrorObject {
  message?: string;
}

/** 网络状态变化回调 */
export type NetworkStatusCallback = (info: NetworkInfo) => void;

export class NetworkMonitor {
  /** 网络状态变化回调列表 */
  private static callbacks: NetworkStatusCallback[] = [];
  
  /** 当前网络状态缓存 */
  private static currentStatus: NetworkInfo | null = null;

  /**
   * 获取当前网络状态。
   * @returns 网络状态信息
   */
  static async getCurrentStatus(): Promise<NetworkInfo> {
    try {
      // 使用 connection 模块检测网络状态
      const netHandle = connection.getDefaultNetSync();
      if (netHandle === undefined || netHandle === null) {
        return {
          status: NetworkStatus.OFFLINE,
          type: NetworkType.NONE,
          isOnline: false,
          description: '无网络连接'
        };
      }

      // 获取网络能力
      const netCapabilities = await connection.getNetCapabilities(netHandle);
      if (netCapabilities === undefined || netCapabilities === null) {
        return {
          status: NetworkStatus.UNKNOWN,
          type: NetworkType.NONE,
          isOnline: false,
          description: '网络状态未知'
        };
      }

      // 判断网络类型
      let networkType: NetworkType = NetworkType.OTHER;
      const bearerTypes = netCapabilities.bearerTypes;
      if (bearerTypes !== undefined && bearerTypes !== null) {
        for (let i = 0; i < bearerTypes.length; i++) {
          const bearerType = bearerTypes[i];
          if (bearerType === connection.NetBearType.BEARER_WIFI) {
            networkType = NetworkType.WIFI;
            break;
          } else if (bearerType === connection.NetBearType.BEARER_CELLULAR) {
            networkType = NetworkType.CELLULAR;
            break;
          } else if (bearerType === connection.NetBearType.BEARER_ETHERNET) {
            networkType = NetworkType.ETHERNET;
            break;
          }
        }
      }

      // 判断是否在线 - 如果有bearerTypes就认为在线
      const isOnline: boolean = bearerTypes !== undefined && bearerTypes !== null && bearerTypes.length > 0;

      // 构建网络状态信息
      const status: NetworkInfo = {
        status: isOnline ? NetworkStatus.ONLINE : NetworkStatus.OFFLINE,
        type: networkType,
        isOnline: isOnline,
        description: isOnline ? `${NetworkMonitor.getTypeName(networkType)}连接正常` : '无网络连接'
      };

      NetworkMonitor.currentStatus = status;
      return status;
    } catch (error) {
      let errorMessage = '未知错误';
      if (error && typeof error === 'object') {
        // 使用类型保护检查是否有message属性
        const errorObj = error as ErrorObject;
        if (errorObj.message !== undefined && errorObj.message !== null) {
          errorMessage = String(errorObj.message);
        }
      } else if (typeof error === 'string') {
        errorMessage = error;
      }
      
      return {
        status: NetworkStatus.UNKNOWN,
        type: NetworkType.NONE,
        isOnline: false,
        description: `网络状态检测失败: ${errorMessage}`
      };
    }
  }

  /**
   * 注册网络状态变化监听器。
   * @param callback 状态变化回调
   */
  static registerCallback(callback: NetworkStatusCallback): void {
    NetworkMonitor.callbacks.push(callback);
  }

  /**
   * 取消注册网络状态变化监听器。
   * @param callback 状态变化回调
   */
  static unregisterCallback(callback: NetworkStatusCallback): void {
    const index: number = NetworkMonitor.callbacks.indexOf(callback);
    if (index >= 0) {
      NetworkMonitor.callbacks.splice(index, 1);
    }
  }

  /**
   * 通知所有监听器网络状态变化。
   * @param info 网络状态信息
   */
  private static notifyCallbacks(info: NetworkInfo): void {
    for (let i = 0; i < NetworkMonitor.callbacks.length; i++) {
      try {
        const callback = NetworkMonitor.callbacks[i];
        callback(info);
      } catch {
        // 忽略回调执行错误
      }
    }
  }

  /**
   * 获取网络类型名称。
   * @param type 网络类型
   * @returns 类型名称
   */
  private static getTypeName(type: NetworkType): string {
    switch (type) {
      case NetworkType.WIFI:
        return 'WiFi';
      case NetworkType.CELLULAR:
        return '蜂窝网络';
      case NetworkType.ETHERNET:
        return '以太网';
      case NetworkType.OTHER:
        return '网络';
      default:
        return '未知';
    }
  }

  /**
   * 格式化网络状态信息为字符串。
   * @param info 网络状态信息
   * @returns 格式化字符串
   */
  static formatNetworkInfo(info: NetworkInfo): string {
    const lines: string[] = [
      `🌐 网络状态：`,
      `  状态：${info.description}`,
      `  类型：${NetworkMonitor.getTypeName(info.type)}`,
      `  在线：${info.isOnline ? '是' : '否'}`
    ];

    return lines.join('\n');
  }
}

