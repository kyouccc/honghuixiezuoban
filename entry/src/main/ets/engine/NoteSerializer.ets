/**
 * NoteSerializer.ets — `.hcnote` 序列化 / 反序列化（v2.4 阶段一，T1-2）
 *
 * 职责（架构 §3.4 W2 / §5.2）：
 *  1. NoteContent ↔ `.hcnote` JSON 文本 双向转换（含 7 个阶段二/三扩展空位占位）；
 *  2. 坐标 2 位小数量化，并**回写内存**——保证 save→load→save 字节级幂等（A1-1 / A1-7）；
 *  3. StrokeRecord ↔ HCStroke 双向映射（页面内存态 ↔ 落盘 DTO）；
 *  4. Layer → HCLayer 白名单逐字段投影（⚠️ 必须剔除 offscreenCanvas，S-3）；
 *  5. ImageRefData ↔ HCImage 双向映射（阶段一只存 uri，U-4）；
 *  6. FNV-1a 32 位 checksum 生成与校验（校验失败只降级告警，不阻断读取，S-5）；
 *  7. 版本迁移桩 migrate()：v1 直通，未来版本在此追加分支。
 *
 * 幂等三原则（本文件必须长期遵守）：
 *  - 序列化**不修改** meta.updatedAt（由 NoteRepository 在真正 dirty 时才 bump）；
 *  - 文件内 meta.sizeBytes **恒写 0**（真实体积只存索引层），避免"体积字段自引用"导致字节漂移；
 *  - 所有浮点先量化再写盘，且量化结果同步回写内存对象。
 *
 * ArkTS 严格模式：无 any/unknown、无对象展开、JSON.parse 结果显式 as 到 *Raw 类型。
 */

import { Logger } from '../common/Logger';
import { Layer } from './LayerManager';
import { CanvasElement, ImageRefData } from './types/CanvasElement';
import { RGASnapshot } from '../crdt/RGAEngine';
import { CRDTOp } from '../crdt/types/CRDTOp';
import {
  HC_APP_ID,
  HC_APP_VERSION,
  HC_CHECKSUM_PREFIX,
  HC_DEFAULT_BACKGROUND,
  HC_DEFAULT_PAPER,
  HC_LOCAL_AUTHOR,
  HC_NOTE_ENCODING_JSON,
  HC_NOTE_MAGIC,
  HC_NOTE_SCHEMA_VERSION,
  HC_POINT_FORMAT_XY,
  HC_THUMB_FORMAT,
  HCAnnotation,
  HCAnnotationRaw,
  HCDoc,
  HCDocRaw,
  HCFlashcard,
  HCFlashcardRaw,
  HCImage,
  HCImageRaw,
  HCLayer,
  HCLayerRaw,
  HCMindEdge,
  HCMindEdgeRaw,
  HCMindMap,
  HCMindMapRaw,
  HCMindNode,
  HCMindNodeRaw,
  HCNoteFile,
  HCNoteFileRaw,
  HCStroke,
  HCStrokeRaw,
  HCText,
  HCTextRaw,
  HCThumb,
  HCThumbRaw,
  NoteContent,
  NoteMeta,
  NoteMetaRaw,
  NotePaper,
  NotePaperRaw,
  NoteViewport,
  NoteViewportRaw,
  PointRecord,
  StrokeRecord,
  createNoteId,
  createNoteMeta,
  normalizeNoteTitle,
} from './types/NoteModel';

const TAG_MODULE = 'NoteSerializer';

/** 合法底纸模板白名单，非法值一律降级 blank（不抛异常） */
const PAPER_TEMPLATE_WHITELIST: string[] = ['blank', 'grid', 'dot', 'lined', 'four_line'];

/** checksum 十六进制长度（8）+ 前缀 'fnv1a:'（6）= 14，用于体积预估 */
const CHECKSUM_TEXT_LENGTH: number = 14;

/** 反序列化结果（NoteRepository 内部使用；对 UI 再包一层 NoteLoadResult） */
export interface NoteDeserializeResult {
  /** 是否成功解析出可用内容（magic / JSON 结构合法） */
  ok: boolean;
  /** 解析后的内存态内容；失败时为空内容，绝不为 null（S-5） */
  content: NoteContent;
  /** checksum 是否一致；false 仅告警，不影响 ok */
  checksumMatched: boolean;
  /** 原文件 schemaVersion */
  fileSchemaVersion: number;
  /** 是否执行过版本迁移 */
  migrated: boolean;
  /** 失败原因，成功时为空串 */
  errorMessage: string;
  /** 非阻断加载告警（T2-1b P1）：空串=无告警；如「已跳过 N 笔坐标异常笔画」「笔画数与元信息不一致」 */
  loadWarning: string;
}

/** rawToContent 方法返回结果 */
interface RawToContentResult {
  content: NoteContent;
  loadWarning: string;
}

/** readStrokes 方法返回结果 */
interface ReadStrokesResult {
  strokes: HCStroke[];
  skipped: number;
}

// ═══════════════════════════════════════════════════════════════════
// 私有取值兜底工具（ArkTS 无可选链默认值语法糖，统一收口）
// ═══════════════════════════════════════════════════════════════════

function pickString(value: string | undefined, fallback: string): string {
  return value !== undefined && value !== null ? value : fallback;
}

function pickNumber(value: number | undefined, fallback: number): number {
  if (value === undefined || value === null) {
    return fallback;
  }
  if (!Number.isFinite(value)) {
    return fallback;
  }
  return value;
}

function pickBoolean(value: boolean | undefined, fallback: boolean): boolean {
  return value !== undefined && value !== null ? value : fallback;
}

function pickStringArray(value: string[] | undefined): string[] {
  return value !== undefined && value !== null ? value.slice() : [];
}

function pickNumberArray(value: number[] | undefined): number[] {
  return value !== undefined && value !== null ? value.slice() : [];
}

export class NoteSerializer {
  /** 坐标 / 宽度 / 透明度统一保留 2 位小数 */
  static readonly DECIMALS: number = 2;

  // ═══════════════════════════════════════════════════════════════
  // 一、数值量化
  // ═══════════════════════════════════════════════════════════════

  /**
   * 2 位小数量化。
   * 反复调用结果稳定（q(q(x)) === q(x)），是字节级幂等的基石（A1-7）。
   * 非有限数（NaN/Infinity）统一归 0，避免 JSON.stringify 产出 null 破坏 schema。
   */
  static quantize(value: number): number {
    if (value === undefined || value === null || !Number.isFinite(value)) {
      return 0;
    }
    const rounded: number = Math.round(value * 100) / 100;
    // 消除 -0：JSON.stringify(-0) 虽输出 "0"，但内存比较时会造成困扰
    return rounded === 0 ? 0 : rounded;
  }

  /** 量化并 clamp 到 [min,max] */
  static quantizeClamped(value: number, min: number, max: number): number {
    const q: number = NoteSerializer.quantize(value);
    if (q < min) {
      return min;
    }
    if (q > max) {
      return max;
    }
    return q;
  }

