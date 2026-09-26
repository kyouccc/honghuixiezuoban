/**
 * DistributedBoardSession.ets — 分布式白板共享会话（v2.7.3 新增）
 *
 * ══════════════════════════════════════════════════════════════════════
 * 🔴 v2.7.3 审核修复（问题①「加入同一房间、登录同一华为账号的两块平板不能共享白板」真因）
 *
 * 真因：项目原有的板面同步链路是
 *     WhiteboardPage → DistributedBoardSync → CollaborationManager → transport → WSClient(WebSocket)
 *   即**必须有一个公网信令服务端**。本项目没有部署服务端 → 两台平板即便都"加入成功"，
 *   也**根本没有数据通路**，白板自然无法共享（审核实测即此现象）。
 *
 * 修法：改用鸿蒙**分布式数据对象**（`@ohos.data.distributedDataObject`）作为板面数据通路。
 *   它由系统分布式软总线承载，**同一华为账号下的可信设备之间自动同步，不需要任何服务端**，
 *   正是「登录同一账号的两块平板共享白板」这一场景的标准解法。
 *
 * ⚠️ API 说明（以本 SDK 声明文件实测签名为准，与旧示例不同）：
 *   · `create(context, source)` —— **必须传 Context**
 *   · 属性**直接读写**（该 API 无 setProperty）
 *   · `on('change', (sessionId, fields) => …)` —— 回调只给**变更字段名**，取值需再读属性
 *   · `on('status', (sessionId, networkId, status) => …)` —— 对端上下线
 *
 * 数据模型（G-Set 风格，两端最终一致且不丢笔画）：
 *   · strokes  —— 笔画信封数组的 JSON（键为 dev_sid，求并集去重 → 双向收敛）
 *   · clearRev —— 清空计数器（取 max 收敛）
 *   · from     —— 发送方设备标识（用于忽略自身回声）
 *   ⚠️ StrokeRecord.id 是 **number**、各设备本地自增，跨设备必然重号，
 *      故必须以「设备号 + 本地序号」作为全局唯一键，否则合并会丢笔画。
 *
 * ⚠️ 权限：ohos.permission.DISTRIBUTED_DATASYNC（user_grant）。
 *   已在本版本 module.json5 声明，并**必须**在 AGC 隐私政策中逐项声明（文案见交付文档）。
 * ══════════════════════════════════════════════════════════════════════
 */

import { distributedDataObject } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { SafeAsync } from '../common/utils/SafeAsync';
import { StrokeRecord } from '../engine/types/NoteModel';

const TAG = 'DistributedBoardSession';

/** 板面分布式对象：继承 DataObject 后即可类型安全地直接读写属性 */
interface BoardDO extends distributedDataObject.DataObject {
  strokes: string;
  clearRev: number;
  from: string;
  room: string;
}

/** 笔画信封：来源设备号 + 本地序号 = 跨设备唯一键 */
interface StrokeEnvelope {
  dev: string;
  sid: number;
  stroke: StrokeRecord;
}

interface StrokePayload {
  strokes: StrokeEnvelope[];
}

/** 远端事件回调（由页面层注册） */
export interface BoardSessionListener {
  onRemoteStrokes: (incoming: StrokeRecord[]) => void;
  onRemoteClear: () => void;
  onPeersChanged: (count: number) => void;
}

export class DistributedBoardSession {
  private static instance: DistributedBoardSession | null = null;

  private obj: BoardDO | null = null;
  private sessionId: string = '';
  private localDeviceId: string = '';
  private active: boolean = false;
  /** 已持有的笔画全局键（dev_sid），用于并集去重 */
  private knownKeys: Set<string> = new Set<string>();
  private clearRev: number = 0;
  private listener: BoardSessionListener | null = null;
  /** 已发布过的 JSON，避免无变更重复写入 */
  private lastPublished: string = '';
  private peers: number = 0;

