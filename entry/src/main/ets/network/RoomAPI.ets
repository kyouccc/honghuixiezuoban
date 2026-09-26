import { http } from '@kit.NetworkKit';
import { Logger } from '../common/Logger';
import { SafeAsync } from '../common/utils/SafeAsync';
import { API_BASE_URL } from '../common/Constants';

const TAG_MODULE = 'RoomAPI';

export interface RoomInfo {
  room_id: string;
  name: string;
  join_code: string;
  ws_endpoint: string;
  created_at: string;
  expires_at: string;
}

export interface JoinResult {
  user_id: string;
  token: string;
  ws_endpoint: string;
}

export interface ApiResponse {
  code: number;
  data: string;
}

export class RoomAPI {
  private static instance: RoomAPI | null = null;

  static getInstance(): RoomAPI {
    if (!RoomAPI.instance) {
      RoomAPI.instance = new RoomAPI();
    }
    return RoomAPI.instance;
  }

  async createRoom(name: string): Promise<ApiResponse> {
    return this.request('POST', '/rooms', JSON.stringify({ name: name }));
  }

  async joinRoom(joinCode: string, userName: string): Promise<ApiResponse> {
    const body: string = JSON.stringify({ join_code: joinCode, user_name: userName });
    return this.request('POST', `/rooms/${joinCode}/join`, body);
  }

  async leaveRoom(roomId: string): Promise<ApiResponse> {
    return this.request('POST', `/rooms/${roomId}/leave`, '');
  }

  async deleteRoom(roomId: string): Promise<ApiResponse> {
    return this.request('DELETE', `/rooms/${roomId}`, '');
  }

  async getRoomState(roomId: string): Promise<ApiResponse> {
    return this.request('GET', `/rooms/${roomId}/state`, '');
  }

  private async request(method: string, path: string, body: string): Promise<ApiResponse> {
    const url: string = `${API_BASE_URL}${path}`;
    const token: string = AppStorage.get<string>('authToken') || '';
    let httpRequest: http.HttpRequest | null = null;
    try {
      httpRequest = http.createHttp();
      const response: http.HttpResponse = await httpRequest.request(url, {
        method: method as http.RequestMethod,
        header: {
          'Content-Type': 'application/json',
          'Authorization': token && token.length > 0 ? `Bearer ${token}` : ''
        },
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 15000
      });
      httpRequest.destroy();
      httpRequest = null;

      if (response.responseCode === 200 || response.responseCode === 201) {
        const result: ApiResponse = { code: 0, data: response.result as string };
        Logger.info(TAG_MODULE, `${method} ${path} OK`);
        return result;
      }
      Logger.warn(TAG_MODULE, `${method} ${path} HTTP ${response.responseCode}`);
      return { code: response.responseCode, data: '' };
    } catch (err) {
      if (httpRequest) {
        try { httpRequest.destroy(); } catch (_) { /* ignore */ }
      }
      // 🔧 v2.7.0 审核修复（问题①-3）：原实现用
      //   `err instanceof Error ? err.message : String(err)`，
      //   而鸿蒙 BusinessError 是普通对象 → String(obj) = "[object Object]"，
      //   该字面量被当作错误文案直接显示在页面上（审核截图即此）。
      //   统一改用 SafeAsync.describe：message → code → JSON → 中文兜底。
      const errMsg: string = SafeAsync.describe(err as Error);
      Logger.error(TAG_MODULE, `API call failed [${method} ${path}]: ${errMsg}`);
      return { code: 20001, data: errMsg };
    }
  }
}
