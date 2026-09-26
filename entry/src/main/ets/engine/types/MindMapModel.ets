/**
 * MindMapModel.ets — 思维导图领域模型（S2-B / T2-4 新建）
 *
 * 领域类型复用 NoteModel.HCMindMap / HCMindNode / HCMindEdge（.hcnote 持久化投影与内存态同构），
 * 本文件提供工厂函数与层级工具（层级化布局 / 深度计算）。
 *
 * 布局：根节点在中心，子节点向右侧逐层展开（x = 层深 * 水平间距，y 按兄弟序垂直排布）。
 */

import { HCMindMap, HCMindNode, HCMindEdge } from '../types/NoteModel';

const TAG_MODULE = 'MindMapModel';

/** 水平间距（每层） */
const LEVEL_GAP: number = 180;
/** 垂直间距（兄弟节点） */
const SIBLING_GAP: number = 70;

export class MindMapModel {
  /** 新建空导图 */
  static createEmpty(title: string, rootLabel: string): HCMindMap {
    const now: number = Date.now();
    const rootId: string = `n_${now}_0`;
    return {
      id: `map_${now}_${Math.random().toString(36).substring(2, 9)}`,
      title: title !== undefined && title.length > 0 ? title : '思维导图',
      rootLabel: rootLabel !== undefined && rootLabel.length > 0 ? rootLabel : '中心主题',
      nodes: [{ id: rootId, label: rootLabel, x: 0, y: 0, parentId: '' }],
      edges: [],
      createdAt: now,
    };
  }

  /** 追加子节点（parentId 指向父节点；布局：子节点在父节点右侧下一层） */
  static addNode(map: HCMindMap, parentId: string, label: string): HCMindNode | null {
    const parent: HCMindNode | null = MindMapModel.findNode(map, parentId);
    if (parent === null) {
      return null;
    }
    const siblings: HCMindNode[] = MindMapModel.childrenOf(map, parentId);
    const child: HCMindNode = {
      id: `n_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`,
      label: label !== undefined && label.length > 0 ? label : '分支',
      x: parent.x + LEVEL_GAP,
      y: parent.y + (siblings.length + 1) * SIBLING_GAP,
      parentId: parentId,
    };
    const next: HCMindNode[] = map.nodes.slice();
    next.push(child);
    const edge: HCMindEdge = {
      id: `e_${Date.now()}_${Math.random().toString(36).substring(2, 6)}`,
      from: parentId,
      to: child.id,
    };
    const nextEdges: HCMindEdge[] = map.edges.slice();
    nextEdges.push(edge);
    map.nodes = next;
    map.edges = nextEdges;
    return child;
  }

  /** 更新节点标签（返回新对象，不可变语义） */
  static updateLabel(map: HCMindMap, nodeId: string, label: string): boolean {
    const idx: number = MindMapModel.indexOfNode(map, nodeId);
    if (idx < 0) {
      return false;
    }
    const updated: HCMindNode = {
      id: map.nodes[idx].id,
      label: label !== undefined && label.length > 0 ? label : map.nodes[idx].label,
      x: map.nodes[idx].x,
      y: map.nodes[idx].y,
      parentId: map.nodes[idx].parentId,
    };
    const next: HCMindNode[] = map.nodes.slice();
    next[idx] = updated;
    map.nodes = next;
    return true;
  }

  /** 删除节点及其子树（连带边） */
  static removeSubtree(map: HCMindMap, nodeId: string): boolean {
    if (map.nodes.length > 0 && map.nodes[0] !== undefined && nodeId === map.nodes[0].id) {
      return false; // 根不可删
    }
    const doomed: Set<string> = MindMapModel.collectSubtree(map, nodeId);
    const nextNodes: HCMindNode[] = [];
    for (let i = 0; i < map.nodes.length; i++) {
      if (!doomed.has(map.nodes[i].id)) {
        nextNodes.push(map.nodes[i]);
      }
    }
    const nextEdges: HCMindEdge[] = [];
    for (let i = 0; i < map.edges.length; i++) {
      if (!doomed.has(map.edges[i].from) && !doomed.has(map.edges[i].to)) {
        nextEdges.push(map.edges[i]);
      }
    }
    map.nodes = nextNodes;
    map.edges = nextEdges;
    return true;
  }

  /** 收集节点及其子树 id（含自身） */
  static collectSubtree(map: HCMindMap, nodeId: string): Set<string> {
    const result: Set<string> = new Set<string>();
    const stack: string[] = [nodeId];
    while (stack.length > 0) {
      const cur: string = stack.pop()!;
      if (result.has(cur)) {
        continue;
      }
      result.add(cur);
      const children: HCMindNode[] = MindMapModel.childrenOf(map, cur);
      for (let i = 0; i < children.length; i++) {
        stack.push(children[i].id);
      }
    }
    return result;
  }

  /** 查找节点 */
  static findNode(map: HCMindMap, nodeId: string): HCMindNode | null {
    const idx: number = MindMapModel.indexOfNode(map, nodeId);
    return idx >= 0 ? map.nodes[idx] : null;
  }

  /** 子节点（按 y 升序） */
  static childrenOf(map: HCMindMap, parentId: string): HCMindNode[] {
    const result: HCMindNode[] = [];
    for (let i = 0; i < map.nodes.length; i++) {
      if (map.nodes[i].parentId === parentId) {
        result.push(map.nodes[i]);
      }
    }
    result.sort((a: HCMindNode, b: HCMindNode): number => a.y - b.y);
    return result;
  }

  /** 节点深度（根=0；未找到返回 -1） */
  static depthOf(map: HCMindMap, nodeId: string): number {
    let depth: number = 0;
    let cur: string = nodeId;
    const guard: number = map.nodes.length + 1;
    let steps: number = 0;
    while (steps < guard) {
      const node: HCMindNode | null = MindMapModel.findNode(map, cur);
      if (node === null || node.parentId.length === 0) {
        return depth;
      }
      depth++;
      cur = node.parentId;
      steps++;
    }
    return depth;
  }

  private static indexOfNode(map: HCMindMap, nodeId: string): number {
    for (let i = 0; i < map.nodes.length; i++) {
      if (map.nodes[i].id === nodeId) {
        return i;
      }
    }
    return -1;
  }
}