  static getInstance(): DistributedBoardSession {
    if (DistributedBoardSession.instance === null) {
      DistributedBoardSession.instance = new DistributedBoardSession();
    }
    return DistributedBoardSession.instance;
  }

  setListener(listener: BoardSessionListener | null): void {
    this.listener = listener;
  }

  setLocalDeviceId(id: string): void {
    this.localDeviceId = id;
  }

  isActive(): boolean {
    return this.active;
  }

  getSessionId(): string {
    return this.sessionId;
  }

  getPeerCount(): number {
    return this.peers;
  }

  /**
   * 加入/创建分布式板面会话。
   * 同一华为账号下的其它设备只要以相同 roomCode 调用本方法，即自动互通。
   */
  async join(context: common.Context, roomCode: string, localStrokes: StrokeRecord[]): Promise<boolean> {
    if (context === null || context === undefined || roomCode.length === 0) {
      Logger.warn(TAG, 'join 参数无效，跳过分布式共享');
      return false;
    }
    this.leave();

    this.sessionId = roomCode;
    this.knownKeys.clear();
    const localEnvelopes: StrokeEnvelope[] = this.toEnvelopes(localStrokes);
    for (let i = 0; i < localEnvelopes.length; i++) {
      this.knownKeys.add(`${localEnvelopes[i].dev}_${localEnvelopes[i].sid}`);
    }
    const initialJson: string = JSON.stringify(localEnvelopes);

    try {
      const created: distributedDataObject.DataObject = distributedDataObject.create(context, {
        strokes: initialJson,
        clearRev: this.clearRev,
        from: this.localDeviceId,
        room: roomCode,
      });
      this.obj = created as BoardDO;

      this.obj.on('change', (sessionId: string, fields: Array<string>): void => {
        SafeAsync.runVoid(TAG, 'onRemoteChange', (): void => {
          this.handleRemoteChange(fields);
        });
      });
      this.obj.on('status', (sessionId: string, networkId: string, status: 'online' | 'offline'): void => {
        SafeAsync.runVoid(TAG, 'onPeerStatus', (): void => {
          this.handlePeerStatus(networkId, status);
        });
      });

      // 加入同步会话：同账号设备使用相同 sessionId 即互通
      this.obj.setSessionId(roomCode).catch((err: Error): void => {
        Logger.error(TAG, `setSessionId 失败: ${SafeAsync.describe(err)}`);
      });

      this.active = true;
      this.lastPublished = initialJson;
      Logger.info(TAG, `分布式板面会话已建立: room=${roomCode} 本机笔画 ${localStrokes.length} 笔`);
      return true;
    } catch (e) {
      this.active = false;
      this.obj = null;
      Logger.error(TAG, `建立分布式板面会话失败: ${SafeAsync.describe(e as Error)}`);
      return false;
    }
  }

  /** 退出会话（释放数据对象） */
  leave(): void {
    if (this.obj !== null) {
      try {
        this.obj.off('change');
        this.obj.off('status');
      } catch (e) {
        Logger.warn(TAG, `解绑监听失败: ${SafeAsync.describe(e as Error)}`);
      }
      try {
        this.obj.setSessionId('').catch((): void => { /* 忽略 */ });
      } catch (e) {
        Logger.warn(TAG, '清空 sessionId 失败');
      }
      this.obj = null;
    }
    this.active = false;
    this.sessionId = '';
    this.peers = 0;
    this.knownKeys.clear();
    Logger.info(TAG, '已退出分布式板面会话');
  }

  /** 发布本地笔画全量集合（并集去重后写入，触发跨设备同步） */
  publishStrokes(localStrokes: StrokeRecord[]): void {
    if (!this.active || this.obj === null) {
      return;
    }
    try {
      const envelopes: StrokeEnvelope[] = this.toEnvelopes(localStrokes);
      for (let i = 0; i < envelopes.length; i++) {
        this.knownKeys.add(`${envelopes[i].dev}_${envelopes[i].sid}`);
      }
      const json: string = JSON.stringify(envelopes);
      if (json === this.lastPublished) {
        return;
      }
      this.lastPublished = json;
      this.obj.from = this.localDeviceId;
      this.obj.strokes = json;      // 直接属性赋值即触发分布式同步
      Logger.info(TAG, `已同步本机笔画 ${localStrokes.length} 笔 → 房间 ${this.sessionId}`);
    } catch (e) {
      Logger.error(TAG, `同步笔画失败: ${SafeAsync.describe(e as Error)}`);
    }
  }

