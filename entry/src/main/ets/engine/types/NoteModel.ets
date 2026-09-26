/**
 * NoteModel.ets — `.hcnote` 数据模型与常量（v2.4 阶段一，T1-1）
 *
 * 本文件是 `.hcnote` schema v1 的**类型正本**，与 architecture-harmonycanvas-notes.md §2 一一对应。
 *
 * 冻结约定（S-1）：
 *  1. 顶层必须携带 magic="HCNT" + schemaVersion(整数) + encoding；
 *  2. **只允许追加字段，禁止改名 / 改语义 / 删除**；
 *  3. 任何字段变更必须递增 HC_NOTE_SCHEMA_VERSION 并在 NoteSerializer.migrate 中补迁移分支。
 *
 * 设计要点：
 *  - 全部字段为**必填**（不使用可选属性），缺失值在反序列化阶段统一补默认值。
 *    原因：JSON.stringify 会丢弃 undefined 字段，可选属性会破坏 save→load→save 的字节级幂等（A1-7）。
 *  - 笔画字段与 engine/StrokeEngine.ets 的 StrokeData **同名同义**，阶段二升级 CRDT 时零成本对齐。
 *  - 本模块**不 import 任何其他模块**，避免循环依赖（common/Constants.ets 反向引用本文件）。
 */

// 唯一例外：类型级 import（编译期擦除，无运行时依赖、不会形成循环）。
// 便签节点复用 BoardModel.CanvasNode，避免双份数据模型（NOTE-01 持久化接入）。
import type { CanvasNode, LinkData, BookmarkData } from './BoardModel';

// ═══════════════════════════════════════════════════════════════════
// 一、格式常量（schema v1 冻结值）
// ═══════════════════════════════════════════════════════════════════

/** 文件魔数，读取时首先校验，不匹配直接判定非法文件 */
export const HC_NOTE_MAGIC: string = 'HCNT';

/** 当前 schema 版本。阶段一=1；阶段二=2；阶段三=3 */
export const HC_NOTE_SCHEMA_VERSION: number = 2;

/** 编码方式。预留 'json-deflate' / 'binary-tlv' 切换位（U-1 主理人已拍板阶段一用 json） */
export const HC_NOTE_ENCODING_JSON: string = 'json';

/** 点序列格式。'xy'=扁平 [x0,y0,x1,y1,…]（阶段一）；'xytp'=四元组（阶段二压感） */
export const HC_POINT_FORMAT_XY: string = 'xy';

/** 写入方应用标识（仅排障用，不参与兼容判定） */
export const HC_APP_ID: string = 'harmonycanvas';

/** 写入方应用版本（仅排障用） */
export const HC_APP_VERSION: string = '2.4';

/** 默认底纸模板 */
export const HC_DEFAULT_PAPER: string = 'blank';

/** 默认背景色（白底由 PaperLayerRenderer.renderBlank 实际绘制，C-2） */
export const HC_DEFAULT_BACKGROUND: string = '#FFFFFF';

/** 默认作者标识（单机） */
export const HC_LOCAL_AUTHOR: string = 'local';

/** checksum 算法前缀 */
export const HC_CHECKSUM_PREFIX: string = 'fnv1a:';

/** 缩略图格式 */
export const HC_THUMB_FORMAT: string = 'png';

// ═══════════════════════════════════════════════════════════════════
// 二、核心数据结构
// ═══════════════════════════════════════════════════════════════════

/**
 * 笔记元信息（索引层 NoteMeta 与 `.hcnote` meta 段的公共正本）。
 * 阶段一全部字段必填；`favorite` / `tags` 为阶段二收藏与标签预留（U-7）。
 */
