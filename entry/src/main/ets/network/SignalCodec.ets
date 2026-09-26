import { Logger } from '../common/Logger';
import { util } from '@kit.ArkTS';
import { CRDTOp } from '../crdt/types/CRDTOp';
import { CanvasElement } from '../engine/types/CanvasElement';
import { SessionIdentity } from '../common/identity/SessionIdentity';

const TAG_MODULE = 'SignalCodec';

// ─── Protobuf Tag-Length-Value 编码/解码 ───

export enum MsgType {
  MSG_CRDT_OP = 1,
  MSG_CURSOR_SYNC = 2,
  MSG_ROOM_EVENT = 3,
  MSG_STATE_SYNC = 4,
  MSG_HEARTBEAT = 5,
  MSG_LAYER_OP = 6,
  // ─── v2.0 增量（对齐 proto MsgType，字段编号永久保留）───
  MSG_VIEWPORT_SYNC = 8,        // 视口/页码跟随（低频控制消息，不进 CRDT，HM-09）
  MSG_PERMISSION_ASSERT = 9,    // 权限断言（加入会话时下发，HM-11）
  MSG_VIEWPORT_SUB = 10,        // 视口订阅（上报视口矩形，HM-14，P1）
  MSG_VIEWPORT_DIFF = 11,       // 视口差分广播（服务端→订阅者，HM-14，P1）
  // ─── S2-Cc / T2-5c：资产分片旁路通道（t25 §2，只加不改既有）───
  MSG_ASSET_CHUNK = 12,         // 资产分片（64KB/片 + 每片 CRC32）
  MSG_ASSET_REQ = 13,           // 缺失资产请求
  MSG_ASSET_ACK = 14,           // 收齐确认（bitmap 断点续传）
}

/** 连接级 JSON 信令类型（v1 兼容；新代码优先使用 MsgType 信封） */
export enum SignalType {
  JOIN = 'join',
  LEAVE = 'leave',
  OPERATION = 'operation',
  SYNC = 'sync',
  USER_JOIN = 'user_join',
  USER_LEAVE = 'user_leave',
}

export interface SignalEnvelope {
  msg_id: string;
  msg_type: MsgType;
  payload: Uint8Array;
  timestamp: number;
  sender_id: string;
}

/** v2.0：视口同步负载（与 proto ViewportSyncMessage 对齐） */
export interface ViewportSyncPayload {
  centerX: number;
  centerY: number;
  scale: number;
  currentPage: number;
  timestamp: number;
  senderDeviceId: string;
}

/**
 * v2.0：权限断言负载（与 proto PermissionAssertion / Go REST 字段命名一致，
 * 架构 §8.2 约定 1 三端统一 snake_case：session_id/user_id/device_id/issued_at/expires_at。
 * 修复 E-6：REST join 响应断言可直传 joinSession，不再出现 deviceId=undefined。）
 */
export interface PermissionAssertionPayload {
  session_id: string;
  user_id: string;
  device_id: string;
  role: string;             // VIEWER | ANNOTATOR | EDITOR
  issuer: string;
  issued_at: number;
  expires_at: number;
  signature: string;
}

/** v2.0：CRDT 操作负载（JSON 序列化 + elementType 显式标注） */
export interface CRDTOpPayload {
  opJson: string;
  elementType: string;
}

// ─── S2-Cc / T2-5c：资产分片负载（t25 §2）───

/** 资产分片（64KB/片；data 为 base64 文本以便 JSON 信封承载，CRC32 每片校验） */
export interface AssetChunkPayload {
  assetId: string;          // imageHash（FNV-1a，内容寻址）
  seq: number;              // 片序号（0 基）
  totalChunks: number;
  data: string;             // 本片字节（base64）
  chunkCrc: number;         // 本片 CRC32
}

/** 缺失资产请求 */
export interface AssetReqPayload {
  assetId: string;
}

/** 收齐确认（bitmap 断点续传；bit 位=片序号，'1'=已收） */
export interface AssetAckPayload {
  assetId: string;
  receivedBitmap: string;
}

/** varint 解析结果（替代内联对象类型，符合 arkts-no-obj-literals-as-types） */
export interface VarintResult {
  value: number;
  endPos: number;
}

