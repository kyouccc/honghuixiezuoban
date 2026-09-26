/**
 * 认证服务
 * 管理 JWT token 的获取、刷新、验证和存储
 *
 * ┌──────────────────────────────────────────────────────────────────────────┐
 * │ 当前未接线声明（C01 / backlog #4 拍板：保留 + 声明，不删除）              │
 * │                                                                          │
 * │ 本服务当前在 UI 层**无任何入口、无外部调用方**（全仓 grep 唯一命中均为   │
 * │ 文件自身）。它是一枚「未接线的备件」，不是露出给用户的空壳，故保留。     │
 * │                                                                          │
 * │ 保留理由：它是全仓**唯一**的 JWT 刷新实现 ——                          │
 * │   · scheduleTokenRefresh：提前 5 分钟刷新 accessToken；                   │
 * │   · refreshToken 失败自动 logout。                                       │
 * │ 若删除，将来接真后端时需从零重写这部分能力。                            │
 * │                                                                          │
 * │ 接线时机：本服务应作为 SessionIdentity 的 token 后端                     │
 * │ （见 common/identity/SessionIdentity.ets）。届时 JoinResult.token 落地后，│
 * │ 由本服务接管续期；当前阶段 token 仅由 SessionIdentity 暂存，未做刷新。   │
 * │                                                                          │
 * │ ⚠️ 接线者在 IDE 中即可看到本声明，切勿把「认证」与「CRDT 会话角色守卫」  │
 * │   （PermissionGuard）混淆：后者管的是 VIEWER/ANNOTATOR/EDITOR 图层权限，  │
 * │   与 ohos.permission.* 系统权限无关。                                     │
 * └──────────────────────────────────────────────────────────────────────────┘
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { API_BASE_URL } from '../Constants';
import { analytics, AnalyticsEvent } from './AnalyticsService';

const TAG = 'AuthService';
const DOMAIN = 0x0000;

export interface AuthToken {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
  userId: string;
}

export interface UserInfo {
  userId: string;
  deviceId: string;
  nickname?: string;
  avatar?: string;
}

export interface LoginProps extends Record<string, string> {
  method: string;
}

export class AuthService {
  private static instance: AuthService;
  private context: common.UIAbilityContext | null = null;
  private token: AuthToken | null = null;
  private userInfo: UserInfo | null = null;
  private refreshTimer: number = -1;

  private constructor() {}

  static getInstance(): AuthService {
    if (!AuthService.instance) {
      AuthService.instance = new AuthService();
    }
    return AuthService.instance;
  }

  /**
   * 初始化认证服务
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    
    // 从本地存储加载 token
    await this.loadTokenFromStorage();
    
    // 检查 token 是否有效
    if (this.token && this.isTokenValid()) {
      // 设置自动刷新
      this.scheduleTokenRefresh();
      hilog.info(DOMAIN, TAG, 'AuthService initialized with valid token');
    } else {
      hilog.info(DOMAIN, TAG, 'AuthService initialized without valid token');
    }
  }

  /**
   * 从本地存储加载 token
   */
  private async loadTokenFromStorage(): Promise<void> {
    if (!this.context) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'auth');
      const tokenStr = await prefs.get('token', '') as string;
      
      if (tokenStr) {
        this.token = JSON.parse(tokenStr);
        hilog.info(DOMAIN, TAG, 'Token loaded from storage');
      }
      
      const userInfoStr = await prefs.get('userInfo', '') as string;
      if (userInfoStr) {
        this.userInfo = JSON.parse(userInfoStr);
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to load token: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 保存 token 到本地存储
   */
  private async saveTokenToStorage(): Promise<void> {
    if (!this.context || !this.token) return;

    try {
      const prefs = await preferences.getPreferences(this.context, 'auth');
      await prefs.put('token', JSON.stringify(this.token));
      
      if (this.userInfo) {
        await prefs.put('userInfo', JSON.stringify(this.userInfo));
      }
      
      await prefs.flush();
      hilog.info(DOMAIN, TAG, 'Token saved to storage');
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to save token: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 检查 token 是否有效
   */
  private isTokenValid(): boolean {
    if (!this.token) return false;
    
    const now = Date.now();
    const bufferTime = 5 * 60 * 1000; // 5分钟缓冲
    
    return this.token.expiresAt > (now + bufferTime);
  }

  /**
   * 获取当前访问 token
   */
  getAccessToken(): string | null {
    if (!this.token || !this.isTokenValid()) {
      return null;
    }
    return this.token.accessToken;
  }

  /**
   * 获取用户信息
   */
  getUserInfo(): UserInfo | null {
    return this.userInfo;
  }

  /**
   * 检查是否已认证
   */
  isAuthenticated(): boolean {
    return this.token !== null && this.isTokenValid();
  }

  /**
   * 使用设备 ID 登录（匿名认证）
   */
  async loginWithDevice(deviceId: string): Promise<boolean> {
    try {
      hilog.info(DOMAIN, TAG, `Logging in with device: ${deviceId}`);
      
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(
        `${API_BASE_URL}/auth/device`,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json'
          },
          extraData: {
            device_id: deviceId
          }
        }
      );

      if (response.responseCode === 200 && response.result) {
        const result = JSON.parse(response.result as string) as Record<string, string | number>;
        
        this.token = {
          accessToken: String(result.access_token),
          refreshToken: String(result.refresh_token),
          expiresAt: Date.now() + (Number(result.expires_in) * 1000),
          userId: String(result.user_id)
        };
        
        this.userInfo = {
          userId: String(result.user_id),
          deviceId: deviceId
        };
        
        // 保存到本地
        await this.saveTokenToStorage();
        
        // 设置自动刷新
        this.scheduleTokenRefresh();
        
        // 更新 AppStorage
        AppStorage.setOrCreate<string>('authToken', this.token!.accessToken);
        AppStorage.setOrCreate<string>('userId', this.token!.userId);
        
        // 记录埋点
        const loginProps: LoginProps = { method: 'device' };
        analytics.track('auth_login_success', loginProps);
        
        hilog.info(DOMAIN, TAG, 'Login successful');
        return true;
      } else {
        hilog.error(DOMAIN, TAG, `Login failed: ${response.responseCode}`);
        analytics.trackError('auth', `Login failed: ${response.responseCode}`);
        return false;
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Login error: ${JSON.stringify(error)}`);
      analytics.trackError('auth', `Login error: ${JSON.stringify(error)}`);
      return false;
    }
  }

  /**
   * 刷新 token
   */
  async refreshToken(): Promise<boolean> {
    if (!this.token || !this.token.refreshToken) {
      hilog.warn(DOMAIN, TAG, 'No refresh token available');
      return false;
    }

    try {
      hilog.info(DOMAIN, TAG, 'Refreshing token');
      
      const httpRequest = http.createHttp();
      const response = await httpRequest.request(
        `${API_BASE_URL}/auth/refresh`,
        {
          method: http.RequestMethod.POST,
          header: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${this.token.refreshToken}`
          }
        }
      );

      if (response.responseCode === 200 && response.result) {
        const result = JSON.parse(response.result as string) as Record<string, string | number>;
        
        this.token!.accessToken = String(result.access_token);
        this.token!.expiresAt = Date.now() + (Number(result.expires_in) * 1000);
        
        if (result.refresh_token) {
          this.token!.refreshToken = String(result.refresh_token);
        }
        
        // 保存到本地
        await this.saveTokenToStorage();
        
        // 更新 AppStorage
        AppStorage.setOrCreate<string>('authToken', this.token!.accessToken);
        
        // 设置下次刷新
        this.scheduleTokenRefresh();
        
        hilog.info(DOMAIN, TAG, 'Token refreshed successfully');
        return true;
      } else {
        hilog.error(DOMAIN, TAG, `Token refresh failed: ${response.responseCode}`);
        // Token 刷新失败，需要重新登录
        await this.logout();
        return false;
      }
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Token refresh error: ${JSON.stringify(error)}`);
      return false;
    }
  }

  /**
   * 设置自动刷新
   */
  private scheduleTokenRefresh(): void {
    if (!this.token) return;
    
    // 清除之前的定时器
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
    }
    
    const now = Date.now();
    const timeUntilRefresh = this.token.expiresAt - now - (5 * 60 * 1000); // 提前5分钟刷新
    
    if (timeUntilRefresh > 0) {
      this.refreshTimer = setTimeout(() => {
        this.refreshToken();
      }, timeUntilRefresh);
      
      hilog.info(DOMAIN, TAG, `Token refresh scheduled in ${Math.floor(timeUntilRefresh / 1000 / 60)} minutes`);
    }
  }

  /**
   * 登出
   */
  async logout(): Promise<void> {
    hilog.info(DOMAIN, TAG, 'Logging out');
    
    // 清除定时器
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
    
    // 清除内存中的 token
    this.token = null;
    this.userInfo = null;
    
    // 清除本地存储
    if (this.context) {
      try {
        const prefs = await preferences.getPreferences(this.context, 'auth');
        await prefs.delete('token');
        await prefs.delete('userInfo');
        await prefs.flush();
      } catch (error) {
        hilog.error(DOMAIN, TAG, `Failed to clear token: ${JSON.stringify(error)}`);
      }
    }
    
    // 清除 AppStorage
    AppStorage.setOrCreate<string>('authToken', '');
    AppStorage.setOrCreate<string>('userId', '');
    
    // 记录埋点
    analytics.track('auth_logout');
  }

  /**
   * 销毁服务
   */
  destroy(): void {
    if (this.refreshTimer !== -1) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }
}

// 导出单例
export const authService = AuthService.getInstance();