export interface NoteMeta {
  /** `note_{createdAt13位}_{6位小写字母数字}`，同时是文件名（S-7） */
  id: string;
  /** 标题，1-60 字符，去首尾空白 */
  title: string;
  createdAt: number;
  updatedAt: number;
  /** blank | grid | dot | lined | four_line */
  paperTemplate: string;
  /** 冗余字段，供列表展示与 A1-1 快速校验 */
  strokeCount: number;
  /** 收藏（NotePage「收藏」Tab，阶段一恒 false 且 Tab 置灰，U-7） */
  favorite: boolean;
  /** 标签，v1 恒空数组 */
  tags: string[];
  /** 缩略图相对路径，形如 `thumbs/{id}.txt` */
  thumbRef: string;
  /** 写入该笔记时的 schema 版本 */
  schemaVersion: number;
  /** 最近一次序列化文本字节数（近似，供排障与容量预警） */
  sizeBytes: number;
  /** 保存时的画布逻辑宽（vp），恢复时判断是否需坐标归一 */
  canvasWidth: number;
  /** 保存时的画布逻辑高（vp） */
  canvasHeight: number;
}

/** 底纸段（§2.3）。非法 template 一律降级 'blank' 并记 warn，不抛异常 */
export interface NotePaper {
  template: string;
  /** 纸图层在 LayerManager 中的 id */
  layerId: string;
  backgroundColor: string;
}

/** 视口段（§2.1） */
export interface NoteViewport {
  x: number;
  y: number;
  scale: number;
}

/**
 * 图层的可序列化投影（§2.4）。
 * ⚠️ 必须剔除 Layer.offscreenCanvas（OffscreenCanvas 不可 JSON 序列化，S-3）。
 */
export interface HCLayer {
  id: string;
  name: string;
  /** draw | paper | page | group */
  type: string;
  opacity: number;
  visible: boolean;
  locked: boolean;
  groupId: string;
  paperTemplate: string;
  pageRef: string;
  order: number;
}

/**
 * 笔画 DTO（§2.5），字段与 StrokeData 同名同义。
 * points 为扁平数组，长度必为偶数（pointFormat='xy'）。
 * pressure 为与 points 1:1 的压感平行数组（S2-A / T2-2：第 i 个元素 = 第 i 个点压力，2 位量化；
 * 缺省=无压感旧文件，pointFormat 永为 'xy'，'xytp' 永不落地）。
 */
export interface HCStroke {
  id: string;
  layerId: string;
  /** pen|pencil|highlighter|marker|brush|laser|eraser|rectangle|circle|arrow|line */
  tool: string;
  color: string;
  width: number;
  opacity: number;
  /** normal | multiply */
  blendMode: string;
  /** round | flat | texture */
  brushShape: string;
  texture: string;
  points: number[];
  /** 压感平行数组（可选，S2-A）：points.length/2 个元素，2 位量化；无压感省略 */
  pressure?: number[];
  createdAt: number;
  createdBy: string;
}

/** 图片引用 DTO（§2.6）。阶段一只存 uri，binaryRef 恒空串（U-4） */
export interface HCImage {
  id: string;
  layerId: string;
  imageHash: string;
  mimeType: string;
  x: number;
  y: number;
  width: number;
  height: number;
  uri: string;
  binaryRef: string;
  rotation: number;
  scale: number;
  createdBy: string;
  createdAt: number;
}

/** 缩略图描述段（§2.1） */
export interface HCThumb {
  format: string;
  ref: string;
  /** 内联 dataURL，阶段一恒空串（缩略图独立落 thumbs/{id}.txt） */
  inline: string;
}

/**
 * `.hcnote` 文件顶层结构（§2.1）。
 * 字段声明顺序 == JSON 序列化顺序，是 A1-7「字节级幂等」的保证之一。
 */
export interface HCNoteFile {
  magic: string;
  schemaVersion: number;
  encoding: string;
  app: string;
  appVersion: string;
  pointFormat: string;
  meta: NoteMeta;
  paper: NotePaper;
  viewport: NoteViewport;
  layers: HCLayer[];
  strokes: HCStroke[];
  images: HCImage[];
  // ── 阶段二 / 三扩展空位：v2 起 docs / annotations 为具体 DTO，其余仍占位 ──
  shapes: HCStroke[];
  texts: HCText[];
  docs: HCDoc[];
  annotations: HCAnnotation[];
  flashcards: HCFlashcard[];
  mindmaps: HCMindMap[];
  aiIndex: HCReserved | null;
  thumb: HCThumb;
  checksum: string;
}