  /** 发布清空动作 */
  publishClear(): void {
    if (!this.active || this.obj === null) {
      return;
    }
    try {
      this.clearRev += 1;
      this.knownKeys.clear();
      this.lastPublished = '[]';
      this.obj.from = this.localDeviceId;
      this.obj.clearRev = this.clearRev;
      this.obj.strokes = '[]';
      Logger.info(TAG, `已同步清空动作（clearRev=${this.clearRev}）`);
    } catch (e) {
      Logger.error(TAG, `同步清空失败: ${SafeAsync.describe(e as Error)}`);
    }
  }

  // ───────────────────────── 内部实现 ─────────────────────────

  private handlePeerStatus(networkId: string, status: 'online' | 'offline'): void {
    this.peers = status === 'online' ? this.peers + 1 : Math.max(0, this.peers - 1);
    Logger.info(TAG, `对端 ${status}（networkId=${networkId}），当前在线 ${this.peers}`);
    if (this.listener !== null) {
      this.listener.onPeersChanged(this.peers);
    }
  }

  private handleRemoteChange(fields: Array<string>): void {
    if (this.obj === null) {
      return;
    }
    const fromSelf: boolean = `${this.obj.from}` === this.localDeviceId;
    const hasClear: boolean = fields.indexOf('clearRev') >= 0;
    const hasStrokes: boolean = fields.indexOf('strokes') >= 0;

    // ① 清空（取 max 收敛）
    if (hasClear) {
      const rev: number = Number(this.obj.clearRev);
      if (rev > this.clearRev) {
        this.clearRev = rev;
        this.knownKeys.clear();
        this.lastPublished = '[]';
        if (this.listener !== null) {
          this.listener.onRemoteClear();
        }
      }
    }

    // ② 笔画并集（跳过自身回声）
    if (!hasStrokes || fromSelf) {
      return;
    }
    const raw: string = `${this.obj.strokes}`;
    if (raw.length <= 2) {
      return;
    }
    let payload: StrokePayload | null = null;
    try {
      payload = JSON.parse(raw) as StrokePayload;
    } catch (e) {
      Logger.warn(TAG, '远端笔画 JSON 解析失败，已忽略');
      return;
    }
    if (payload === null || payload.strokes === undefined || payload.strokes === null) {
      return;
    }
    const incoming: StrokeRecord[] = [];
    for (let i = 0; i < payload.strokes.length; i++) {
      const env: StrokeEnvelope = payload.strokes[i];
      if (env === null || env === undefined || env.stroke === undefined || env.stroke === null) {
        continue;
      }
      const key: string = `${env.dev}_${env.sid}`;
      if (!this.knownKeys.has(key)) {
        this.knownKeys.add(key);
        incoming.push(env.stroke);
      }
    }
    if (incoming.length === 0) {
      return;
    }
    Logger.info(TAG, `收到远端新增笔画 ${incoming.length} 笔`);
    if (this.listener !== null) {
      this.listener.onRemoteStrokes(incoming);
    }
  }

  /** 本地笔画 → 信封（dev = 本机设备号，sid = 笔画本地数字 id） */
  private toEnvelopes(strokes: StrokeRecord[]): StrokeEnvelope[] {
    const dev: string = this.localDeviceId.length > 0 ? this.localDeviceId : 'local';
    const out: StrokeEnvelope[] = [];
    for (let i = 0; i < strokes.length; i++) {
      out.push({ dev: dev, sid: strokes[i].id, stroke: strokes[i] });
    }
    return out;
  }
}
