// Constants.ets — 全局常量定义 v1.1（移除重复类，统一为命名空间对象）
// 使用方式：import { Constants } from '../common/Constants'; Constants.WS_HEARTBEAT_INTERVAL
// 或逐项 import：import { WS_HEARTBEAT_INTERVAL } from '../common/Constants';

// ─── WebSocket ───
export const WS_HEARTBEAT_INTERVAL: number = 5000;
export const WS_HEARTBEAT_TIMEOUT: number = 15000;
export const WS_RECONNECT_MAX_RETRIES: number = 5;
export const WS_RECONNECT_BACKOFF_BASE: number = 1000;

// ─── 笔触 ───
export const STROKE_MAX_POINTS: number = 10000;
export const STROKE_MIN_WIDTH: number = 1;
export const STROKE_MAX_WIDTH: number = 20;

// ─── Canvas渲染 ───
export const CANVAS_TARGET_FPS: number = 60;
export const CANVAS_MIN_FPS: number = 55;
export const CANVAS_STROKE_LATENCY_MS: number = 9;
export const CANVAS_FIRST_FRAME_MS: number = 1500;

// ─── CRDT ───
export const CRDT_SYNC_P95_MS: number = 150;
export const CRDT_STATE_SYNC_THRESHOLD: number = 500;

// ─── 房间 ───
export const ROOM_MAX_PARTICIPANTS: number = 50;
export const ROOM_SNAPSHOT_INTERVAL_SEC: number = 300;
export const ROOM_DEFAULT_EXPIRE_HOURS: number = 6;

// ─── 文档导入（v2.0 增量，NP-05）───
export const PDF_FREE_PAGE_LIMIT: number = 10;   // 免费版 PDF 页数上限（架构 §8.5）

// ─── 分布式协同（v2.0 增量，S2T01/S2T02，架构 §8.5）───
export const VIEWPORT_GRID_SIZE: number = 256;              // 视口差分空间网格（世界坐标单元）
export const VIEWPORT_SYNC_MAX_HZ: number = 5;              // 视口跟随消息节流上限（低频控制消息）
export const SESSION_DEFAULT_EXPIRES_MS: number = 6 * 3600 * 1000;   // 会话默认有效期
export const PERMISSION_ASSERT_TTL_MS: number = 4 * 3600 * 1000;     // 权限断言有效期

// ─── AI ───
export const AI_MODEL_MAX_SIZE: number = 50 * 1024 * 1024;
export const AI_INFERENCE_TIMEOUT_MS: number = 10000;
export const AI_CONFIDENCE_THRESHOLD: number = 0.80;

// ─── 包体 ───
export const APP_PACKAGE_MAX_SIZE: number = 10 * 1024 * 1024;

// ─── API ───
export const API_BASE_URL: string = 'https://api.honghui.dev/v1';

// ─── 错误码 ───
export enum ErrorCode {
  SUCCESS = 0,
  E_SYS_0001 = 10001,
  E_NET_0001 = 20001,
  E_NET_0002 = 20002,
  E_CRDT_0001 = 30001,
  E_CRDT_0002 = 30002,
  E_AI_0001 = 40001,
  E_AI_0002 = 40002,
  E_ROOM_0001 = 50001,
  E_ROOM_0002 = 50002,
  E_AUTH_0001 = 60001,
  E_AUTH_0002 = 60002,
}

// ─── 边界校验工具 ───
export function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

export function isValidColor(hex: string): boolean {
  return /^#[0-9A-Fa-f]{6}$/.test(hex) || /^#[0-9A-Fa-f]{8}$/.test(hex);
}

// ─── 兼容 import { Constants } 语法（命名空间对象，非重复定义） ───
interface ConstantsType {
  WS_HEARTBEAT_INTERVAL: number;
  WS_HEARTBEAT_TIMEOUT: number;
  WS_RECONNECT_MAX_RETRIES: number;
  WS_RECONNECT_BACKOFF_BASE: number;
  STROKE_MAX_POINTS: number;
  STROKE_MIN_WIDTH: number;
  STROKE_MAX_WIDTH: number;
  CANVAS_TARGET_FPS: number;
  CANVAS_MIN_FPS: number;
  CANVAS_STROKE_LATENCY_MS: number;
  CANVAS_FIRST_FRAME_MS: number;
  CRDT_SYNC_P95_MS: number;
  CRDT_STATE_SYNC_THRESHOLD: number;
  ROOM_MAX_PARTICIPANTS: number;
  ROOM_SNAPSHOT_INTERVAL_SEC: number;
  ROOM_DEFAULT_EXPIRE_HOURS: number;
  PDF_FREE_PAGE_LIMIT: number;
  VIEWPORT_GRID_SIZE: number;
  VIEWPORT_SYNC_MAX_HZ: number;
  SESSION_DEFAULT_EXPIRES_MS: number;
  PERMISSION_ASSERT_TTL_MS: number;
  AI_MODEL_MAX_SIZE: number;
  AI_INFERENCE_TIMEOUT_MS: number;
  AI_CONFIDENCE_THRESHOLD: number;
  APP_PACKAGE_MAX_SIZE: number;
  API_BASE_URL: string;
}