/**
 * 文本框 DTO（S2-B / T2-3，与 CanvasElement.TextBlockData 同构投影）。
 * S-1 纯追加字段：v1 文件 texts 缺省空数组，Reader 兜底为 []。
 */
export interface HCText {
  id: string;
  layerId: string;
  text: string;
  x: number;
  y: number;
  fontSize: number;
  fontFamily: string;
  align: string;
  color: string;
  createdBy: string;
  createdAt: number;
}

/** HCText 宽松读取变体（§2.7 安全取值） */
export interface HCTextRaw {
  id?: string;
  layerId?: string;
  text?: string;
  x?: number;
  y?: number;
  fontSize?: number;
  fontFamily?: string;
  align?: string;
  color?: string;
  createdBy?: string;
  createdAt?: number;
}

/**
 * 闪卡 DTO（S2-B / T2-4，SM-2 间隔重复状态随笔记持久化）。
 * box 0-5（0=新卡/学习中），ease 1.3-2.5，interval 天，dueAt 下次复习时间戳。
 */
export interface HCFlashcard {
  id: string;
  question: string;
  answer: string;
  box: number;
  ease: number;
  interval: number;
  dueAt: number;
  reps: number;
  lapses: number;
  createdAt: number;
}

/** HCFlashcard 宽松读取变体 */
export interface HCFlashcardRaw {
  id?: string;
  question?: string;
  answer?: string;
  box?: number;
  ease?: number;
  interval?: number;
  dueAt?: number;
  reps?: number;
  lapses?: number;
  createdAt?: number;
}

/** 导图节点 DTO（S2-B / T2-4） */
export interface HCMindNode {
  id: string;
  label: string;
  x: number;
  y: number;
  parentId: string;
}

/** 导图连线 DTO */
export interface HCMindEdge {
  id: string;
  from: string;
  to: string;
}

/** 思维导图 DTO（S2-B / T2-4，手绘/大纲→层级节点，随笔记持久化） */
export interface HCMindMap {
  id: string;
  title: string;
  rootLabel: string;
  nodes: HCMindNode[];
  edges: HCMindEdge[];
  createdAt: number;
}

/** HCMindNode 宽松读取变体 */
export interface HCMindNodeRaw {
  id?: string;
  label?: string;
  x?: number;
  y?: number;
  parentId?: string;
}

/** HCMindEdge 宽松读取变体 */
export interface HCMindEdgeRaw {
  id?: string;
  from?: string;
  to?: string;
}

/** HCMindMap 宽松读取变体 */
export interface HCMindMapRaw {
  id?: string;
  title?: string;
  rootLabel?: string;
  nodes?: HCMindNodeRaw[];
  edges?: HCMindEdgeRaw[];
  createdAt?: number;
}

/**
 * 扩展空位占位类型。
 * 阶段一恒不写入元素；阶段二把对应数组换成具体 DTO 类型即可（追加，不改名）。
 * texts / flashcards / mindmaps / aiIndex 仍用本占位，阶段三再换。
 */
export interface HCReserved {
  id: string;
}

/**
 * 导入文档 DTO（T2-1 阶段二「文档导入与批注页」）。
 * 仅持久化文档元信息；页位图不落盘（P0 为内存态白底位图，pdf.js 接入后再评估缓存策略）。
 * pageRefs 与 LayerManager 的 PageLayer.pageRef（'docId:pageIndex'）一一对应，用于加载时反查底图层。
 */
export interface HCDoc {
  /** 文档会话 id（DocumentImporter 生成，形如 doc_{ts}_{rand}） */
  docId: string;
  /** 原始文件名（展示用） */
  fileName: string;
  /** 'pdf' | 'epub' | 'caj'（导入成功只可能是 pdf，另两者已降级拦截） */
  format: string;
  /** 页面数（≤ PDF_FREE_PAGE_LIMIT=10） */
  pageCount: number;
  /** 每页 pageRef：'docId:pageIndex'，下标与页码对齐 */
  pageRefs: string[];
  /** 导入时间戳 */
  importedAt: number;
  /** F-04 任务 B+：源 PDF 在沙箱 filesDir/docs/{docId}/source.pdf 的持久化路径；
   *  用于批注写回另存（杀掉 App 重开后仍可导出）；空串表示未知
   *  （旧版 .hcnote 无此字段 / 重载且从未落盘，导出时优雅降级）。 */
  sourcePath: string;
}

