import { Logger } from '../common/Logger';
import { NodeID, RGAElement, InsertOp, DeleteOp, UpdateOp, ResurrectOp, CRDTOp, compareNodeIds, serializeNodeID, deserializeNodeID, VectorClock } from './types/CRDTOp';
import { VectorClockHelper } from './VectorClock';

const TAG_MODULE = 'RGAEngine';

/** LWW-Register 条目（图层级操作，架构 §8.1 约定 3；不产生 RGA Insert/Delete） */
interface LayerLWWEntry {
  value: string;
  ts: number;
}

/**
 * T2-5（S2-Cb）：元素级 LWW 条目（字段级合并，t25 Q1）。
 * 决胜键 = (lamportTs, siteId) 字典序（lamportTs 来自产生 op 的 vectorClock[siteId]，非墙钟）。
 */
export interface ElementLWWEntry {
  elementId: string;   // serializeNodeID(elementId)
  field: string;
  value: string;
  lamportTs: number;
  siteId: string;
}

/** RGA 快照（状态续传/流转用，替代内联对象类型，符合 arkts-no-obj-literals-as-types） */
export interface RGASnapshot<T> {
  elements: RGAElement<T>[];
  clock: VectorClock;
  /** T2-5：元素级 LWW 字段（扁平序列化友好，import 时转回 Map） */
  elementLWW: ElementLWWEntry[];
}

/** pending-buffer 条目（D-T25-1：afterId 未到的乱序插入 op） */
interface PendingInsert<T> {
  op: InsertOp<T>;
  resolved: boolean;
}

export class RGAEngine<T> {
  private elements: RGAElement<T>[] = [];
  private lamportClock: number = 0;
  private siteId: string;
  private vectorClock: VectorClock = {};
  private opLog: CRDTOp<T>[] = [];
  private processedOps: Set<string> = new Set();
  /** v2.0（S2T03）：元素归属图层 LWW-Register（layerId → field → {value, ts}） */
  private layerLWW: Map<string, Map<string, LayerLWWEntry>> = new Map();
  /** T2-5（S2-Cb）：元素级 LWW（elementId → field → {value, lamportTs, siteId}，镜像 layerLWW 结构） */
  private elementLWW: Map<string, Map<string, ElementLWWEntry>> = new Map();
  /** D-T25-1：乱序到达缓冲（afterId 未到的插入 op，父到达后按序落位） */
  private pendingInserts: PendingInsert<T>[] = [];

  constructor(siteId: string) {
    this.siteId = siteId;
  }

  // ─── 本地操作 ───

  /**
   * 本地插入。elementType 为 v2.0 增量（stroke/shape/text_block/annotation/image_ref/mind_map），
   * 随 InsertOp 下发，供 getElementTypeOfOp 与权限校验使用（架构 §8.1 约定 2）。
   */
  localInsert(value: T, afterId: NodeID | null = null, elementType?: string): InsertOp<T> {
    this.lamportClock++;
    const nodeId: NodeID = { lamportTs: this.lamportClock, siteId: this.siteId };
    this.vectorClock = VectorClockHelper.increment(this.vectorClock, this.siteId);

    const op: InsertOp<T> = {
      type: 'insert',
      element: { id: nodeId, value: value, deleted: false, afterId: afterId },
      afterId: afterId,
      vectorClock: VectorClockHelper.clone(this.vectorClock),
      timestamp: Date.now(),
      elementType: elementType !== undefined ? elementType : ''
    };

    this.applyInsert(op);
    this.opLog.push(op);
    return op;
  }

  /**
   * 本地删除。elementType 为 v2.0 修复（E-3）：随 DeleteOp 下发，
   * 服务端按真实元素类型校验权限（Annotator 删除自己批注不被回退 stroke 拒绝）。
   */
  localDelete(targetId: NodeID, elementType?: string): DeleteOp | null {
    const element = this.elements.find(e => serializeNodeID(e.id) === serializeNodeID(targetId));
    if (!element || element.deleted) return null;

    this.vectorClock = VectorClockHelper.increment(this.vectorClock, this.siteId);

    const op: DeleteOp = {
      type: 'delete',
      targetId: targetId,
      vectorClock: VectorClockHelper.clone(this.vectorClock),
      timestamp: Date.now(),
      elementType: elementType !== undefined ? elementType : ''
    };

    element.deleted = true;
    this.opLog.push(op);
    return op;
  }