  /** 画布尺寸取整（整数 vp，避免 0.01 抖动） */
  static roundSize(value: number): number {
    if (value === undefined || value === null || !Number.isFinite(value) || value < 0) {
      return 0;
    }
    return Math.round(value);
  }

  /** 底纸模板归一化，非法值降级 blank 并记 warn */
  static normalizePaperTemplate(template: string): string {
    const t: string = pickString(template, HC_DEFAULT_PAPER);
    if (PAPER_TEMPLATE_WHITELIST.indexOf(t) >= 0) {
      return t;
    }
    Logger.warn(TAG_MODULE, `未知底纸模板 ${t}，降级为 ${HC_DEFAULT_PAPER}`);
    return HC_DEFAULT_PAPER;
  }

  // ═══════════════════════════════════════════════════════════════
  // 二、FNV-1a 32 位校验和
  // ═══════════════════════════════════════════════════════════════

  /**
   * FNV-1a 32bit。
   * 不使用 Math.imul（部分 ArkTS 运行时对其支持不稳定），改用 FNV 素数 16777619 的移位分解：
   *   16777619 = 2^24 + 2^8 + 2^7 + 2^4 + 2^1 + 1
   * 中文标题等非 ASCII 字符按 UTF-16 码元的低字节 / 高字节依次喂入，结果稳定可复现。
   *
   * @returns 形如 `fnv1a:1a2b3c4d` 的小写十六进制串
   */
  static checksum(text: string): string {
    let hash: number = 0x811c9dc5;
    const len: number = text.length;
    for (let i = 0; i < len; i++) {
      const code: number = text.charCodeAt(i);
      hash = NoteSerializer.fnvMix(hash, code & 0xff);
      if (code > 0xff) {
        hash = NoteSerializer.fnvMix(hash, (code >>> 8) & 0xff);
      }
    }
    let hex: string = (hash >>> 0).toString(16);
    while (hex.length < 8) {
      hex = `0${hex}`;
    }
    return `${HC_CHECKSUM_PREFIX}${hex}`;
  }

  private static fnvMix(hash: number, byte: number): number {
    let h: number = (hash ^ byte) >>> 0;
    h = (h + ((h << 1) + (h << 4) + (h << 7) + (h << 8) + (h << 24))) >>> 0;
    return h;
  }

  // ═══════════════════════════════════════════════════════════════
  // 三、StrokeRecord ↔ HCStroke（页面内存态 ↔ 落盘 DTO）
  // ═══════════════════════════════════════════════════════════════

  /**
   * 内存笔画 → 落盘笔画。
   * ⚠️ 副作用（有意为之）：量化后的坐标 / 宽度 / 透明度会**回写** record，
   *    否则第二次保存会因为浮点尾差产出不同字节，A1-7 无法达标。
   */
  static strokeRecordToHC(record: StrokeRecord, fallbackLayerId: string): HCStroke {
    const flat: number[] = [];
    const pressureValues: number[] = [];
    const points: PointRecord[] = record.points !== undefined && record.points !== null ? record.points : [];
    // S2-A / T2-2：仅当全部点都有有效压感时才写 pressure 平行数组（与 points 1:1、2 位量化+回写幂等）；
    // 任一点缺压感 → 整笔不写 pressure（保持旧文件形态，无压感 fixture 字节级零变化）
    let hasPressure: boolean = true;
    for (let i = 0; i < points.length; i++) {
      const p: PointRecord = points[i];
      const qx: number = NoteSerializer.quantize(p.x);
      const qy: number = NoteSerializer.quantize(p.y);
      // 回写内存，保证幂等
      p.x = qx;
      p.y = qy;
      flat.push(qx);
      flat.push(qy);
      if (p.pressure !== undefined && p.pressure !== null && Number.isFinite(p.pressure)) {
        const qp: number = NoteSerializer.quantize(p.pressure);
        p.pressure = qp;
        pressureValues.push(qp);
      } else {
        hasPressure = false;
        pressureValues.push(0);
      }
    }
    const qWidth: number = NoteSerializer.quantizeClamped(record.width, 0.1, 200);
    const qOpacity: number = NoteSerializer.quantizeClamped(record.opacity, 0, 1);
    record.width = qWidth;
    record.opacity = qOpacity;

    const layerId: string = record.layerId !== undefined && record.layerId.length > 0
      ? record.layerId
      : fallbackLayerId;
    record.layerId = layerId;

    const hc: HCStroke = {
      id: `s_${record.id}`,
      layerId: layerId,
      tool: pickString(record.tool, 'pen'),
      color: pickString(record.color, '#000000'),
      width: qWidth,
      opacity: qOpacity,
      blendMode: pickString(record.blendMode, 'normal'),
      brushShape: pickString(record.brushShape, 'round'),
      texture: '',
      points: flat,
      createdAt: record.createdAt > 0 ? record.createdAt : 0,
      createdBy: HC_LOCAL_AUTHOR,
    };
    if (hasPressure && pressureValues.length === points.length) {
      hc.pressure = pressureValues;
    }
    return hc;
  }

  /** 批量：内存笔画数组 → 落盘笔画数组 */
  static strokeRecordsToHC(records: StrokeRecord[], fallbackLayerId: string): HCStroke[] {
    const result: HCStroke[] = [];
    for (let i = 0; i < records.length; i++) {
      result.push(NoteSerializer.strokeRecordToHC(records[i], fallbackLayerId));
    }
    return result;
  }

  /**
   * 落盘笔画 → 内存笔画。
   * StrokeRecord.id 为页面自增数字，恢复时按下标重排（0..n-1），
   * 撤销 / 重做只依赖数组顺序，不依赖 id 数值本身。
   */
  static hcToStrokeRecord(stroke: HCStroke, index: number): StrokeRecord {
    const flat: number[] = stroke.points !== undefined && stroke.points !== null ? stroke.points : [];
    const points: PointRecord[] = [];
    // 奇数长度视为脏数据，丢弃最后一个孤立分量
    const pairCount: number = Math.floor(flat.length / 2);
    // S2-A / T2-2：pressure 平行数组（1:1 对应 points 对）；缺省=无压感旧文件 → PointRecord.pressure undefined
    const pressureRaw: number[] = stroke.pressure !== undefined && stroke.pressure !== null ? stroke.pressure : [];
    const hasPressure: boolean = pressureRaw.length >= pairCount && pairCount > 0;
    for (let i = 0; i < pairCount; i++) {
      points.push({
        x: NoteSerializer.quantize(flat[i * 2]),
        y: NoteSerializer.quantize(flat[i * 2 + 1]),
        pressure: hasPressure ? NoteSerializer.quantize(pressureRaw[i]) : undefined,
      });
    }
    return {
      id: index,
      tool: pickString(stroke.tool, 'pen'),
      color: pickString(stroke.color, '#000000'),
      width: NoteSerializer.quantizeClamped(pickNumber(stroke.width, 3), 0.1, 200),
      points: points,
      opacity: NoteSerializer.quantizeClamped(pickNumber(stroke.opacity, 1), 0, 1),
      blendMode: pickString(stroke.blendMode, 'normal'),
      brushShape: pickString(stroke.brushShape, 'round'),
      layerId: pickString(stroke.layerId, ''),
      createdAt: pickNumber(stroke.createdAt, 0),
    };
  }