export class SignalCodec {
  /**
   * Protobuf TLV 编码信封消息
   *
   * SignalEnvelope wire format:
   *   field 1 (string msg_id)    = tag 0x0A, length-delimited
   *   field 2 (int32 msg_type)   = tag 0x10, varint
   *   field 3 (bytes payload)    = tag 0x1A, length-delimited
   *   field 4 (int64 timestamp)  = tag 0x20, varint
   *   field 5 (string sender_id) = tag 0x2A, length-delimited
   */
  static encode(envelope: SignalEnvelope): Uint8Array {
    const parts: Uint8Array[] = [];

    // msg_id (field 1, wire type 2)
    const msgIdBytes = SignalCodec.stringToBytes(envelope.msg_id);
    parts.push(SignalCodec.encodeTagLengthValue(0x0A, msgIdBytes));

    // msg_type (field 2, wire type 0)
    parts.push(SignalCodec.encodeVarintField(0x10, envelope.msg_type));

    // payload (field 3, wire type 2)
    parts.push(SignalCodec.encodeTagLengthValue(0x1A, envelope.payload));

    // timestamp (field 4, wire type 0)
    parts.push(SignalCodec.encodeVarintField(0x20, envelope.timestamp));

    // sender_id (field 5, wire type 2)
    const senderIdBytes = SignalCodec.stringToBytes(envelope.sender_id);
    parts.push(SignalCodec.encodeTagLengthValue(0x2A, senderIdBytes));

    return SignalCodec.concatBytes(parts);
  }

  /**
   * Protobuf TLV 解码信封消息
   *
   * C03 加固（Q13 / 验收①）：
   *  - wireType 1/5（fixed64/fixed32）此前未处理导致 pos 不前进 → 畸形消息死循环。
   *    现按 wire 语义跳过对应长度（未知字段无需消费，优雅丢弃）。
   *  - 循环尾 `if (pos <= lastPos) break` 硬保护：任何分支都必须前进 pos，否则终止，
   *    从结构上杜绝死循环（不抛未捕获异常，调用方拿到的只是部分默认信封）。
   */
  static decode(data: Uint8Array): SignalEnvelope {
    const envelope: Partial<SignalEnvelope> = {
      msg_id: '',
      msg_type: MsgType.MSG_HEARTBEAT,
      payload: new Uint8Array(0),
      timestamp: Date.now(),
      sender_id: ''
    };

    let pos = 0;
    while (pos < data.length) {
      const lastPos: number = pos;
      const first: VarintResult = SignalCodec.readVarint(data, pos);
      if (first.endPos <= lastPos) {
        // varint 未消费任何字节（畸形 tag）：终止，避免死循环
        break;
      }
      pos = first.endPos;
      const tag: number = first.value;
      const wireType: number = tag & 0x07;
      const fieldNumber: number = tag >> 3;

      if (wireType === 0) {
        // arkts-no-destruct-decls：禁止解构声明，逐字段赋值
        const varint0: VarintResult = SignalCodec.readVarint(data, pos);
        if (varint0.endPos <= pos) {
          break;
        }
        pos = varint0.endPos;
        const value: number = varint0.value;
        if (fieldNumber === 2) envelope.msg_type = value;
        if (fieldNumber === 4) envelope.timestamp = value;
      } else if (wireType === 2) {
        const varint1: VarintResult = SignalCodec.readVarint(data, pos);
        if (varint1.endPos <= pos) {
          break;
        }
        pos = varint1.endPos;
        const length: number = varint1.value;
        if (length < 0 || pos + length > data.length) {
          // 长度越界（畸形）：丢弃剩余，避免越界读取
          break;
        }
        const bytes = data.slice(pos, pos + length);
        pos += length;

        if (fieldNumber === 1) envelope.msg_id = SignalCodec.bytesToString(bytes);
        if (fieldNumber === 3) envelope.payload = bytes;
        if (fieldNumber === 5) envelope.sender_id = SignalCodec.bytesToString(bytes);
      } else if (wireType === 1) {
        // fixed64（8 字节定长）：未知字段无需消费 → 跳过
        if (pos + 8 > data.length) {
          break;
        }
        pos += 8;
      } else if (wireType === 5) {
        // fixed32（4 字节定长）：未知字段无需消费 → 跳过
        if (pos + 4 > data.length) {
          break;
        }
        pos += 4;
      } else {
        // wireType 3/4/6/7：分组/废弃类型无法确定长度 → 优雅终止，丢弃剩余
        break;
      }

      if (pos <= lastPos) {
        // 硬保护：本轮未前进 → 终止，杜绝任何死循环可能
        break;
      }
    }

    return envelope as SignalEnvelope;
  }