/**
 * 批注笔画 DTO（T2-1）。
 * docId + pageIndex **强绑**，是「翻页批注不错位（A2-1）」的落盘保证：
 * 加载时按 pageIndex 把笔画路由回对应页的批注图层。
 */
export interface HCAnnotation {
  id: string;
  /** 所属文档 id */
  docId: string;
  /** 所属页码（0 基），强绑批注图层 */
  pageIndex: number;
  /** 该页批注图层 id（AnnotationPage 每页一图层） */
  layerId: string;
  /** pen | highlighter | marker | …（批注只取自由笔迹类） */
  tool: string;
  color: string;
  width: number;
  opacity: number;
  /** 扁平坐标 [x0,y0,x1,y1,…]，pointFormat='xy' */
  points: number[];
  createdAt: number;
  createdBy: string;
}

/** HCAnnotation 宽松读取变体（§2.7 安全取值） */
export interface HCAnnotationRaw {
  id?: string;
  docId?: string;
  pageIndex?: number;
  layerId?: string;
  tool?: string;
  color?: string;
  width?: number;
  opacity?: number;
  points?: number[];
  createdAt?: number;
  createdBy?: string;
}

/** HCDoc 宽松读取变体（§2.7 安全取值） */
export interface HCDocRaw {
  docId?: string;
  fileName?: string;
  format?: string;
  pageCount?: number;
  pageRefs?: string[];
  importedAt?: number;
  sourcePath?: string;
}

/**
 * 宽松读取结构：所有字段可选，用于 JSON.parse 后的安全取值。
 * 反序列化时逐字段兜底填默认值，避免脏文件导致整本笔记读不出来（S-5）。
 */
export interface HCNoteFileRaw {
  magic?: string;
  schemaVersion?: number;
  encoding?: string;
  app?: string;
  appVersion?: string;
  pointFormat?: string;
  meta?: NoteMetaRaw;
  paper?: NotePaperRaw;
  viewport?: NoteViewportRaw;
  layers?: HCLayerRaw[];
  strokes?: HCStrokeRaw[];
  images?: HCImageRaw[];
  thumb?: HCThumbRaw;
  // ── 阶段二扩展（T2-1/T2-3/T2-4）：v1 文件无此字段，读取时按缺省空数组兜底 ──
  docs?: HCDocRaw[];
  annotations?: HCAnnotationRaw[];
  texts?: HCTextRaw[];
  flashcards?: HCFlashcardRaw[];
  mindmaps?: HCMindMapRaw[];
  checksum?: string;
}

export interface NoteMetaRaw {
  id?: string;
  title?: string;
  createdAt?: number;
  updatedAt?: number;
  paperTemplate?: string;
  strokeCount?: number;
  favorite?: boolean;
  tags?: string[];
  thumbRef?: string;
  schemaVersion?: number;
  sizeBytes?: number;
  canvasWidth?: number;
  canvasHeight?: number;
}

export interface NotePaperRaw {
  template?: string;
  layerId?: string;
  backgroundColor?: string;
}

export interface NoteViewportRaw {
  x?: number;
  y?: number;
  scale?: number;
}

export interface HCLayerRaw {
  id?: string;
  name?: string;
  type?: string;
  opacity?: number;
  visible?: boolean;
  locked?: boolean;
  groupId?: string;
  paperTemplate?: string;
  pageRef?: string;
  order?: number;
}

export interface HCStrokeRaw {
  id?: string;
  layerId?: string;
  tool?: string;
  color?: string;
  width?: number;
  opacity?: number;
  blendMode?: string;
  brushShape?: string;
  texture?: string;
  points?: number[];
  /** 压感平行数组（可选，S2-A）：缺省=无压感旧文件 */
  pressure?: number[];
  createdAt?: number;
  createdBy?: string;
}