  /** 批量：落盘笔画数组 → 内存笔画数组 */
  static hcToStrokeRecords(strokes: HCStroke[]): StrokeRecord[] {
    const result: StrokeRecord[] = [];
    for (let i = 0; i < strokes.length; i++) {
      result.push(NoteSerializer.hcToStrokeRecord(strokes[i], i));
    }
    return result;
  }

  // ═══════════════════════════════════════════════════════════════
  // 四、Layer → HCLayer 白名单投影（S-3）
  // ═══════════════════════════════════════════════════════════════

  /**
   * ⚠️ 关键约束：Layer 携带 `offscreenCanvas: OffscreenCanvas | null` 与
   *   `strokes: RGAElement<StrokeData>[]`，直接 JSON.stringify(layer) 会抛异常或产出巨型脏数据。
   *   因此这里**逐字段白名单拷贝**，只取可序列化的元信息；笔画统一走顶层 strokes 段。
   */
  static projectLayer(layer: Layer, order: number): HCLayer {
    return {
      id: pickString(layer.id, ''),
      name: pickString(layer.name, '图层'),
      type: pickString(layer.type, 'draw'),
      opacity: NoteSerializer.quantizeClamped(pickNumber(layer.opacity, 1), 0, 1),
      visible: pickBoolean(layer.visible, true),
      locked: pickBoolean(layer.locked, false),
      groupId: pickString(layer.groupId, ''),
      paperTemplate: pickString(layer.paperTemplate, ''),
      pageRef: pickString(layer.pageRef, ''),
      order: order,
    };
  }

  /** 批量投影，order 取数组下标（LayerManager.getLayers 已按 z 序返回） */
  static projectLayers(layers: Layer[]): HCLayer[] {
    const result: HCLayer[] = [];
    for (let i = 0; i < layers.length; i++) {
      result.push(NoteSerializer.projectLayer(layers[i], i));
    }
    return result;
  }

  // ═══════════════════════════════════════════════════════════════
  // 五、ImageRefData ↔ HCImage（阶段一 uri-only，U-4）
  // ═══════════════════════════════════════════════════════════════

  static imageRefToHC(ref: ImageRefData): HCImage {
    return {
      id: pickString(ref.id, ''),
      layerId: pickString(ref.layerId, ''),
      imageHash: pickString(ref.imageHash, ''),
      mimeType: pickString(ref.mimeType, 'image/png'),
      x: NoteSerializer.quantize(pickNumber(ref.x, 0)),
      y: NoteSerializer.quantize(pickNumber(ref.y, 0)),
      width: NoteSerializer.quantize(pickNumber(ref.width, 0)),
      height: NoteSerializer.quantize(pickNumber(ref.height, 0)),
      uri: pickString(ref.uri, ''),
      // 阶段一二进制旁路未启用，恒空串（U-4）
      binaryRef: '',
      rotation: NoteSerializer.quantize(pickNumber(ref.rotation, 0)),
      scale: NoteSerializer.quantizeClamped(pickNumber(ref.scale, 1), 0.01, 100),
      createdBy: pickString(ref.createdBy, HC_LOCAL_AUTHOR),
      createdAt: pickNumber(ref.createdAt, 0),
    };
  }

  static imageRefsToHC(refs: ImageRefData[]): HCImage[] {
    const result: HCImage[] = [];
    for (let i = 0; i < refs.length; i++) {
      result.push(NoteSerializer.imageRefToHC(refs[i]));
    }
    return result;
  }

  static hcToImageRef(image: HCImage): ImageRefData {
    return {
      id: pickString(image.id, ''),
      layerId: pickString(image.layerId, ''),
      createdBy: pickString(image.createdBy, HC_LOCAL_AUTHOR),
      createdAt: pickNumber(image.createdAt, 0),
      imageHash: pickString(image.imageHash, ''),
      mimeType: pickString(image.mimeType, 'image/png'),
      x: pickNumber(image.x, 0),
      y: pickNumber(image.y, 0),
      width: pickNumber(image.width, 0),
      height: pickNumber(image.height, 0),
      binaryRef: '',
      uri: pickString(image.uri, ''),
      rotation: pickNumber(image.rotation, 0),
      scale: pickNumber(image.scale, 1),
    };
  }

  static hcToImageRefs(images: HCImage[]): ImageRefData[] {
    const result: ImageRefData[] = [];
    for (let i = 0; i < images.length; i++) {
      result.push(NoteSerializer.hcToImageRef(images[i]));
    }
    return result;
  }

  // ═══════════════════════════════════════════════════════════════
  // 五·补、HCDoc / HCAnnotation（T2-1 文档批注段）
  // ═══════════════════════════════════════════════════════════════

  /** 内存文档列表 → 落盘文档列表 */
  static docsToHC(docs: HCDoc[]): HCDoc[] {
    const result: HCDoc[] = [];
    for (let i = 0; i < docs.length; i++) {
      const d: HCDoc = docs[i];
      const refs: string[] = d.pageRefs !== undefined && d.pageRefs !== null ? d.pageRefs.slice() : [];
      result.push({
        docId: pickString(d.docId, ''),
        fileName: pickString(d.fileName, ''),
        format: pickString(d.format, 'pdf'),
        pageCount: Math.max(0, pickNumber(d.pageCount, 0)),
        pageRefs: refs,
        importedAt: pickNumber(d.importedAt, 0),
        sourcePath: pickString(d.sourcePath, ''),
      });
    }
    return result;
  }

  /** 内存批注列表 → 落盘批注列表（坐标量化回写，保证幂等） */
  static annotationsToHC(annotations: HCAnnotation[]): HCAnnotation[] {
    const result: HCAnnotation[] = [];
    for (let i = 0; i < annotations.length; i++) {
      const a: HCAnnotation = annotations[i];
      const flatRaw: number[] = pickNumberArray(a.points);
      const flat: number[] = [];
      const pairCount: number = Math.floor(flatRaw.length / 2);
      for (let k = 0; k < pairCount; k++) {
        flat.push(NoteSerializer.quantize(flatRaw[k * 2]));
        flat.push(NoteSerializer.quantize(flatRaw[k * 2 + 1]));
      }
      result.push({
        id: pickString(a.id, `a_${i}`),
        docId: pickString(a.docId, ''),
        pageIndex: Math.max(0, pickNumber(a.pageIndex, 0)),
        layerId: pickString(a.layerId, ''),
        tool: pickString(a.tool, 'pen'),
        color: pickString(a.color, '#000000'),
        width: NoteSerializer.quantizeClamped(pickNumber(a.width, 3), 0.1, 200),
        opacity: NoteSerializer.quantizeClamped(pickNumber(a.opacity, 1), 0, 1),
        points: flat,
        createdAt: pickNumber(a.createdAt, 0),
        createdBy: pickString(a.createdBy, HC_LOCAL_AUTHOR),
      });
    }
    return result;
  }

  // ═══════════════════════════════════════════════════════════════
  // 五·补二、HCText / HCFlashcard / HCMindMap（S2-B T2-3/T2-4 追加段）
  // ═══════════════════════════════════════════════════════════════

