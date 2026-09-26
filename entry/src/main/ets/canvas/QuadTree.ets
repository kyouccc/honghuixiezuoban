/**
 * QuadTree.ets — 四叉树空间索引（ENG-03，阶段1 P1 净新增）
 *
 * 职责：对画布节点做二维空间索引，支持「视口 + 10% 缓冲」快速查询可见节点，
 * 配合 CanvasEngine 的视口裁剪与 OffscreenCanvas 离屏静态层，目标万级节点 ≥55fps。
 *
 * 设计：
 *  - 采用 Region QuadTree（按节点包围盒插入，按 region 相交查询）；
 *  - 每个叶节点容量达到 maxNodes 且未达 maxDepth 时四等分细分；
 *  - 节点移动用 update(id, newBounds) 先 remove 再 insert；
 *  - 查询返回与 region 相交（含部分重叠）的 CanvasNode[]（调用方再按视口精确裁剪）。
 *
 * 与既有引擎零耦合：仅依赖 engine/types/BoardModel 的 CanvasNode / Rect 类型（纯类型）。
 *
 * ArkTS 严格模式：显式类型，无 any/unknown，无对象展开。
 */

import { CanvasNode, Rect, nodeBounds } from '../engine/types/BoardModel';

/** 四叉树缺省最大深度 */
const DEFAULT_MAX_DEPTH: number = 8;
/** 四叉树缺省单节点容量 */
const DEFAULT_MAX_NODES: number = 8;

/** 轴对齐矩形相交判断（含边界重叠） */
function rectsIntersect(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y;
}

/** 构造矩形（含越界保护：宽高下限 0） */
function normalizeRect(r: Rect): Rect {
  return {
    x: r.x,
    y: r.y,
    w: r.w > 0 ? r.w : 0,
    h: r.h > 0 ? r.h : 0
  };
}

/**
 * 四叉树索引。
 * 用法：rebuild(nodes) 一次性建树（节点增删频繁时亦可先 clear 再 rebuild）；
 *       query(viewportRect) 取可见节点；单点增删用 insert/remove/update。
 */
export class QuadTree {
  private bounds: Rect;
  private maxDepth: number;
  private maxNodes: number;
  private depth: number;
  private items: CanvasNode[] = [];
  private divided: boolean = false;
  private northwest: QuadTree | null = null;
  private northeast: QuadTree | null = null;
  private southwest: QuadTree | null = null;
  private southeast: QuadTree | null = null;

  constructor(bounds: Rect, maxDepth?: number, maxNodes?: number) {
    this.bounds = normalizeRect(bounds);
    this.maxDepth = maxDepth !== undefined && maxDepth > 0 ? maxDepth : DEFAULT_MAX_DEPTH;
    this.maxNodes = maxNodes !== undefined && maxNodes > 0 ? maxNodes : DEFAULT_MAX_NODES;
    this.depth = 0;
  }

  /** 当前树根包围盒 */
  getBounds(): Rect {
    return this.bounds;
  }

  /** 当前节点持有元素数（调试 / 容量诊断用） */
  getSize(): number {
    return this.items.length;
  }

  /**
   * 插入单个节点。交集判断：节点包围盒与当前分区相交即插入（避免横跨分界线的节点被遗漏）。
   * 达到容量且未达最大深度时细分；否则保留在叶节点（允许适度超载）。
   */
  insert(node: CanvasNode): void {
    if (!rectsIntersect(nodeBounds(node), this.bounds)) {
      return;
    }
    if (!this.divided && (this.items.length < this.maxNodes || this.depth >= this.maxDepth)) {
      this.items.push(node);
      return;
    }
    if (!this.divided) {
      this.subdivide();
    }
    // 已细分：向四个子区下放（相交即下发，可能重复落入多个子区，查询去重保证正确性）
    if (this.northwest !== null && rectsIntersect(nodeBounds(node), this.northwest.bounds)) {
      this.northwest.insert(node);
    }
    if (this.northeast !== null && rectsIntersect(nodeBounds(node), this.northeast.bounds)) {
      this.northeast.insert(node);
    }
    if (this.southwest !== null && rectsIntersect(nodeBounds(node), this.southwest.bounds)) {
      this.southwest.insert(node);
    }
    if (this.southeast !== null && rectsIntersect(nodeBounds(node), this.southeast.bounds)) {
      this.southeast.insert(node);
    }
  }