  // ─── 远程操作应用 ───

  applyRemoteOp(op: CRDTOp<T>): boolean {
    const opKey = this.getOpKey(op);
    if (this.processedOps.has(opKey)) {
      return false; // 幂等
    }

    this.processedOps.add(opKey);
    this.vectorClock = VectorClockHelper.merge(this.vectorClock, op.vectorClock);
    this.lamportClock = Math.max(this.lamportClock, ...Object.values(op.vectorClock));

    if (op.type === 'insert') {
      // ArkTS 不自动收窄联合类型（CRDTOp<T>），显式断言为 InsertOp<T>
      const insertOp: InsertOp<T> = op as InsertOp<T>;
      this.applyInsert(insertOp);
    } else if (op.type === 'delete') {
      const deleteOp: DeleteOp = op as DeleteOp;
      this.applyDelete(deleteOp);
    } else if (op.type === 'update') {
      const updateOp: UpdateOp = op as UpdateOp;
      this.applyElementUpdate(updateOp);
    } else if (op.type === 'resurrect') {
      const resurrectOp: ResurrectOp = op as ResurrectOp;
      this.applyResurrect(resurrectOp);
    }

    return true;
  }

  // ─── CRDT 核心：插入位置定位 ───

  private findInsertPosition(afterId: NodeID | null): number {
    if (afterId === null) {
      // 插入到最前面
      return 0;
    }

    // 查找 afterId 在列表中的索引
    const afterIndex = this.findElementIndex(afterId);
    if (afterIndex === -1) {
      // D-T25-1：afterId 缺失不再 append——调用方（applyInsert）已保证先入 pending-buffer；
      // 此处仅防御性兜底（不应到达），返回末尾并告警。
      Logger.warn(TAG_MODULE, `findInsertPosition: afterId still missing (pending-buffer bypass): ${serializeNodeID(afterId)}`);
      return this.elements.length;
    }

    return afterIndex + 1;
  }

  /**
   * CRITICAL: 冲突解决规则 — 并发Insert同一位置
   * 按 (lamportTs, siteId) 字典序排序，先到达的排在前面
   */
  private findElementIndex(targetId: NodeID): number {
    const targetStr = serializeNodeID(targetId);
    return this.elements.findIndex(e => serializeNodeID(e.id) === targetStr);
  }

  private applyInsert(op: InsertOp<T>): void {
    const element = op.element;
    const afterId = op.afterId;

    // CRITICAL: 如果元素已存在（并发冲突），按RGA规则排序
    const existingIndex = this.findElementIndex(element.id);
    if (existingIndex !== -1) {
      return; // 已存在，幂等忽略
    }

    // D-T25-1：afterId 缺失（乱序到达）→ 入 pending-buffer，父节点到达后按序落位（不 append）
    if (afterId !== null && this.findElementIndex(afterId) === -1) {
      Logger.warn(TAG_MODULE, `afterId not ready, buffered: ${serializeNodeID(afterId)}`);
      this.pendingInserts.push({ op: op, resolved: false });
      return;
    }

    this.insertElement(op);
    // 父节点已到达 → 尝试落位缓冲中的乱序 op（可能连锁解锁）
    this.flushPendingInserts();
  }

  /** 插入单个元素（前置条件：afterId 必已存在或为 null；含并发排序） */
  private insertElement(op: InsertOp<T>): void {
    const element = op.element;
    const afterId = op.afterId;
    let insertIndex = this.findInsertPosition(afterId);

    // CRITICAL: 处理并发Insert — 同一父节点后的多个元素
    // 确保按 (lamportTs, siteId) 字典序排列。
    // v2.0 修复（E-4）：父节点同为 null（并发头部插入）也必须参与排序，
    // 否则两端头部顺序不一致（[c2,c1] vs [c1,c2]），违反 CRDT 最终一致性。
    while (insertIndex < this.elements.length) {
      const nextElement = this.elements[insertIndex];
      const sameParent: boolean =
        (nextElement.afterId === null && afterId === null) ||
        (nextElement.afterId !== null && afterId !== null &&
          serializeNodeID(nextElement.afterId) === serializeNodeID(afterId));
      if (sameParent) {
        if (compareNodeIds(element.id, nextElement.id) < 0) {
          break; // 当前元素应该排在前面
        }
      } else {
        break;
      }
      insertIndex++;
    }

    const newElement: RGAElement<T> = {
      id: element.id,
      value: element.value,
      deleted: false,
      afterId: afterId
    };
    this.elements.splice(insertIndex, 0, newElement);
  }