  /** 内存文本框列表 → 落盘文本框列表（S2-B / T2-3；坐标/字号量化，幂等） */
  static textsToHC(texts: HCText[]): HCText[] {
    const result: HCText[] = [];
    const list: HCText[] = texts !== undefined && texts !== null ? texts : [];
    for (let i = 0; i < list.length; i++) {
      const t: HCText = list[i];
      result.push({
        id: pickString(t.id, `text_${i}`),
        layerId: pickString(t.layerId, ''),
        text: pickString(t.text, ''),
        x: NoteSerializer.quantize(pickNumber(t.x, 0)),
        y: NoteSerializer.quantize(pickNumber(t.y, 0)),
        fontSize: NoteSerializer.quantizeClamped(pickNumber(t.fontSize, 20), 8, 120),
        fontFamily: pickString(t.fontFamily, 'HarmonyOS Sans'),
        align: pickString(t.align, 'left'),
        color: pickString(t.color, '#000000'),
        createdBy: pickString(t.createdBy, HC_LOCAL_AUTHOR),
        createdAt: pickNumber(t.createdAt, 0),
      });
    }
    return result;
  }

  /** 内存闪卡列表 → 落盘闪卡列表（S2-B / T2-4；SM-2 状态原样，量化数值域） */
  static flashcardsToHC(flashcards: HCFlashcard[]): HCFlashcard[] {
    const result: HCFlashcard[] = [];
    const list: HCFlashcard[] = flashcards !== undefined && flashcards !== null ? flashcards : [];
    for (let i = 0; i < list.length; i++) {
      const c: HCFlashcard = list[i];
      result.push({
        id: pickString(c.id, `card_${i}`),
        question: pickString(c.question, ''),
        answer: pickString(c.answer, ''),
        box: Math.max(0, Math.min(5, Math.round(pickNumber(c.box, 0)))),
        ease: NoteSerializer.quantizeClamped(pickNumber(c.ease, 2.5), 1.3, 2.5),
        interval: Math.max(0, Math.round(pickNumber(c.interval, 0))),
        dueAt: Math.max(0, Math.round(pickNumber(c.dueAt, 0))),
        reps: Math.max(0, Math.round(pickNumber(c.reps, 0))),
        lapses: Math.max(0, Math.round(pickNumber(c.lapses, 0))),
        createdAt: Math.max(0, Math.round(pickNumber(c.createdAt, 0))),
      });
    }
    return result;
  }

  /** 内存导图列表 → 落盘导图列表（S2-B / T2-4；节点坐标量化） */
  static mindMapsToHC(mindmaps: HCMindMap[]): HCMindMap[] {
    const result: HCMindMap[] = [];
    const list: HCMindMap[] = mindmaps !== undefined && mindmaps !== null ? mindmaps : [];
    for (let i = 0; i < list.length; i++) {
      const m: HCMindMap = list[i];
      const nodes: HCMindNode[] = [];
      const srcNodes: HCMindNode[] = m.nodes !== undefined && m.nodes !== null ? m.nodes : [];
      for (let k = 0; k < srcNodes.length; k++) {
        const n: HCMindNode = srcNodes[k];
        nodes.push({
          id: pickString(n.id, `n_${k}`),
          label: pickString(n.label, ''),
          x: NoteSerializer.quantize(pickNumber(n.x, 0)),
          y: NoteSerializer.quantize(pickNumber(n.y, 0)),
          parentId: pickString(n.parentId, ''),
        });
      }
      const edges: HCMindEdge[] = [];
      const srcEdges: HCMindEdge[] = m.edges !== undefined && m.edges !== null ? m.edges : [];
      for (let k = 0; k < srcEdges.length; k++) {
        const e: HCMindEdge = srcEdges[k];
        edges.push({
          id: pickString(e.id, `e_${k}`),
          from: pickString(e.from, ''),
          to: pickString(e.to, ''),
        });
      }
      result.push({
        id: pickString(m.id, `map_${i}`),
        title: pickString(m.title, '思维导图'),
        rootLabel: pickString(m.rootLabel, '中心主题'),
        nodes: nodes,
        edges: edges,
        createdAt: Math.max(0, Math.round(pickNumber(m.createdAt, 0))),
      });
    }
    return result;
  }

  // ═══════════════════════════════════════════════════════════════
  // 六、NoteContent → HCNoteFile → 文本
  // ═══════════════════════════════════════════════════════════════

  /**
   * 构造文件对象（checksum 留空）。
   * 字段书写顺序 == JSON 键顺序 == 落盘字节顺序，请勿随意调整。
   */
  private static buildFile(content: NoteContent): HCNoteFile {
    const template: string = NoteSerializer.normalizePaperTemplate(content.paper.template);
    const canvasW: number = NoteSerializer.roundSize(content.canvasWidth);
    const canvasH: number = NoteSerializer.roundSize(content.canvasHeight);

    const meta: NoteMeta = {
      id: pickString(content.meta.id, ''),
      title: normalizeNoteTitle(content.meta.title, '未命名笔记'),
      createdAt: pickNumber(content.meta.createdAt, 0),
      // 注意：序列化过程绝不 bump updatedAt，由 NoteRepository 在真正 dirty 时更新
      updatedAt: pickNumber(content.meta.updatedAt, 0),
      paperTemplate: template,
      strokeCount: content.strokes.length,
      favorite: pickBoolean(content.meta.favorite, false),
      tags: pickStringArray(content.meta.tags),
      thumbRef: pickString(content.meta.thumbRef, ''),
      schemaVersion: HC_NOTE_SCHEMA_VERSION,
      // 恒 0：真实体积只写索引层，避免自引用导致字节漂移（见文件头「幂等三原则」）
      sizeBytes: 0,
      canvasWidth: canvasW,
      canvasHeight: canvasH,
    };

    const paper: NotePaper = {
      template: template,
      layerId: pickString(content.paper.layerId, ''),
      backgroundColor: pickString(content.paper.backgroundColor, HC_DEFAULT_BACKGROUND),
    };

    const viewport: NoteViewport = {
      x: NoteSerializer.quantize(content.viewport.x),
      y: NoteSerializer.quantize(content.viewport.y),
      scale: NoteSerializer.quantizeClamped(content.viewport.scale, 0.1, 10),
    };
    // 量化回写内存（幂等）
    content.viewport.x = viewport.x;
    content.viewport.y = viewport.y;
    content.viewport.scale = viewport.scale;
    content.meta.paperTemplate = template;
    content.meta.strokeCount = meta.strokeCount;
    content.canvasWidth = canvasW;
    content.canvasHeight = canvasH;

    const thumb: HCThumb = {
      format: HC_THUMB_FORMAT,
      ref: pickString(content.meta.thumbRef, ''),
      inline: '',
    };

    return {
      magic: HC_NOTE_MAGIC,
      schemaVersion: HC_NOTE_SCHEMA_VERSION,
      encoding: HC_NOTE_ENCODING_JSON,
      app: HC_APP_ID,
      appVersion: HC_APP_VERSION,
      pointFormat: HC_POINT_FORMAT_XY,
      meta: meta,
      paper: paper,
      viewport: viewport,
      layers: content.layers.slice(),
      strokes: content.strokes.slice(),
      images: content.images.slice(),
      // ── 阶段二 / 三扩展空位（5 个）；v2 起 docs / annotations 为具体 DTO ──
      shapes: [],
      texts: NoteSerializer.textsToHC(content.texts),
      docs: NoteSerializer.docsToHC(
        content.docs !== undefined && content.docs !== null ? content.docs : []),
      annotations: NoteSerializer.annotationsToHC(
        content.annotations !== undefined && content.annotations !== null ? content.annotations : []),
      flashcards: NoteSerializer.flashcardsToHC(content.flashcards),
      mindmaps: NoteSerializer.mindMapsToHC(content.mindmaps),
      aiIndex: null,
      thumb: thumb,
      checksum: '',
    };
  }