export const Constants: ConstantsType = {
  WS_HEARTBEAT_INTERVAL,
  WS_HEARTBEAT_TIMEOUT,
  WS_RECONNECT_MAX_RETRIES,
  WS_RECONNECT_BACKOFF_BASE,
  STROKE_MAX_POINTS,
  STROKE_MIN_WIDTH,
  STROKE_MAX_WIDTH,
  CANVAS_TARGET_FPS,
  CANVAS_MIN_FPS,
  CANVAS_STROKE_LATENCY_MS,
  CANVAS_FIRST_FRAME_MS,
  CRDT_SYNC_P95_MS,
  CRDT_STATE_SYNC_THRESHOLD,
  ROOM_MAX_PARTICIPANTS,
  ROOM_SNAPSHOT_INTERVAL_SEC,
  ROOM_DEFAULT_EXPIRE_HOURS,
  PDF_FREE_PAGE_LIMIT,
  VIEWPORT_GRID_SIZE,
  VIEWPORT_SYNC_MAX_HZ,
  SESSION_DEFAULT_EXPIRES_MS,
  PERMISSION_ASSERT_TTL_MS,
  AI_MODEL_MAX_SIZE,
  AI_INFERENCE_TIMEOUT_MS,
  AI_CONFIDENCE_THRESHOLD,
  APP_PACKAGE_MAX_SIZE,
  API_BASE_URL,
};

// ═══════════════════════════════════════════════════════════════════
// 功能总开关（v2.7.5）
// ═══════════════════════════════════════════════════════════════════
/**
 * 协作功能总开关。
 *
 * v2.7.5 起**暂时下线**：跨设备白板共享依赖分布式数据同步能力，
 * 而该能力需要 user_grant 权限「DISTRIBUTED_DATASYNC」并同步在 AGC 隐私政策中声明，
 * 会增加提审环节的不确定性。为保证本版本顺利上架，先关闭协作入口，
 * 相关实现（JoinRoomPage / DistributedBoardSession / RoomDirectory）全部保留，
 * **下一版本把本开关改为 true、并在 module.json5 恢复权限声明即可重新启用**。
 */
export const FEATURE_COLLAB_ENABLED: boolean = false;

/**
 * 设备发现 / 跨设备协同 总开关。
 *
 * v2.7.6 起**暂时下线**：「附近设备」读取依赖 `distributedDeviceManager`，
 * 该能力需要 user_grant 权限「DISTRIBUTED_DATASYNC」——而本版本为降低提审风险
 * 已移除该权限（见 module.json5 注释），因此**设备列表必然为空**，
 * 审核会判为"读取不到设备"的功能异常。
 *
 * 处置：关闭「设备管理」入口，避免暴露一个必然失败的功能。
 * 下一版本恢复步骤：①本开关置 true；②module.json5 恢复 DISTRIBUTED_DATASYNC；
 * ③AGC 隐私政策同步声明该权限。
 */
// 🔴 v2.7.8：为**确保本次上架**，暂时关闭该入口（通过上架后立即开启）。
//   原因：本功能依赖 user_grant 权限 DISTRIBUTED_DATASYNC，
//   开启入口必须同时 ①声明权限 ②AGC 隐私政策同步声明 —— 多一个提审风险点；
//   而该功能又依赖两台真机同账号 + 超级终端，**无法在提交前自证可用**。
//   关闭入口后审核界面上不再出现该功能，对应驳回项随之消失。
//   ✅ 恢复方式（代码已全部就绪，仅需）：本开关置 true + module.json5 恢复权限声明
//      + AGC 隐私政策同步声明该权限。运行时权限申请逻辑已写在 DeviceManagePage。
export const FEATURE_DEVICE_DISCOVERY_ENABLED: boolean = false;