  // ─── Deflate 压缩 (使用pako库) ───

  /**
   * @deprecated C03 声明：零调用方，pako 未加载，实际透传原数据（无压缩效果）。
   * 新代码禁止调用；如需压缩请走独立压缩通道（本期不做）。
   */
  static compress(data: Uint8Array): Uint8Array {
    try {
      // pako.deflate would be used here in production
      // For MVP, return raw data (compression is optional)
      Logger.debug(TAG_MODULE, `Compress: ${data.length} bytes → raw (pako not loaded)`);
      return data;
    } catch (err) {
      Logger.warn(TAG_MODULE, 'Compression failed, using raw data');
      return data;
    }
  }

  /**
   * @deprecated C03 声明：零调用方，pako 未加载，实际透传原数据（无解压效果）。
   * 新代码禁止调用；如需压缩请走独立压缩通道（本期不做）。
   */
  static decompress(data: Uint8Array): Uint8Array {
    try {
      // pako.inflate would be used here in production
      return data;
    } catch (err) {
      return data;
    }
  }

  // ─── 消息类型编码 ───

  /** CRDT 操作编码（v2.0：显式类型 CRDTOp，避免 any） */
  static encodeCRDTOp(op: CRDTOp): Uint8Array {
    const opStr: string = JSON.stringify(op);
    const payload: Uint8Array = SignalCodec.stringToBytes(opStr);

    return SignalCodec.encode({
      msg_id: `crdt_${Date.now()}`,
      msg_type: MsgType.MSG_CRDT_OP,
      payload: payload,
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  /** CRDT 操作解码（payload = JSON 序列化的 CRDTOp） */
  static decodeCRDTOp(payload: Uint8Array): CRDTOp {
    const json: string = SignalCodec.bytesToString(payload);
    const op: CRDTOp = JSON.parse(json) as CRDTOp;
    return op;
  }

  // ─── S2-Cc / T2-5c：资产分片编解码（只加不改，t25 §2）───

  /** 资产分片编码（payload = JSON 序列化的 AssetChunkPayload） */
  static encodeAssetChunk(chunk: AssetChunkPayload): Uint8Array {
    const payload: Uint8Array = SignalCodec.stringToBytes(JSON.stringify(chunk));
    return SignalCodec.encode({
      msg_id: `asset_${Date.now()}_${chunk.seq}`,
      msg_type: MsgType.MSG_ASSET_CHUNK,
      payload: payload,
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  static decodeAssetChunk(payload: Uint8Array): AssetChunkPayload {
    return JSON.parse(SignalCodec.bytesToString(payload)) as AssetChunkPayload;
  }

  /** 资产请求编码 */
  static encodeAssetReq(req: AssetReqPayload): Uint8Array {
    const payload: Uint8Array = SignalCodec.stringToBytes(JSON.stringify(req));
    return SignalCodec.encode({
      msg_id: `assetreq_${Date.now()}`,
      msg_type: MsgType.MSG_ASSET_REQ,
      payload: payload,
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  static decodeAssetReq(payload: Uint8Array): AssetReqPayload {
    return JSON.parse(SignalCodec.bytesToString(payload)) as AssetReqPayload;
  }

  /** 资产收齐确认编码 */
  static encodeAssetAck(ack: AssetAckPayload): Uint8Array {
    const payload: Uint8Array = SignalCodec.stringToBytes(JSON.stringify(ack));
    return SignalCodec.encode({
      msg_id: `assetack_${Date.now()}`,
      msg_type: MsgType.MSG_ASSET_ACK,
      payload: payload,
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  static decodeAssetAck(payload: Uint8Array): AssetAckPayload {
    return JSON.parse(SignalCodec.bytesToString(payload)) as AssetAckPayload;
  }

  /** base64 编码（资产分片数据载荷；ArkTS 无内置 Base64Helper 时自实现） */
  static base64Encode(bytes: Uint8Array): string {
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    // C03 优化（验收③）：result += 逐 4 字符拼接会产生大量中间字符串（64KB → 2.1 万次 +=）。
    // 改 parts.push + join，避免 O(n²) 字符串拷贝，64KB 分片编码耗时显著下降。
    const parts: string[] = [];
    for (let i = 0; i < bytes.length; i += 3) {
      const b0: number = bytes[i];
      const b1: number = i + 1 < bytes.length ? bytes[i + 1] : 0;
      const b2: number = i + 2 < bytes.length ? bytes[i + 2] : 0;
      const n: number = (b0 << 16) | (b1 << 8) | b2;
      parts.push(chars.charAt((n >> 18) & 63));
      parts.push(chars.charAt((n >> 12) & 63));
      parts.push(i + 1 < bytes.length ? chars.charAt((n >> 6) & 63) : '=');
      parts.push(i + 2 < bytes.length ? chars.charAt(n & 63) : '=');
    }
    return parts.join('');
  }

  /** base64 解码（资产分片数据载荷；容错：忽略非法字符） */
  static base64Decode(b64: string): Uint8Array {
    const chars: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const out: number[] = [];
    let buffer: number = 0;
    let bits: number = 0;
    for (let i = 0; i < b64.length; i++) {
      const c: string = b64.charAt(i);
      if (c === '=') {
        break;
      }
      const idx: number = chars.indexOf(c);
      if (idx < 0) {
        continue;
      }
      buffer = (buffer << 6) | idx;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xFF);
      }
    }
    return Uint8Array.from(out);
  }

  /** CRC32（IEEE 802.3，零三方依赖；每片校验，t25 §2.3） */
  static crc32(bytes: Uint8Array): number {
    let crc: number = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) {
      crc ^= bytes[i];
      for (let k = 0; k < 8; k++) {
        const mask: number = (crc & 1) !== 0 ? 0xEDB88320 : 0;
        crc = (crc >>> 1) ^ mask;
      }
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  /** FNV-1a 32 位（整文件校验 == imageHash 口径，与 .hcnote checksum 算法一致；t25 §2.3） */
  static fnv1aBytes(bytes: Uint8Array): string {
    let hash: number = 0x811C9DC5;
    for (let i = 0; i < bytes.length; i++) {
      hash ^= bytes[i];
      hash = (hash * 0x01000193) >>> 0;
    }
    return `fnv1a:${hash.toString(16).padStart(8, '0')}`;
  }

  /** 视口同步编码（MSG_VIEWPORT_SYNC，低频控制消息，不进 CRDT） */
  static encodeViewportSync(vp: ViewportSyncPayload): Uint8Array {
    const payload: Uint8Array = SignalCodec.stringToBytes(JSON.stringify(vp));
    return SignalCodec.encode({
      msg_id: `vp_${Date.now()}`,
      msg_type: MsgType.MSG_VIEWPORT_SYNC,
      payload: payload,
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  /** 视口同步解码 */
  static decodeViewportSync(payload: Uint8Array): ViewportSyncPayload {
    const json: string = SignalCodec.bytesToString(payload);
    const vp: ViewportSyncPayload = JSON.parse(json) as ViewportSyncPayload;
    return vp;
  }

  /** 权限断言编码（MSG_PERMISSION_ASSERT，加入会话时携带） */
  static encodePermissionAssertion(assertion: PermissionAssertionPayload): Uint8Array {
    const payload: Uint8Array = SignalCodec.stringToBytes(JSON.stringify(assertion));
    return SignalCodec.encode({
      msg_id: `pa_${Date.now()}`,
      msg_type: MsgType.MSG_PERMISSION_ASSERT,
      payload: payload,
      timestamp: Date.now(),
      sender_id: assertion.device_id
    });
  }

  /** 权限断言解码 */
  static decodePermissionAssertion(payload: Uint8Array): PermissionAssertionPayload {
    const json: string = SignalCodec.bytesToString(payload);
    const assertion: PermissionAssertionPayload = JSON.parse(json) as PermissionAssertionPayload;
    return assertion;
  }

  /** CanvasElement 全类型编码（S2T03：Stroke/Shape/TextBlock/Annotation/ImageRef） */
  static encodeCanvasElement(element: CanvasElement): Uint8Array {
    const payload: Uint8Array = SignalCodec.stringToBytes(JSON.stringify(element));
    return SignalCodec.encode({
      msg_id: `el_${Date.now()}`,
      msg_type: MsgType.MSG_CRDT_OP,
      payload: payload,
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  /** CanvasElement 全类型解码 */
  static decodeCanvasElement(payload: Uint8Array): CanvasElement {
    const json: string = SignalCodec.bytesToString(payload);
    const element: CanvasElement = JSON.parse(json) as CanvasElement;
    return element;
  }

  static encodeHeartbeat(): Uint8Array {
    return SignalCodec.encode({
      msg_id: `hb_${Date.now()}`,
      msg_type: MsgType.MSG_HEARTBEAT,
      payload: new Uint8Array(0),
      timestamp: Date.now(),
      sender_id: SignalCodec.readUserId()
    });
  }

  // ─── 工具方法 ───

  private static readUserId(): string {
    try {
      // C01 转派③（C03 落地）：身份单一源 SessionIdentity.userId()。
      // 服务端签发 > 回退 siteId —— 离线时两个用户各回退各的 siteId，不再撞车为 'unknown'。
      // 删除旧的 AppStorage.get('userId') 直接取值路径（离线回退 'unknown' 导致 sender_id 撞车）。
      const value: string = SessionIdentity.getInstance().userId();
      return value;
    } catch (err) {
      // Node 验证环境无 ArkUI AppStorage，回退 'unknown'
      return 'unknown';
    }
  }

  private static encodeTagLengthValue(tag: number, value: Uint8Array): Uint8Array {
    const lengthBytes = SignalCodec.encodeVarint(value.length);
    return SignalCodec.concatBytes([new Uint8Array([tag]), lengthBytes, value]);
  }

  private static encodeVarintField(tag: number, value: number): Uint8Array {
    const tagBytes = new Uint8Array([tag]);
    const valueBytes = SignalCodec.encodeVarint(value);
    return SignalCodec.concatBytes([tagBytes, valueBytes]);
  }

  private static encodeVarint(value: number): Uint8Array {
    const bytes: number[] = [];
    let v = value;
    // Q13 修复：v >>>= 7 会把 v 截断到 32 位（Date.now() 时间戳 1.7e12 > 2^32 会丢失高位）。
    // 改用 Math.floor(v / 128)，配合下方 readVarint 的 value += (byte & 0x7F) * 2^shift，
    // 支持 > 2^32 且不溢出（JS number 双精度安全整数 2^53 内精确）。
    while (v >= 128) {
      bytes.push((v % 128) | 0x80);
      v = Math.floor(v / 128);
    }
    bytes.push(v % 128);
    return new Uint8Array(bytes);
  }

  /** varint 最大字节数（protobuf int64 上限 10 字节；超出视为畸形 → 截断） */
  private static readonly MAX_VARINT_BYTES: number = 10;

  private static readVarint(data: Uint8Array, startPos: number): VarintResult {
    let value = 0;
    let shift = 0;
    let pos = startPos;
    let count = 0;
    // Q13 修复：value |= (byte & 0x7F) << shift 在 shift >= 32 时左移溢出（JS 位运算 32 位），
    // 超长 varint 会整数回绕。改用 value += (byte & 0x7F) * Math.pow(2, shift) 精确累加；
    // 同时以 MAX_VARINT_BYTES 截断超长序列（防无限循环 + 防整数回绕）。
    while (pos < data.length && count < SignalCodec.MAX_VARINT_BYTES) {
      const byte = data[pos];
      value += (byte & 0x7F) * Math.pow(2, shift);
      pos++;
      count++;
      if ((byte & 0x80) === 0) {
        break;
      }
      shift += 7;
    }
    const result: VarintResult = { value: value, endPos: pos };
    return result;
  }

  private static concatBytes(arrays: Uint8Array[]): Uint8Array {
    const totalLength = arrays.reduce((sum, arr) => sum + arr.length, 0);
    const result = new Uint8Array(totalLength);
    let offset = 0;
    for (const arr of arrays) {
      result.set(arr, offset);
      offset += arr.length;
    }
    return result;
  }

  private static stringToBytes(str: string): Uint8Array {
    // ArkTS 无全局 TextEncoder，使用 @kit.ArkTS 的 util.TextEncoder
    const encoder = new util.TextEncoder();
    return encoder.encodeInto(str);
  }

  private static bytesToString(bytes: Uint8Array): string {
    const decoder = new util.TextDecoder();
    return decoder.decodeToString(bytes);
  }
}