  /**
   * NoteContent → `.hcnote` 文本。
   *
   * checksum 覆盖范围 = "checksum 字段为空串时的完整 JSON 文本"，
   * 校验侧按同一规则重建后比对，规则对称、无需额外裁剪逻辑。
   */
  static serialize(content: NoteContent): string {
    const file: HCNoteFile = NoteSerializer.buildFile(content);
    const body: string = JSON.stringify(file);
    file.checksum = NoteSerializer.checksum(body);
    const text: string = JSON.stringify(file);
    // 真实体积回写内存（供索引层与容量预警使用），文件内仍为 0
    content.meta.sizeBytes = text.length;
    return text;
  }

  /** 预估序列化体积（不做真正序列化，用于容量预警） */
  static estimateSize(content: NoteContent): number {
    const file: HCNoteFile = NoteSerializer.buildFile(content);
    return JSON.stringify(file).length + CHECKSUM_TEXT_LENGTH;
  }

  // ═══════════════════════════════════════════════════════════════
  // 七、文本 → NoteContent
  // ═══════════════════════════════════════════════════════════════

  /**
   * `.hcnote` 文本 → 内存态内容。
   * **本方法不抛异常**：任何解析失败都返回 ok=false + 空内容 + errorMessage（S-5）。
   *
   * @param text     文件原文
   * @param fallbackId 解析失败或 meta.id 缺失时使用的兜底 id
   */
  static deserialize(text: string, fallbackId: string): NoteDeserializeResult {
    const safeId: string = fallbackId.length > 0 ? fallbackId : createNoteId();
    if (text === undefined || text === null || text.length === 0) {
      return NoteSerializer.buildFailure(safeId, '文件为空');
    }

    let raw: HCNoteFileRaw;
    try {
      raw = JSON.parse(text) as HCNoteFileRaw;
    } catch (error) {
      const err: Error = error as Error;
      Logger.error(TAG_MODULE, `JSON 解析失败: ${err.message}`);
      return NoteSerializer.buildFailure(safeId, `JSON 解析失败: ${err.message}`);
    }
    if (raw === undefined || raw === null) {
      return NoteSerializer.buildFailure(safeId, 'JSON 解析结果为空');
    }

    const magic: string = pickString(raw.magic, '');
    if (magic !== HC_NOTE_MAGIC) {
      Logger.error(TAG_MODULE, `magic 不匹配: 期望 ${HC_NOTE_MAGIC}，实际 ${magic}`);
      return NoteSerializer.buildFailure(safeId, `文件魔数非法（${magic}）`);
    }

    const fileVersion: number = pickNumber(raw.schemaVersion, 0);
    const migrated: boolean = fileVersion !== HC_NOTE_SCHEMA_VERSION;
    const normalized: HCNoteFileRaw = NoteSerializer.migrate(raw, fileVersion);

    const converted: RawToContentResult = NoteSerializer.rawToContent(normalized, safeId);
    const content: NoteContent = converted.content;
    // 前向兼容：文件版本高于当前实现时，原样保留全文（§2.8）
    content.forwardRaw = fileVersion > HC_NOTE_SCHEMA_VERSION ? text : '';

    // checksum 复核：按"重建 + 置空 checksum"规则比对
    const declared: string = pickString(normalized.checksum, '');
    let matched: boolean = true;
    if (declared.length > 0) {
      const rebuilt: HCNoteFile = NoteSerializer.buildFile(content);
      const actual: string = NoteSerializer.checksum(JSON.stringify(rebuilt));
      matched = actual === declared;
      if (!matched) {
        Logger.warn(TAG_MODULE, `checksum 不一致（期望 ${declared} / 实际 ${actual}），内容仍按可用处理`);
      }
    }

    return {
      ok: true,
      content: content,
      checksumMatched: matched,
      fileSchemaVersion: fileVersion,
      migrated: migrated,
      errorMessage: '',
      loadWarning: converted.loadWarning,
    };
  }

  /** 逐字段兜底转换：宽松 Raw → 严格 NoteContent（T2-1b P1：附带 loadWarning） */
  private static rawToContent(raw: HCNoteFileRaw, fallbackId: string): RawToContentResult {
    const metaRaw: NoteMetaRaw = raw.meta !== undefined && raw.meta !== null ? raw.meta : {};
    const paperRaw: NotePaperRaw = raw.paper !== undefined && raw.paper !== null ? raw.paper : {};
    const viewportRaw: NoteViewportRaw = raw.viewport !== undefined && raw.viewport !== null ? raw.viewport : {};
    const thumbRaw: HCThumbRaw = raw.thumb !== undefined && raw.thumb !== null ? raw.thumb : {};

    const id: string = pickString(metaRaw.id, '').length > 0 ? pickString(metaRaw.id, '') : fallbackId;
    const template: string = NoteSerializer.normalizePaperTemplate(
      pickString(metaRaw.paperTemplate, pickString(paperRaw.template, HC_DEFAULT_PAPER))
    );

    const strokesResult: ReadStrokesResult = NoteSerializer.readStrokes(raw.strokes);
    const strokes: HCStroke[] = strokesResult.strokes;
    const layers: HCLayer[] = NoteSerializer.readLayers(raw.layers);
    const images: HCImage[] = NoteSerializer.readImages(raw.images);
    // v1 文件无 docs / annotations 字段，按缺省空数组兜底（向下兼容，绝不抛异常）
    const docs: HCDoc[] = NoteSerializer.readDocs(raw.docs);
    const annotations: HCAnnotation[] = NoteSerializer.readAnnotations(raw.annotations);
    // S2-B / T2-3/T2-4：texts / flashcards / mindmaps 同批追加，v1 缺省空数组
    const texts: HCText[] = NoteSerializer.readTexts(raw.texts);
    const flashcards: HCFlashcard[] = NoteSerializer.readFlashcards(raw.flashcards);
    const mindmaps: HCMindMap[] = NoteSerializer.readMindMaps(raw.mindmaps);

    // T2-1b P1：非阻断加载告警——跳过坏笔优先报告；否则元信息 strokeCount 与实际载入数不一致也告警
    let loadWarning: string = '';
    if (strokesResult.skipped > 0) {
      loadWarning = `已跳过 ${strokesResult.skipped} 笔坐标异常（非有限数）的笔画`;
    } else {
      const declaredCount: number = pickNumber(metaRaw.strokeCount, strokes.length);
      if (declaredCount !== strokes.length) {
        loadWarning = `笔画数与文件元信息不一致（元信息 ${declaredCount} 笔，实际载入 ${strokes.length} 笔）`;
      }
    }

    const meta: NoteMeta = {
      id: id,
      title: normalizeNoteTitle(pickString(metaRaw.title, ''), '未命名笔记'),
      createdAt: pickNumber(metaRaw.createdAt, 0),
      updatedAt: pickNumber(metaRaw.updatedAt, 0),
      paperTemplate: template,
      strokeCount: strokes.length,
      favorite: pickBoolean(metaRaw.favorite, false),
      tags: pickStringArray(metaRaw.tags),
      thumbRef: pickString(metaRaw.thumbRef, pickString(thumbRaw.ref, `thumbs/${id}.txt`)),
      schemaVersion: HC_NOTE_SCHEMA_VERSION,
      sizeBytes: 0,
      canvasWidth: NoteSerializer.roundSize(pickNumber(metaRaw.canvasWidth, 0)),
      canvasHeight: NoteSerializer.roundSize(pickNumber(metaRaw.canvasHeight, 0)),
    };

    const paper: NotePaper = {
      template: template,
      layerId: pickString(paperRaw.layerId, ''),
      backgroundColor: pickString(paperRaw.backgroundColor, HC_DEFAULT_BACKGROUND),
    };

    const viewport: NoteViewport = {
      x: NoteSerializer.quantize(pickNumber(viewportRaw.x, 0)),
      y: NoteSerializer.quantize(pickNumber(viewportRaw.y, 0)),
      scale: NoteSerializer.quantizeClamped(pickNumber(viewportRaw.scale, 1), 0.1, 10),
    };

    const content: NoteContent = {
      meta: meta,
      paper: paper,
      viewport: viewport,
      layers: layers,
      strokes: strokes,
      images: images,
      docs: docs,
      annotations: annotations,
      texts: texts,
      flashcards: flashcards,
      mindmaps: mindmaps,
      nodes: [],
      links: [],
      bookmarks: [],
      canvasWidth: meta.canvasWidth,
      canvasHeight: meta.canvasHeight,
      forwardRaw: '',
    };
    const res: RawToContentResult = { content: content, loadWarning: loadWarning };
    return res;
  }

