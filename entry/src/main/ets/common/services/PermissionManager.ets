/**
 * PermissionManager.ets - 权限管理服务（F-07 隐私合规）
 * 
 * 功能：
 * 1. 按需申请权限（避免过度权限）
 * 2. 权限申请结果回调
 * 3. 权限拒绝后的降级方案
 * 4. 权限使用说明
 */

import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../Logger';

/**
 * 权限枚举（仅作类型定义，**必须与 module.json5 的 requestPermissions 严格一致**）。
 *
 * ⚠️ v2.7.0 重要约束（AGC 提审拦截项）：
 *   AGC 会校验「包内 user_grant 权限」是否与隐私政策声明一致。本应用当前**只申请
 *   INTERNET**（system_grant，无需运行时授权，也不需要在隐私政策中逐项列举）。
 *   因此下列 user_grant 权限（DISTRIBUTED_DATASYNC / READ_MEDIA / WRITE_MEDIA）
 *   **均未在 module.json5 中声明，且代码中无任何调用方**。
 *   若后续要真正启用，必须先：
 *     ① 在 module.json5 声明 + 补 reason 字符串；
 *     ② 在 AppGallery Connect 的隐私政策中逐项声明该权限及其用途；
 *     ③ 再在代码中调用 requestPermission，否则运行时会直接失败。
 */
export enum PermissionType {
  INTERNET = 'ohos.permission.INTERNET',
  GET_NETWORK_INFO = 'ohos.permission.GET_NETWORK_INFO',
  DISTRIBUTED_DATASYNC = 'ohos.permission.DISTRIBUTED_DATASYNC',
  READ_MEDIA = 'ohos.permission.READ_MEDIA',
  WRITE_MEDIA = 'ohos.permission.WRITE_MEDIA'
}

export interface PermissionResult {
  permission: PermissionType;
  granted: boolean;
  reason?: string;
}

export class PermissionManager {
  private static instance: PermissionManager;
  private readonly TAG = 'PermissionManager';
  
  // 权限申请回调
  private permissionCallbacks: Map<PermissionType, Array<(result: PermissionResult) => void>> = new Map();
  
  private constructor() {}
  
  static getInstance(): PermissionManager {
    if (!PermissionManager.instance) {
      PermissionManager.instance = new PermissionManager();
    }
    return PermissionManager.instance;
  }
  
  /**
   * 检查权限是否已授予
   */
  async checkPermission(permission: PermissionType): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const ctx = getContext(this) as common.UIAbilityContext;
      
      const grantStatus = await atManager.checkAccessToken(
        ctx.applicationInfo.accessTokenId,
        permission
      );
      
      return grantStatus === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
    } catch (error) {
      Logger.error(this.TAG, '检查权限失败: ' + JSON.stringify(error));
      return false;
    }
  }
  
  /**
   * 申请权限
   */
  async requestPermission(permission: PermissionType): Promise<PermissionResult> {
    try {
      // 先检查是否已授予
      const hasPermission = await this.checkPermission(permission);
      if (hasPermission) {
        return { permission, granted: true };
      }
      
      // 申请权限
      const atManager = abilityAccessCtrl.createAtManager();
      const ctx = getContext(this) as common.UIAbilityContext;
      
      const result = await atManager.requestPermissionsFromUser(ctx, [permission]);
      
      const granted = result.authResults[0] === 0;
      
      const permissionResult: PermissionResult = {
        permission,
        granted,
        reason: granted ? undefined : '用户拒绝授权'
      };
      
      // 通知回调
      this.notifyPermissionCallbacks(permissionResult);
      
      return permissionResult;
    } catch (error) {
      Logger.error(this.TAG, '申请权限失败: ' + JSON.stringify(error));
      return { permission, granted: false, reason: '申请权限失败' };
    }
  }
  
  /**
   * 批量申请权限
   */
  async requestPermissions(permissions: PermissionType[]): Promise<PermissionResult[]> {
    const results: PermissionResult[] = [];
    
    for (const permission of permissions) {
      const result = await this.requestPermission(permission);
      results.push(result);
    }
    
    return results;
  }
  
  /**
   * 申请网络权限（按需）
   */
  async requestNetworkPermission(): Promise<PermissionResult> {
    return await this.requestPermission(PermissionType.GET_NETWORK_INFO);
  }
  
  /**
   * 申请媒体权限（按需）
   */
  async requestMediaPermission(): Promise<PermissionResult[]> {
    return await this.requestPermissions([
      PermissionType.READ_MEDIA,
      PermissionType.WRITE_MEDIA
    ]);
  }
  
  /**
   * 申请分布式权限（按需）
   */
  async requestDistributedPermission(): Promise<PermissionResult> {
    return await this.requestPermission(PermissionType.DISTRIBUTED_DATASYNC);
  }
  
  /**
   * 添加权限申请回调
   */
  addPermissionCallback(permission: PermissionType, callback: (result: PermissionResult) => void): void {
    if (!this.permissionCallbacks.has(permission)) {
      this.permissionCallbacks.set(permission, []);
    }
    this.permissionCallbacks.get(permission)?.push(callback);
  }
  
  /**
   * 移除权限申请回调
   */
  removePermissionCallback(permission: PermissionType, callback: (result: PermissionResult) => void): void {
    const callbacks = this.permissionCallbacks.get(permission);
    if (callbacks) {
      const index = callbacks.indexOf(callback);
      if (index !== -1) {
        callbacks.splice(index, 1);
      }
    }
  }
  
  /**
   * 通知权限申请回调
   */
  private notifyPermissionCallbacks(result: PermissionResult): void {
    const callbacks = this.permissionCallbacks.get(result.permission);
    if (callbacks) {
      callbacks.forEach(callback => callback(result));
    }
  }
  
  /**
   * 获取权限说明
   */
  getPermissionReason(permission: PermissionType): string {
    const ctx = getContext(this) as common.UIAbilityContext;
    
    switch (permission) {
      case PermissionType.INTERNET:
        return ctx.resourceManager.getStringSync($r('app.string.permission_internet_reason').id);
      case PermissionType.GET_NETWORK_INFO:
        return ctx.resourceManager.getStringSync($r('app.string.permission_network_info_reason').id);
      case PermissionType.DISTRIBUTED_DATASYNC:
        return ctx.resourceManager.getStringSync($r('app.string.permission_distributed_datasync_reason').id);
      case PermissionType.READ_MEDIA:
        return ctx.resourceManager.getStringSync($r('app.string.permission_read_media_reason').id);
      case PermissionType.WRITE_MEDIA:
        return ctx.resourceManager.getStringSync($r('app.string.permission_write_media_reason').id);
      default:
        return '用于应用功能正常运行';
    }
  }
}

// 导出单例便捷方法
export const permissionManager = PermissionManager.getInstance();