  /** D-T25-1：缓冲中的乱序 op，父节点到达后按序落位（循环直到无进展） */
  private flushPendingInserts(): void {
    let progressed: boolean = true;
    while (progressed) {
      progressed = false;
      for (let i = 0; i < this.pendingInserts.length; i++) {
        const item: PendingInsert<T> = this.pendingInserts[i];
        if (item.resolved) {
          continue;
        }
        const op: InsertOp<T> = item.op;
        if (op.afterId === null || this.findElementIndex(op.afterId) !== -1) {
          if (this.findElementIndex(op.element.id) === -1) {
            this.insertElement(op);
          }
          item.resolved = true;
          progressed = true;
        }
      }
    }
  }

  private applyDelete(op: DeleteOp): void {
    const element = this.elements.find(e => serializeNodeID(e.id) === serializeNodeID(op.targetId));
    if (element) {
      element.deleted = true;
    }
  }

  // ─── T2-5（S2-Cb）：元素级 LWW 字段操作 ───

  /**
   * 本地字段更新：lamport 递增 → UpdateOp → 应用（LWW 决胜 (lamportTs, siteId)）。
   * @param field 可变字段名
   * @param value 字段新值（字符串化）
   */
  localUpdate(targetId: NodeID, field: string, value: string, elementType?: string): UpdateOp | null {
    const element = this.elements.find(e => serializeNodeID(e.id) === serializeNodeID(targetId));
    if (element === undefined) {
      return null;
    }
    this.lamportClock++;
    this.vectorClock = VectorClockHelper.increment(this.vectorClock, this.siteId);
    const op: UpdateOp = {
      type: 'update',
      targetId: targetId,
      field: field,
      value: value,
      vectorClock: VectorClockHelper.clone(this.vectorClock),
      timestamp: Date.now(),
      elementType: elementType !== undefined ? elementType : '',
      siteId: this.siteId,
    };
    this.applyElementUpdate(op);
    this.opLog.push(op);
    return op;
  }

  /** 本地撤销删除：清墓碑（ResurrectOp） */
  localResurrect(targetId: NodeID, elementType?: string): ResurrectOp | null {
    const element = this.elements.find(e => serializeNodeID(e.id) === serializeNodeID(targetId));
    if (element === undefined || !element.deleted) {
      return null;
    }
    this.lamportClock++;
    this.vectorClock = VectorClockHelper.increment(this.vectorClock, this.siteId);
    const op: ResurrectOp = {
      type: 'resurrect',
      targetId: targetId,
      vectorClock: VectorClockHelper.clone(this.vectorClock),
      timestamp: Date.now(),
      elementType: elementType !== undefined ? elementType : '',
    };
    this.applyResurrect(op);
    this.opLog.push(op);
    return op;
  }

  /** 应用字段更新：按 (lamportTs=vectorClock[siteId], siteId) 字典序 LWW 决胜（非墙钟） */
  applyElementUpdate(op: UpdateOp): void {
    const key: string = serializeNodeID(op.targetId);
    const lamportTs: number = op.vectorClock[op.siteId] !== undefined ? op.vectorClock[op.siteId] : 0;
    let fields: Map<string, ElementLWWEntry> | undefined = this.elementLWW.get(key);
    if (fields === undefined) {
      fields = new Map<string, ElementLWWEntry>();
      this.elementLWW.set(key, fields);
    }
    const existing: ElementLWWEntry | undefined = fields.get(op.field);
    if (existing !== undefined) {
      // 决胜：lamportTs 大者胜；相等比 siteId 字典序
      if (existing.lamportTs > lamportTs) {
        return; // 旧写已更高，忽略
      }
      if (existing.lamportTs === lamportTs && existing.siteId > op.siteId) {
        return;
      }
    }
    fields.set(op.field, { elementId: key, field: op.field, value: op.value, lamportTs: lamportTs, siteId: op.siteId });
  }