export interface HCImageRaw {
  id?: string;
  layerId?: string;
  imageHash?: string;
  mimeType?: string;
  x?: number;
  y?: number;
  width?: number;
  height?: number;
  uri?: string;
  binaryRef?: string;
  rotation?: number;
  scale?: number;
  createdBy?: string;
  createdAt?: number;
}

export interface HCThumbRaw {
  format?: string;
  ref?: string;
  inline?: string;
}

/**
 * 内存态笔记内容（页面层与仓储层之间传递的载体）。
 * 与 HCNoteFile 的区别：不含 magic / encoding 等文件头，另带前向兼容桶。
 */
export interface NoteContent {
  meta: NoteMeta;
  paper: NotePaper;
  viewport: NoteViewport;
  layers: HCLayer[];
  strokes: HCStroke[];
  images: HCImage[];
  /** T2-1 导入文档列表（顶层，与落盘 docs[] 同构） */
  docs: HCDoc[];
  /** T2-1 批注笔画列表（docId + pageIndex 强绑，翻页不错位） */
  annotations: HCAnnotation[];
  /** T2-3 文本框列表（与落盘 texts[] 同构，CanvasElement.TextBlockData 投影） */
  texts: HCText[];
  /** T2-4 闪卡列表（SM-2 状态随笔记持久化） */
  flashcards: HCFlashcard[];
  /** T2-4 思维导图列表 */
  mindmaps: HCMindMap[];
  /** NOTE-01：画布便签/便利贴节点（CanvasNode[]，复用 BoardModel，随笔记原子落盘） */
  nodes: CanvasNode[];
  /** NOTE-02：手写双链（独立 links[] 表，软删除无幽灵引用） */
  links: LinkData[];
  /** NOTE-03：书签三类（必背/易错/真题）锚点 */
  bookmarks: BookmarkData[];
  canvasWidth: number;
  canvasHeight: number;
  /**
   * 前向兼容桶（§2.8）：读到高于当前 schemaVersion 的文件时，
   * 在此原样保留完整原文，保存时把未知顶层字段回写，避免丢新版本数据。
   * 空串表示无前向数据。
   */
  forwardRaw: string;
}

/** 加载结果。loadNote 永不抛异常，恒返回本结构（S-5） */
export interface NoteLoadResult {
  ok: boolean;
  content: NoteContent;
  /** true 表示主文件损坏、内容来自 .bak */
  recoveredFromBak: boolean;
  /** true 表示主文件与备份均不可用、内容来自未提交草稿（L3 救回，T2-1b D-1） */
  recoveredFromTmp: boolean;
  /** true 表示主文件完好已采用，但磁盘存在「校验通过且比正文新」的未提交草稿（提示档，T2-1b 闸 B） */
  hasUncommittedTmp: boolean;
  /** 非阻断加载告警（T2-1b P1）：空串=无告警；如「已跳过 N 笔坐标异常笔画」「笔画数与元信息不一致」 */
  loadWarning: string;
  errorMessage: string;
}

/** 保存状态三态（U-2 文案约定） */
export enum NoteSaveState {
  IDLE = 'idle',
  SAVING = 'saving',
  SAVED = 'saved',
  FAILED = 'failed',
}

/**
 * 状态严重性（d1 §11.2 ①）：胶囊底色与内容严重性解耦的唯一依据。
 * 实现为 class 静态只读 string 常量（非 string enum）：ArkTS 严格模式下 string enum 成员
 * 不可赋给 string 变量/参数（TS2322），class 常量在类型层面就是 string，赋值/传参/比较均无坑。
 */
export class StatusSeverity {
  /** 中性常规：笔数、模式切换等例行提示 */
  static readonly ROUTINE: string = 'routine';
  /** 信息：进行中 / 已保存 */
  static readonly INFO: string = 'info';
  /** 告警：保存失败 / 导出失败等，stickyAlert 防被 routine 覆盖 */
  static readonly ALERT: string = 'alert';
}