  /** 查询与 region 相交的全部节点（去重：同一节点可能落入多个子区） */
  query(region: Rect): CanvasNode[] {
    const result: CanvasNode[] = [];
    const seen: Set<string> = new Set<string>();
    this.queryInto(region, result, seen);
    return result;
  }

  private queryInto(region: Rect, out: CanvasNode[], seen: Set<string>): void {
    if (!rectsIntersect(region, this.bounds)) {
      return;
    }
    for (let i = 0; i < this.items.length; i++) {
      const node: CanvasNode = this.items[i];
      if (!seen.has(node.id) && rectsIntersect(nodeBounds(node), region)) {
        seen.add(node.id);
        out.push(node);
      }
    }
    if (this.divided && this.northwest !== null) {
      this.northwest.queryInto(region, out, seen);
      this.northeast!.queryInto(region, out, seen);
      this.southwest!.queryInto(region, out, seen);
      this.southeast!.queryInto(region, out, seen);
    }
  }

  /** 按 id 删除（软删除调用方置 deleted=true 后调用，或物理移除索引条目） */
  remove(id: string): void {
    for (let i = this.items.length - 1; i >= 0; i--) {
      if (this.items[i].id === id) {
        this.items.splice(i, 1);
        return;
      }
    }
    if (this.divided && this.northwest !== null) {
      this.northwest.remove(id);
      this.northeast!.remove(id);
      this.southwest!.remove(id);
      this.southeast!.remove(id);
    }
  }

  /** 节点移动后更新索引：先按旧 id 删除，再按新包围盒插入 */
  update(id: string, newBounds: Rect): void {
    this.remove(id);
    // 调用方需保证 node 仍可被访问；此处以 newBounds 重建一个临时占位插入不影响数据，
    // 因此 update 仅负责索引：实际节点对象由调用方持有。这里通过「重建无对象」不可行，
    // 故约定——调用方传入的 newBounds 仅用于判断分区，真正插入仍由调用方 insert 完成。
    // 为简化 API，update 直接委托 remove，调用方随后 insert(node) 即可。
    // （保留 newBounds 参数以便未来支持原地重插。）
    void newBounds;
  }

  /** 用节点数组一次性建树（清空旧树 + 批量插入） */
  rebuild(nodes: CanvasNode[]): void {
    this.clear();
    for (let i = 0; i < nodes.length; i++) {
      this.insert(nodes[i]);
    }
  }

  /** 清空全部节点（释放子区） */
  clear(): void {
    this.items = [];
    this.divided = false;
    this.northwest = null;
    this.northeast = null;
    this.southwest = null;
    this.southeast = null;
  }

  /** 细分当前分区为四个象限 */
  private subdivide(): void {
    const halfW: number = this.bounds.w / 2;
    const halfH: number = this.bounds.h / 2;
    const x: number = this.bounds.x;
    const y: number = this.bounds.y;
    const childDepth: number = this.depth + 1;
    this.northwest = new QuadTree({ x: x, y: y, w: halfW, h: halfH }, this.maxDepth, this.maxNodes);
    this.northwest.depth = childDepth;
    this.northeast = new QuadTree({ x: x + halfW, y: y, w: halfW, h: halfH }, this.maxDepth, this.maxNodes);
    this.northeast.depth = childDepth;
    this.southwest = new QuadTree({ x: x, y: y + halfH, w: halfW, h: halfH }, this.maxDepth, this.maxNodes);
    this.southwest.depth = childDepth;
    this.southeast = new QuadTree({ x: x + halfW, y: y + halfH, w: halfW, h: halfH }, this.maxDepth, this.maxNodes);
    this.southeast.depth = childDepth;
    this.divided = true;
    // 把当前叶节点承载的元素下放到子区（避免重复持有）
    const pending: CanvasNode[] = this.items;
    this.items = [];
    for (let i = 0; i < pending.length; i++) {
      const node: CanvasNode = pending[i];
      if (rectsIntersect(nodeBounds(node), this.northwest.bounds)) {
        this.northwest.insert(node);
      }
      if (rectsIntersect(nodeBounds(node), this.northeast.bounds)) {
        this.northeast.insert(node);
      }
      if (rectsIntersect(nodeBounds(node), this.southwest.bounds)) {
        this.southwest.insert(node);
      }
      if (rectsIntersect(nodeBounds(node), this.southeast.bounds)) {
        this.southeast.insert(node);
      }
    }
  }
}
