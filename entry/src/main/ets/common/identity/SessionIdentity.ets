/**
 * SessionIdentity.ets — 单一身份源（C01 · 身份链贯通）
 *
 * 本模块是「身份三分律」（约定 S）在**协作会话**链路的单一身份源（写入 + 读取入口）。
 * 注意：AuthService 在 JWT 刷新 / 登出时亦写入 AppStorage['userId']（详见 applyJoinResult 注释），
 * 故本模块并非全仓唯一写入点；但在「会话身份」这条链路上它是唯一写入点，也是推荐的读取入口。
 *
 * 写入点（会话链路）：
 *   - applyJoinResult(raw)  ← JoinRoomPage 在 REST 加入成功后调用，
 *     解析 JoinResult{user_id, token, ws_endpoint} 并落地到 AppStorage。
 *   - siteId()  ← 缺失时按 CollabStatusService.ensureLocalDeviceId 同款格式生成并回写。
 *
 * 严禁：
 *   - userId 回退到昵称（当前缺陷根源）。userId 只允许：服务端签发 > 回退 siteId。
 *   - displayName 写入任何协议字段（sender_id / assertion.user_id / undo 归属）。
 *   - 用 siteId 做 UI 展示。
 *
 * 与既有代码的关系：
 *   - SignalCodec.readUserId() / CollabStatusService / UndoRedoManager 历史上直接读
 *     AppStorage['userId']（即昵称）。本模块把「AppStorage['userId'] 写入什么」纠正为
 *     服务端签发的 user_id，下游读取方**无需改动**即自动获得正确身份（C01 范围内不触碰它们）。
 *   - AppStorage 键位沿用既有约定：siteId / userId / authToken / userName / wsEndpoint。
 *
 * ArkTS 严格模式：项目刚修完 2267 个错误，禁用 any/unknown 隐式。JSON.parse 返回 ESObject，
 * 通过 `as` 显式标注到 JoinResultRaw 接口，字段按可选 + 空值兜底处理。
 */

import { IdentitySnapshot } from './IdentitySnapshot';

/** JoinResult 反序列化结构（与服务端 RoomAPI.JoinResult 契约对齐） */
interface JoinResultRaw {
  user_id?: string;
  token?: string;
  ws_endpoint?: string;
}

/**
 * 单一身份源。AppStorage 为底层存储，本类提供类型安全、回退语义一致的访问。
 */
export class SessionIdentity {
  private static instance: SessionIdentity | null = null;

  private constructor() {}

  static getInstance(): SessionIdentity {
    if (SessionIdentity.instance === null || SessionIdentity.instance === undefined) {
      SessionIdentity.instance = new SessionIdentity();
    }
    return SessionIdentity.instance;
  }

  /**
   * 解析 JoinResult JSON 并落地 user_id / token / ws_endpoint。
   * 本模块是**协作会话**身份（userId / authToken / wsEndpoint）的写入点。
   * 注意：AuthService 在 JWT 刷新（token.userId）与登出（''）时亦写入 AppStorage['userId']，
   * 两者语义兼容（均为服务端签发身份），但**不共享代码路径**——故本模块并非全仓唯一写入点
   * （约定 S 仅约束「会话身份」这条链路，不覆盖 AuthService 的鉴权链路）。
   *
   * @param rawData RoomAPI.joinRoom 返回的 ApiResponse.data（JSON 字符串）
   * @returns true 表示解析成功（至少拿到非空 user_id）；false 表示数据无效（离线/脏数据）
   */
  applyJoinResult(rawData: string): boolean {
    if (rawData === null || rawData === undefined || rawData.length === 0) {
      return false;
    }
    let parsed: JoinResultRaw;
    try {
      parsed = JSON.parse(rawData) as JoinResultRaw;
    } catch (e) {
      return false;
    }

    const userId: string =
      (parsed.user_id !== undefined && parsed.user_id !== null && parsed.user_id.length > 0)
        ? parsed.user_id
        : this.siteId();
    const token: string = (parsed.token !== undefined && parsed.token !== null) ? parsed.token : '';
    const wsEndpoint: string =
      (parsed.ws_endpoint !== undefined && parsed.ws_endpoint !== null) ? parsed.ws_endpoint : '';

    AppStorage.setOrCreate<string>('userId', userId);
    AppStorage.setOrCreate<string>('authToken', token);
    AppStorage.setOrCreate<string>('wsEndpoint', wsEndpoint);
    return true;
  }