/** 胶囊调色板（d1 §11.2 ①）：唯一决定状态胶囊配色，fg/bg 恒对比安全 */
export interface StatusPalette {
  background: string;
  foreground: string;
}

/**
 * 按严重性取胶囊配色（d1 §11.2 ①）。
 * 替换原 WhiteboardPage:664 / AnnotationPage:807 硬编码 '#4CAF50' 绿胶囊。
 */
export function statusPalette(severity: string): StatusPalette {
  if (severity === StatusSeverity.ALERT) {
    return { background: '#C0392B', foreground: '#FFFFFF' };
  }
  if (severity === StatusSeverity.INFO) {
    return { background: '#1F6FB2', foreground: '#FFFFFF' };
  }
  // ROUTINE：中性深灰（不再是绿色，绿色语义保留给 SAVED 的 chip 文字色）
  return { background: '#2B2F36', foreground: '#E6E8EB' };
}

/** 保存状态中文文案（U-2）。T2-1b C-2：FAILED 时按失败分类（failureKind）返回对应短文案 */
export function noteSaveStateText(state: string, failureKind?: string): string {
  if (state === NoteSaveState.SAVING) {
    return '保存中…';
  }
  if (state === NoteSaveState.SAVED) {
    return '✓ 已保存';
  }
  if (state === NoteSaveState.FAILED) {
    // d2 §1.2 文案矩阵：chip 短文案 ≤16 汉字，保留「重试」二字（S1NoteTest:468 断言依赖）
    if (failureKind === 'no_space') {
      return '空间不足，未保存 · 点击重试';
    }
    if (failureKind === 'no_permission') {
      return '无写入权限，未保存 · 点击重试';
    }
    // 未知分类（含未传 failureKind 的旧调用点）→ 默认通用文案，含「重试」
    return '保存失败，点击重试';
  }
  return '未保存';
}

/** 保存状态配色（U-2） */
export function noteSaveStateColor(state: string): string {
  if (state === NoteSaveState.SAVING) {
    return '#8A8F99';
  }
  if (state === NoteSaveState.SAVED) {
    return '#2E9E4F';
  }
  if (state === NoteSaveState.FAILED) {
    return '#C0392B';
  }
  return '#B6BBC2';
}

// ═══════════════════════════════════════════════════════════════════
// 三、页面层交互类型
// ═══════════════════════════════════════════════════════════════════

/** NotePage → WhiteboardPage 的路由参数契约（T1-4 / T1-5 并行的接口约定） */
export interface NoteRouteParams {
  noteId: string;
  title: string;
  paperTemplate: string;
  isNew: boolean;
}

/** 底纸选项（页面层类型，避免 pages/* 直接 import PaperLayerRenderer，F-1） */
export interface PaperOption {
  template: string;
  name: string;
}

/** 笔刷选项（页面层类型，避免 pages/* 直接 import BrushRegistry，F-1） */
export interface BrushOption {
  tool: string;
  name: string;
  brushShape: string;
  opacity: number;
  blendMode: string;
  minWidth: number;
  maxWidth: number;
}

/**
 * WhiteboardPage 内存笔画记录。
 * 原为页面私有类型，本次上提到模型层，供 NoteSerializer 做 StrokeRecord ↔ HCStroke 双向映射。
 * 偏差说明：架构 §3.4 W4 把 opacity/blendMode/brushShape/layerId 标为可选，
 * 此处改为**必填 + 构造期填默认值**，以规避 ArkTS 严格模式下满屏 undefined 判断，
 * 语义完全等价（默认 1.0 / 'normal' / 'round' / ''）。
 */
export interface StrokeRecord {
  id: number;
  tool: string;
  color: string;
  width: number;
  points: PointRecord[];
  opacity: number;
  blendMode: string;
  brushShape: string;
  layerId: string;
  createdAt: number;
}