  /** 应用撤销删除：清墓碑（墓碑只是可见性开关，LWW 字段不因墓碑丢弃，t25 §1.5 示例 3） */
  applyResurrect(op: ResurrectOp): void {
    const element = this.elements.find(e => serializeNodeID(e.id) === serializeNodeID(op.targetId));
    if (element) {
      element.deleted = false;
    }
  }

  /** 读取元素字段的 LWW 覆盖值（无覆盖返回 null；调用方 fallback 元素自身值） */
  getElementField(targetId: NodeID, field: string): string | null {
    const key: string = serializeNodeID(targetId);
    const fields: Map<string, ElementLWWEntry> | undefined = this.elementLWW.get(key);
    if (fields === undefined) {
      return null;
    }
    const entry: ElementLWWEntry | undefined = fields.get(field);
    return entry !== undefined ? entry.value : null;
  }

  // ─── 图层级 LWW-Register（v2.0 S2T03，架构 §8.1 约定 3）───

  /**
   * 图层级操作走 LWW-Register：合并/重排/分组/透明度等字段以时间戳后写获胜收敛，
   * 不产生 RGA Insert/Delete。value 为字段新值（字符串化）。
   */
  applyLayerLWW(layerId: string, field: string, value: string): void {
    const now: number = Date.now();
    let fields: Map<string, LayerLWWEntry> | undefined = this.layerLWW.get(layerId);
    if (fields === undefined) {
      fields = new Map<string, LayerLWWEntry>();
      this.layerLWW.set(layerId, fields);
    }
    const existing: LayerLWWEntry | undefined = fields.get(field);
    if (existing !== undefined && existing.ts > now) {
      // 后写获胜（LWW）：仅当已有写入时间戳严格更新时才忽略本次（同毫秒按到达顺序覆盖）
      Logger.debug(TAG_MODULE, `applyLayerLWW: stale write ignored layer=${layerId} field=${field}`);
      return;
    }
    const entry: LayerLWWEntry = { value: value, ts: now };
    fields.set(field, entry);
  }

  getLayerLWWValue(layerId: string, field: string): string {
    const fields: Map<string, LayerLWWEntry> | undefined = this.layerLWW.get(layerId);
    if (fields === undefined) {
      return '';
    }
    const entry: LayerLWWEntry | undefined = fields.get(field);
    return entry !== undefined ? entry.value : '';
  }

  getLayerLWW(layerId: string): Map<string, LayerLWWEntry> {
    const fields: Map<string, LayerLWWEntry> | undefined = this.layerLWW.get(layerId);
    if (fields === undefined) {
      return new Map<string, LayerLWWEntry>();
    }
    return fields;
  }

  // ─── 查询 ───

  getElements(): RGAElement<T>[] {
    return this.elements;
  }

  getVisibleElements(): T[] {
    return this.elements.filter(e => !e.deleted).map(e => e.value);
  }

  getVectorClock(): VectorClock {
    return VectorClockHelper.clone(this.vectorClock);
  }

  getOpLogSince(clock: VectorClock): CRDTOp<T>[] {
    return this.opLog.filter(op => {
      const cmp = VectorClockHelper.compare(op.vectorClock, clock);
      return cmp === 'A_AFTER_B' || cmp === 'CONCURRENT';
    });
  }

  // ─── 快照 ───

  exportSnapshot(): RGASnapshot<T> {
    const snapshot: RGASnapshot<T> = {
      elements: this.elements.map(e => this.cloneRGAElement(e)),
      clock: VectorClockHelper.clone(this.vectorClock),
      elementLWW: this.exportElementLWW()
    };
    return snapshot;
  }