  private static readStrokes(list: HCStrokeRaw[] | undefined): ReadStrokesResult {
    const result: HCStroke[] = [];
    let skipped: number = 0;
    if (list === undefined || list === null) {
      const res: ReadStrokesResult = { strokes: result, skipped: skipped };
      return res;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCStrokeRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const flatRaw: number[] = pickNumberArray(item.points);
      // T2-1b P1：元素级有限数校验——任一坐标非有限数（NaN/Infinity/非 number）→ 该笔跳过，
      // 不产出全 0 原点簇笔（修复对象形态 points 误喂 deserialize 的静默丢数据边界）。
      // 绝不静默转 0、绝不崩溃；跳过数由调用方计入 loadWarning。
      if (!NoteSerializer.isFinitePointArray(flatRaw)) {
        skipped++;
        continue;
      }
      const flat: number[] = [];
      const pairCount: number = Math.floor(flatRaw.length / 2);
      for (let k = 0; k < pairCount; k++) {
        flat.push(NoteSerializer.quantize(flatRaw[k * 2]));
        flat.push(NoteSerializer.quantize(flatRaw[k * 2 + 1]));
      }
      // S2-A / T2-2：pressure 平行数组（1:1 对应 points 对，2 位量化）；缺省=无压感旧文件 → undefined（序列化省略）
      const pressureRaw: number[] = pickNumberArray(item.pressure);
      const hasPressure: boolean = pressureRaw.length >= pairCount && pairCount > 0;
      const hc: HCStroke = {
        id: pickString(item.id, `s_${i}`),
        layerId: pickString(item.layerId, ''),
        tool: pickString(item.tool, 'pen'),
        color: pickString(item.color, '#000000'),
        width: NoteSerializer.quantizeClamped(pickNumber(item.width, 3), 0.1, 200),
        opacity: NoteSerializer.quantizeClamped(pickNumber(item.opacity, 1), 0, 1),
        blendMode: pickString(item.blendMode, 'normal'),
        brushShape: pickString(item.brushShape, 'round'),
        texture: pickString(item.texture, ''),
        points: flat,
        createdAt: pickNumber(item.createdAt, 0),
        createdBy: pickString(item.createdBy, HC_LOCAL_AUTHOR),
      };
      if (hasPressure) {
        const quantized: number[] = [];
        for (let k = 0; k < pairCount; k++) {
          quantized.push(NoteSerializer.quantize(pressureRaw[k]));
        }
        hc.pressure = quantized;
      }
      result.push(hc);
    }
    const res: ReadStrokesResult = { strokes: result, skipped: skipped };
    return res;
  }

  /** 点数组元素级有限数校验（T2-1b P1）：全部为有限数才返回 true；空数组视为有效（无点笔画不拦截） */
  private static isFinitePointArray(values: number[]): boolean {
    for (let i = 0; i < values.length; i++) {
      if (!Number.isFinite(values[i])) {
        return false;
      }
    }
    return true;
  }

  private static readLayers(list: HCLayerRaw[] | undefined): HCLayer[] {
    const result: HCLayer[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCLayerRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      result.push({
        id: pickString(item.id, ''),
        name: pickString(item.name, '图层'),
        type: pickString(item.type, 'draw'),
        opacity: NoteSerializer.quantizeClamped(pickNumber(item.opacity, 1), 0, 1),
        visible: pickBoolean(item.visible, true),
        locked: pickBoolean(item.locked, false),
        groupId: pickString(item.groupId, ''),
        paperTemplate: pickString(item.paperTemplate, ''),
        pageRef: pickString(item.pageRef, ''),
        order: pickNumber(item.order, i),
      });
    }
    return result;
  }

  private static readImages(list: HCImageRaw[] | undefined): HCImage[] {
    const result: HCImage[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCImageRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      result.push({
        id: pickString(item.id, `img_${i}`),
        layerId: pickString(item.layerId, ''),
        imageHash: pickString(item.imageHash, ''),
        mimeType: pickString(item.mimeType, 'image/png'),
        x: NoteSerializer.quantize(pickNumber(item.x, 0)),
        y: NoteSerializer.quantize(pickNumber(item.y, 0)),
        width: NoteSerializer.quantize(pickNumber(item.width, 0)),
        height: NoteSerializer.quantize(pickNumber(item.height, 0)),
        uri: pickString(item.uri, ''),
        binaryRef: '',
        rotation: NoteSerializer.quantize(pickNumber(item.rotation, 0)),
        scale: NoteSerializer.quantizeClamped(pickNumber(item.scale, 1), 0.01, 100),
        createdBy: pickString(item.createdBy, HC_LOCAL_AUTHOR),
        createdAt: pickNumber(item.createdAt, 0),
      });
    }
    return result;
  }

