/**
 * IdentitySnapshot.ets — 身份快照数据结构（C01）
 *
 * 身份三分律（约定 S）的唯一数据载体：
 *   - siteId      CRDT 决胜身份（设备级随机串，稳定）。严禁用于 UI 展示。
 *   - userId      协议身份（服务端签发 > 回退 siteId）。严禁回退昵称。
 *   - displayName 仅 UI 展示（用户输入的昵称）。严禁写入任何协议字段。
 *   - token       服务端签发的 JWT。空串 = 未认证。
 *
 * 三者严禁串用：任何协议字段（sender_id / assertion.user_id / undo 归属）只能取 userId，
 * 永不取 displayName（见 architecture-honghui-dualchannel-v1.md §4.3 / §9 约定 S）。
 */

/** 身份快照：单一身份源 SessionIdentity 对外暴露的不可变视图 */
export interface IdentitySnapshot {
  /** CRDT 决胜身份。稳定、随机、设备级。来源 AppStorage['siteId']。 */
  siteId: string;
  /** 协议身份。服务端签发 > 回退 siteId。永不回退昵称。 */
  userId: string;
  /** 仅 UI 展示。用户输入的昵称。不进任何协议字段。 */
  displayName: string;
  /** 服务端签发的 JWT。空串 = 未认证。 */
  token: string;
}