  importSnapshot(snapshot: RGASnapshot<T>): void {
    this.elements = snapshot.elements.map(e => this.cloneRGAElement(e));
    this.vectorClock = VectorClockHelper.clone(snapshot.clock);
    this.elementLWW = new Map<string, Map<string, ElementLWWEntry>>();
    if (snapshot.elementLWW !== undefined && snapshot.elementLWW !== null) {
      for (let i = 0; i < snapshot.elementLWW.length; i++) {
        const entry: ElementLWWEntry = snapshot.elementLWW[i];
        let fields: Map<string, ElementLWWEntry> | undefined = this.elementLWW.get(entry.elementId);
        if (fields === undefined) {
          fields = new Map<string, ElementLWWEntry>();
          this.elementLWW.set(entry.elementId, fields);
        }
        fields.set(entry.field, {
          elementId: entry.elementId,
          field: entry.field,
          value: entry.value,
          lamportTs: entry.lamportTs,
          siteId: entry.siteId,
        });
      }
    }
    Logger.info(TAG_MODULE, `Snapshot imported: ${this.elements.length} elements, lww=${snapshot.elementLWW !== undefined ? snapshot.elementLWW.length : 0}`);
  }

  /** 元素级 LWW 扁平导出（序列化友好） */
  private exportElementLWW(): ElementLWWEntry[] {
    const result: ElementLWWEntry[] = [];
    const keys: string[] = Array.from(this.elementLWW.keys());
    for (let i = 0; i < keys.length; i++) {
      const fields: Map<string, ElementLWWEntry> | undefined = this.elementLWW.get(keys[i]);
      if (fields === undefined) {
        continue;
      }
      const fieldKeys: string[] = Array.from(fields.keys());
      for (let k = 0; k < fieldKeys.length; k++) {
        const entry: ElementLWWEntry | undefined = fields.get(fieldKeys[k]);
        if (entry !== undefined) {
          result.push({
            elementId: entry.elementId,
            field: entry.field,
            value: entry.value,
            lamportTs: entry.lamportTs,
            siteId: entry.siteId,
          });
        }
      }
    }
    return result;
  }

  // ─── 操作日志导出 ───

  exportOpLog(): CRDTOp<T>[] {
    return [...this.opLog];
  }

  importOpLog(ops: CRDTOp<T>[]): void {
    for (const op of ops) {
      this.applyRemoteOp(op);
    }
  }

  getElementCount(): number {
    return this.elements.length;
  }

  getVisibleCount(): number {
    return this.elements.filter(e => !e.deleted).length;
  }

  private getOpKey(op: CRDTOp<T>): string {
    if (op.type === 'insert') {
      // ArkTS 不自动收窄联合类型，显式断言
      const insertOp: InsertOp<T> = op as InsertOp<T>;
      return `insert:${serializeNodeID(insertOp.element.id)}`;
    }
    if (op.type === 'delete') {
      const deleteOp: DeleteOp = op as DeleteOp;
      return `delete:${serializeNodeID(deleteOp.targetId)}:${deleteOp.timestamp}`;
    }
    if (op.type === 'update') {
      const updateOp: UpdateOp = op as UpdateOp;
      return `update:${serializeNodeID(updateOp.targetId)}:${updateOp.field}:${updateOp.timestamp}`;
    }
    const resurrectOp: ResurrectOp = op as ResurrectOp;
    return `resurrect:${serializeNodeID(resurrectOp.targetId)}:${resurrectOp.timestamp}`;
  }

  reset(): void {
    this.elements = [];
    this.vectorClock = {};
    this.opLog = [];
    this.processedOps.clear();
    this.lamportClock = 0;
    this.layerLWW.clear();
    this.elementLWW.clear();
    this.pendingInserts = [];
  }

  /** 逐字段复制 RGA 元素（替代对象展开，符合 arkts-no-spread） */
  private cloneRGAElement(e: RGAElement<T>): RGAElement<T> {
    const id: NodeID = { lamportTs: e.id.lamportTs, siteId: e.id.siteId };
    const afterId: NodeID | null =
      e.afterId !== null ? { lamportTs: e.afterId.lamportTs, siteId: e.afterId.siteId } : null;
    const result: RGAElement<T> = {
      id: id,
      value: e.value,
      deleted: e.deleted,
      afterId: afterId
    };
    return result;
  }
}