  /** 宽松 Raw → 文档列表（缺字段兜底，向下兼容 v1） */
  private static readDocs(list: HCDocRaw[] | undefined): HCDoc[] {
    const result: HCDoc[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCDocRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const refs: string[] = item.pageRefs !== undefined && item.pageRefs !== null ? item.pageRefs.slice() : [];
      result.push({
        docId: pickString(item.docId, ''),
        fileName: pickString(item.fileName, ''),
        format: pickString(item.format, 'pdf'),
        pageCount: Math.max(0, pickNumber(item.pageCount, 0)),
        pageRefs: refs,
        importedAt: pickNumber(item.importedAt, 0),
        sourcePath: pickString(item.sourcePath, ''),
      });
    }
    return result;
  }

  /** 宽松 Raw → 批注列表（缺字段兜底，坐标量化，向下兼容 v1） */
  private static readAnnotations(list: HCAnnotationRaw[] | undefined): HCAnnotation[] {
    const result: HCAnnotation[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCAnnotationRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const flatRaw: number[] = pickNumberArray(item.points);
      const flat: number[] = [];
      const pairCount: number = Math.floor(flatRaw.length / 2);
      for (let k = 0; k < pairCount; k++) {
        flat.push(NoteSerializer.quantize(flatRaw[k * 2]));
        flat.push(NoteSerializer.quantize(flatRaw[k * 2 + 1]));
      }
      result.push({
        id: pickString(item.id, `a_${i}`),
        docId: pickString(item.docId, ''),
        pageIndex: Math.max(0, pickNumber(item.pageIndex, 0)),
        layerId: pickString(item.layerId, ''),
        tool: pickString(item.tool, 'pen'),
        color: pickString(item.color, '#000000'),
        width: NoteSerializer.quantizeClamped(pickNumber(item.width, 3), 0.1, 200),
        opacity: NoteSerializer.quantizeClamped(pickNumber(item.opacity, 1), 0, 1),
        points: flat,
        createdAt: pickNumber(item.createdAt, 0),
        createdBy: pickString(item.createdBy, HC_LOCAL_AUTHOR),
      });
    }
    return result;
  }

  /** 落盘文本框列表 → 内存文本框列表（S2-B / T2-3；缺省空数组，旧文件零影响） */
  private static readTexts(list: HCTextRaw[] | undefined): HCText[] {
    const result: HCText[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCTextRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      result.push({
        id: pickString(item.id, `text_${i}`),
        layerId: pickString(item.layerId, ''),
        text: pickString(item.text, ''),
        x: NoteSerializer.quantize(pickNumber(item.x, 0)),
        y: NoteSerializer.quantize(pickNumber(item.y, 0)),
        fontSize: NoteSerializer.quantizeClamped(pickNumber(item.fontSize, 20), 8, 120),
        fontFamily: pickString(item.fontFamily, 'HarmonyOS Sans'),
        align: pickString(item.align, 'left'),
        color: pickString(item.color, '#000000'),
        createdBy: pickString(item.createdBy, HC_LOCAL_AUTHOR),
        createdAt: pickNumber(item.createdAt, 0),
      });
    }
    return result;
  }

  /** 落盘闪卡列表 → 内存闪卡列表（S2-B / T2-4；缺省空数组） */
  private static readFlashcards(list: HCFlashcardRaw[] | undefined): HCFlashcard[] {
    const result: HCFlashcard[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCFlashcardRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      result.push({
        id: pickString(item.id, `card_${i}`),
        question: pickString(item.question, ''),
        answer: pickString(item.answer, ''),
        box: Math.max(0, Math.min(5, Math.round(pickNumber(item.box, 0)))),
        ease: NoteSerializer.quantizeClamped(pickNumber(item.ease, 2.5), 1.3, 2.5),
        interval: Math.max(0, Math.round(pickNumber(item.interval, 0))),
        dueAt: Math.max(0, Math.round(pickNumber(item.dueAt, 0))),
        reps: Math.max(0, Math.round(pickNumber(item.reps, 0))),
        lapses: Math.max(0, Math.round(pickNumber(item.lapses, 0))),
        createdAt: Math.max(0, Math.round(pickNumber(item.createdAt, 0))),
      });
    }
    return result;
  }

  /** 落盘导图列表 → 内存导图列表（S2-B / T2-4；缺省空数组） */
  private static readMindMaps(list: HCMindMapRaw[] | undefined): HCMindMap[] {
    const result: HCMindMap[] = [];
    if (list === undefined || list === null) {
      return result;
    }
    for (let i = 0; i < list.length; i++) {
      const item: HCMindMapRaw = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const nodes: HCMindNode[] = [];
      const rawNodes: HCMindNodeRaw[] | undefined = item.nodes;
      if (rawNodes !== undefined && rawNodes !== null) {
        for (let k = 0; k < rawNodes.length; k++) {
          const n: HCMindNodeRaw = rawNodes[k];
          if (n === undefined || n === null) {
            continue;
          }
          nodes.push({
            id: pickString(n.id, `n_${k}`),
            label: pickString(n.label, ''),
            x: NoteSerializer.quantize(pickNumber(n.x, 0)),
            y: NoteSerializer.quantize(pickNumber(n.y, 0)),
            parentId: pickString(n.parentId, ''),
          });
        }
      }
      const edges: HCMindEdge[] = [];
      const rawEdges: HCMindEdgeRaw[] | undefined = item.edges;
      if (rawEdges !== undefined && rawEdges !== null) {
        for (let k = 0; k < rawEdges.length; k++) {
          const e: HCMindEdgeRaw = rawEdges[k];
          if (e === undefined || e === null) {
            continue;
          }
          edges.push({
            id: pickString(e.id, `e_${k}`),
            from: pickString(e.from, ''),
            to: pickString(e.to, ''),
          });
        }
      }
      result.push({
        id: pickString(item.id, `map_${i}`),
        title: pickString(item.title, '思维导图'),
        rootLabel: pickString(item.rootLabel, '中心主题'),
        nodes: nodes,
        edges: edges,
        createdAt: Math.max(0, Math.round(pickNumber(item.createdAt, 0))),
      });
    }
    return result;
  }

  private static buildFailure(id: string, message: string): NoteDeserializeResult {
    const empty: NoteContent = {
      meta: createNoteMeta(id, '未命名笔记', HC_DEFAULT_PAPER),
      paper: { template: HC_DEFAULT_PAPER, layerId: '', backgroundColor: HC_DEFAULT_BACKGROUND },
      viewport: { x: 0, y: 0, scale: 1 },
      layers: [],
      strokes: [],
      images: [],
      docs: [],
      annotations: [],
      texts: [],
      flashcards: [],
      mindmaps: [],
      nodes: [],
      links: [],
      bookmarks: [],
      canvasWidth: 0,
      canvasHeight: 0,
      forwardRaw: '',
    };
    return {
      ok: false,
      content: empty,
      checksumMatched: false,
      fileSchemaVersion: 0,
      migrated: false,
      errorMessage: message,
      loadWarning: '',
    };
  }

  // ═══════════════════════════════════════════════════════════════
  // 八、版本迁移桩
  // ═══════════════════════════════════════════════════════════════