/** 二维采样点（内存态，落盘时展平为 number[]） */
export interface PointRecord {
  x: number;
  y: number;
  /** 压感（0-1，可选，S2-A）：无压感设备/旧文件为 undefined */
  pressure?: number;
  /** 运行时时间戳（相对笔首 ms，可选，S2-A）：**不落盘**，渲染期由 TouchEvent 提供 */
  t?: number;
}

// ═══════════════════════════════════════════════════════════════════
// 四、工厂函数（统一默认值，避免各处散落字面量）
// ═══════════════════════════════════════════════════════════════════

/** 生成合法 noteId：note_{13位时间戳}_{6位小写字母数字}（S-7） */
export function createNoteId(): string {
  const ts: number = Date.now();
  const chars: string = 'abcdefghijklmnopqrstuvwxyz0123456789';
  let suffix: string = '';
  for (let i = 0; i < 6; i++) {
    const idx: number = Math.floor(Math.random() * chars.length);
    suffix += chars.charAt(idx);
  }
  return `note_${ts}_${suffix}`;
}

/** 标题规范化：去首尾空白 + 长度 clamp 到 [1,60] */
export function normalizeNoteTitle(title: string, fallback: string): string {
  const raw: string = title !== undefined && title !== null ? title.trim() : '';
  const base: string = raw.length > 0 ? raw : fallback;
  return base.length > 60 ? base.substring(0, 60) : base;
}

/** 新建笔记元信息 */
export function createNoteMeta(id: string, title: string, paperTemplate: string): NoteMeta {
  const now: number = Date.now();
  return {
    id: id,
    title: normalizeNoteTitle(title, '未命名笔记'),
    createdAt: now,
    updatedAt: now,
    paperTemplate: paperTemplate,
    strokeCount: 0,
    favorite: false,
    tags: [],
    thumbRef: `thumbs/${id}.txt`,
    schemaVersion: HC_NOTE_SCHEMA_VERSION,
    sizeBytes: 0,
    canvasWidth: 0,
    canvasHeight: 0,
  };
}

/** 元信息深拷贝（避免 @State 引用共享导致列表刷新异常） */
export function cloneNoteMeta(src: NoteMeta): NoteMeta {
  return {
    id: src.id,
    title: src.title,
    createdAt: src.createdAt,
    updatedAt: src.updatedAt,
    paperTemplate: src.paperTemplate,
    strokeCount: src.strokeCount,
    favorite: src.favorite,
    tags: src.tags.slice(),
    thumbRef: src.thumbRef,
    schemaVersion: src.schemaVersion,
    sizeBytes: src.sizeBytes,
    canvasWidth: src.canvasWidth,
    canvasHeight: src.canvasHeight,
  };
}

/** 默认底纸段 */
export function createNotePaper(template: string, layerId: string): NotePaper {
  return {
    template: template,
    layerId: layerId,
    backgroundColor: HC_DEFAULT_BACKGROUND,
  };
}

/** 默认视口段 */
export function createNoteViewport(): NoteViewport {
  return { x: 0, y: 0, scale: 1.0 };
}

/** 空加载结果（用于失败兜底，绝不返回 null，S-5） */
export function createEmptyNoteContent(id: string, title: string, paperTemplate: string): NoteContent {
  return {
    meta: createNoteMeta(id, title, paperTemplate),
    paper: createNotePaper(paperTemplate, ''),
    viewport: createNoteViewport(),
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
}

/** 时间戳 → 列表展示文案（今天 HH:mm / 昨天 HH:mm / MM-DD） */
export function formatNoteTime(ts: number): string {
  if (ts <= 0) {
    return '—';
  }
  const now: Date = new Date();
  const d: Date = new Date(ts);
  const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
  const sameDay: boolean = now.getFullYear() === d.getFullYear()
    && now.getMonth() === d.getMonth()
    && now.getDate() === d.getDate();
  if (sameDay) {
    return `今天 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  const yesterday: Date = new Date(now.getTime() - 86400000);
  const isYesterday: boolean = yesterday.getFullYear() === d.getFullYear()
    && yesterday.getMonth() === d.getMonth()
    && yesterday.getDate() === d.getDate();
  if (isYesterday) {
    return `昨天 ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}