  /**
   * siteId：CRDT 决胜身份，设备级随机串。缺失则生成并回写。
   * 生成格式与 CollabStatusService.ensureLocalDeviceId 保持一致：dev_<base36(ts)>_<rand>。
   * 严禁用于 UI 展示。
   */
  siteId(): string {
    const existing: string | undefined = AppStorage.get<string>('siteId');
    if (existing !== undefined && existing !== null && existing.length > 0) {
      return existing;
    }
    const generated: string = `dev_${Date.now().toString(36)}_${Math.random().toString(36).substring(2, 6)}`;
    AppStorage.setOrCreate<string>('siteId', generated);
    return generated;
  }

  /**
   * userId：协议身份。服务端签发 > 回退 siteId。
   * **永不回退昵称**（当前缺陷根源）。
   */
  userId(): string {
    const existing: string | undefined = AppStorage.get<string>('userId');
    if (existing !== undefined && existing !== null && existing.length > 0) {
      return existing;
    }
    // 离线 / 未加入会话：回退 siteId，绝不回退昵称
    return this.siteId();
  }

  /**
   * displayName：仅 UI 展示。取用户输入的昵称（AppStorage['userName']），
   * 缺失时回退 siteId 尾 6 位（便于肉眼区分，但不是身份）。
   * 严禁写入 sender_id / assertion.user_id / undo 归属。
   */
  displayName(): string {
    const existing: string | undefined = AppStorage.get<string>('userName');
    if (existing !== undefined && existing !== null && existing.length > 0) {
      return existing;
    }
    const sid: string = this.siteId();
    return sid.length > 6 ? sid.substring(sid.length - 6) : sid;
  }

  /** token：服务端签发的 JWT。缺失回退 ''（未认证）。 */
  token(): string {
    const existing: string | undefined = AppStorage.get<string>('authToken');
    if (existing !== undefined && existing !== null) {
      return existing;
    }
    return '';
  }

  /** 服务端下发的 ws_endpoint。缺失回退 ''（由调用方按既有策略本地拼）。 */
  // 预留：C02 接入点（消费服务端下发的 ws_endpoint），暂无调用方。
  wsEndpoint(): string {
    const existing: string | undefined = AppStorage.get<string>('wsEndpoint');
    if (existing !== undefined && existing !== null) {
      return existing;
    }
    return '';
  }

  /**
   * 返回当前可用快照。无网络 / 离线时仍返回可用值：
   * userId 回退 siteId（不回退昵称），token 回退 ''。
   * 预留：会话快照对外接口，暂无调用方（IdentitySnapshot 作为本方法返回类型使用）。
   */
  ensure(): IdentitySnapshot {
    return {
      siteId: this.siteId(),
      userId: this.userId(),
      displayName: this.displayName(),
      token: this.token()
    };
  }

  /** 清空协议身份（保留 siteId，设备级稳定）。退出房间时调用。 */
  // 预留：退出房间清理接口，暂无调用方（后续接入房间退出清理时启用）。
  clear(): void {
    // 仅删协议身份字段。userName 是 displayName（仅 UI 展示，非协议身份，见身份三分律），
    // 不可删——否则用户每退一次房间就得重打昵称。
    AppStorage.delete('userId');
    AppStorage.delete('authToken');
    AppStorage.delete('wsEndpoint');
  }
}