  /**
   * schema 版本迁移。
   * 当前（v1）为直通实现；未来新增版本时在此按 `fromVersion` 逐级向上补分支，
   * 每一级只做**字段级增补 / 改名映射**，不得丢弃未知字段（前向兼容桶另行保留全文）。
   *
   * 低于 1 的版本（早期脏文件）按 v1 语义尽力解释。
   * 高于当前版本的文件不降级，直接按 v1 已知字段读取，未知字段交由 forwardRaw 保留。
   */
  static migrate(raw: HCNoteFileRaw, fromVersion: number): HCNoteFileRaw {
    if (fromVersion === HC_NOTE_SCHEMA_VERSION) {
      return raw;
    }
    if (fromVersion < HC_NOTE_SCHEMA_VERSION) {
      Logger.info(TAG_MODULE, `迁移低版本文件 v${fromVersion} → v${HC_NOTE_SCHEMA_VERSION}（字段兜底模式）`);
      return raw;
    }
    Logger.warn(TAG_MODULE, `文件版本 v${fromVersion} 高于当前实现 v${HC_NOTE_SCHEMA_VERSION}，按已知字段读取并保留原文`);
    return raw;
  }

  // ═══════════════════════════════════════════════════════════════
  // 九、便捷组装
  // ═══════════════════════════════════════════════════════════════

  /**
   * 从页面内存态直接组装 NoteContent（WhiteboardPage 保存路径的唯一入口）。
   * 注意：会对 records 做量化回写。
   */
  static composeContent(
    meta: NoteMeta,
    paperTemplate: string,
    paperLayerId: string,
    layers: Layer[],
    records: StrokeRecord[],
    images: ImageRefData[],
    canvasWidth: number,
    canvasHeight: number,
    forwardRaw: string
  ): NoteContent {
    const template: string = NoteSerializer.normalizePaperTemplate(paperTemplate);
    meta.paperTemplate = template;
    // C-4：笔画兜底层必须是「绘制层」而非底纸层。
    // 否则一旦某笔 layerId 为空就会被挂到底纸层上，用户在图层面板隐藏底纸时笔迹会一起消失。
    const fallbackLayerId: string = NoteSerializer.pickDrawLayerId(layers, paperLayerId);
    return {
      meta: meta,
      paper: {
        template: template,
        layerId: paperLayerId,
        backgroundColor: HC_DEFAULT_BACKGROUND,
      },
      viewport: { x: 0, y: 0, scale: 1 },
      layers: NoteSerializer.projectLayers(layers),
      strokes: NoteSerializer.strokeRecordsToHC(records, fallbackLayerId),
      images: NoteSerializer.imageRefsToHC(images),
      // T2-1：docs / annotations 由各页面（AnnotationPage）在 compose 之后单独填充
      docs: [],
      annotations: [],
      // S2-B / T2-3/T2-4：texts / flashcards / mindmaps 由各页面（WhiteboardPage）在 compose 之后填充
      texts: [],
      flashcards: [],
      mindmaps: [],
      // NOTE-01：nodes 由各页面（WhiteboardPage）在 compose 之后填充
      nodes: [],
      links: [],
      bookmarks: [],
      canvasWidth: NoteSerializer.roundSize(canvasWidth),
      canvasHeight: NoteSerializer.roundSize(canvasHeight),
      forwardRaw: forwardRaw,
    };
  }

  /**
   * 选取笔画兜底图层：第一个非底纸层。
   * 全部图层都是底纸（异常结构）时才退回 paperLayerId，保证返回值恒非空。
   */
  static pickDrawLayerId(layers: Layer[], paperLayerId: string): string {
    for (let i = 0; i < layers.length; i++) {
      const layer: Layer = layers[i];
      if (layer.type !== 'paper' && layer.id !== paperLayerId) {
        return layer.id;
      }
    }
    return paperLayerId;
  }

  // ═══════════════════════════════════════════════════════════════
  // 十、CRDT 双文件三态持久化（S2-Cb / T2-5，t25 §3）
  //
  // ⚠️ 红线：.hcnote 主链路（serialize/deserialize/buildFile/rawToContent）零改动；
  //    本段为**纯新增方法**——写/读 `{noteId}.crdt.json` 快照 + `{noteId}.oplog.jsonl` 增量。
  //    序列化在此（NoteSerializer），实际文件 I/O 由 S2-Cc NoteRepository 新增方法承接。
  // ═══════════════════════════════════════════════════════════════

  /** CRDT 快照触发阈值（t25 §3.1，任一先达即打；放本模块供 S2-Cc 判断） */
  static readonly CRDT_SNAPSHOT_OP_THRESHOLD: number = 500;
  static readonly CRDT_SNAPSHOT_TIME_MS: number = 30 * 60 * 1000;
  static readonly CRDT_SNAPSHOT_BYTES: number = 256 * 1024;
  static readonly EXT_CRDT: string = '.crdt.json';
  static readonly EXT_OPLOG: string = '.oplog.jsonl';

  /**
   * RGASnapshot → `.crdt.json` 文本。
   * snapshot 已是序列化友好结构（elements 数组 + clock 对象 + elementLWW 扁平数组），
   * 直接 JSON.stringify；不校验、不抛异常。
   */
  static serializeCrdtSnapshot(snapshot: RGASnapshot<CanvasElement>): string {
    return JSON.stringify(snapshot);
  }

  /**
   * `.crdt.json` 文本 → RGASnapshot（宽松解析，缺省空）。
   * 解析失败/结构非法返回 null（调用方降级为 .hcnote 投影 + oplog 重放）。
   */
  static deserializeCrdtSnapshot(text: string): RGASnapshot<CanvasElement> | null {
    if (text === undefined || text === null || text.length === 0) {
      return null;
    }
    let parsed: RGASnapshot<CanvasElement> | null = null;
    try {
      parsed = JSON.parse(text) as RGASnapshot<CanvasElement>;
    } catch (error) {
      Logger.warn(TAG_MODULE, `crdt.json 解析失败: ${(error as Error).message}`);
      return null;
    }
    if (parsed === undefined || parsed === null || !Array.isArray(parsed.elements)) {
      return null;
    }
    if (parsed.elementLWW === undefined || parsed.elementLWW === null) {
      parsed.elementLWW = [];
    }
    return parsed;
  }

  /** 单条 CRDT op → oplog JSONL 行（append-only；含换行符） */
  static serializeOpLogLine(op: CRDTOp<CanvasElement>): string {
    return JSON.stringify(op) + '\n';
  }

  /** oplog JSONL 行 → CRDT op（宽松解析；坏行返回 null，调用方跳过不阻断） */
  static parseOpLogLine(line: string): CRDTOp<CanvasElement> | null {
    const trimmed: string = line !== undefined ? line.replace(/\r?\n$/, '') : '';
    if (trimmed.length === 0) {
      return null;
    }
    let parsed: CRDTOp<CanvasElement> | null = null;
    try {
      parsed = JSON.parse(trimmed) as CRDTOp<CanvasElement>;
    } catch (error) {
      Logger.warn(TAG_MODULE, `oplog 行解析失败: ${(error as Error).message}`);
      return null;
    }
    if (parsed === undefined || parsed === null || typeof parsed.type !== 'string') {
      return null;
    }
    return parsed;
  }
}
