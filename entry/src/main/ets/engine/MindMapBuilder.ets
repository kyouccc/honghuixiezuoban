/**
 * MindMapBuilder.ets — 思维导图构建器（S2-B / T2-4 新建）
 *
 * 手绘/大纲 → 层级节点：
 *  - buildFromOutline：大纲文本（每行一个节点，缩进=层级）→ HCMindMap；
 *  - buildFromStrokes：手绘笔迹 → 用 SketchToVector 几何聚类（convert/rdp）识别候选分支，
 *    按识别结果生成节点（识别失败退化为根节点 + 提示）。
 *
 * 复用 SketchToVector（几何聚类能力），本文件只做「识别结果 → 层级布局」编排。
 */

import { SketchToVector, VecPoint } from './SketchToVector';
import { HCMindMap, HCMindNode, HCMindEdge } from './types/NoteModel';
import { MindMapModel } from './types/MindMapModel';

const TAG_MODULE = 'MindMapBuilder';

/** 笔迹数据结构 */
export interface StrokePoints {
  points: VecPoint[];
}

/** 大纲 → 导图：每行一个节点，行首空白数（2 空格=1 级）为层级 */
export function buildFromOutline(title: string, outline: string): HCMindMap {
  const map: HCMindMap = MindMapModel.createEmpty(title, '中心主题');
  const lines: string[] = outline.split('\n');
  // 维护每层最近节点 id：levelStack[0]=根
  const levelStack: string[] = [map.nodes[0].id];
  for (let i = 0; i < lines.length; i++) {
    const raw: string = lines[i].replace(/\r/g, '');
    const trimmed: string = raw.trim();
    if (trimmed.length === 0) {
      continue;
    }
    const indent: number = Math.floor(raw.length - raw.trimStart().length);
    const level: number = Math.min(indent / 2, 4);
    // 若层级比当前栈浅 → 弹栈回退到该层父节点
    while (levelStack.length - 1 > level) {
      levelStack.pop();
    }
    const parentId: string = levelStack[levelStack.length - 1];
    const node: HCMindNode | null = MindMapModel.addNode(map, parentId, trimmed);
    if (node !== null) {
      levelStack.push(node.id);
    }
  }
  return map;
}

/**
 * 手绘笔迹 → 导图：
 * 对每条笔迹做形状识别（SketchToVector.convert），按识别出的 bounding 聚类分组：
 * 同一组（中心距离 < 120）合并为一个分支节点；识别失败忽略该笔。
 * 结果放入 map 的 nodes/edges（根节点为中心主题）。
 */
export function buildFromStrokes(title: string, rootLabel: string,
                                 strokes: StrokePoints[]): HCMindMap {
  const map: HCMindMap = MindMapModel.createEmpty(title, rootLabel);
  const rootId: string = map.nodes[0].id;
  const seen: string[] = [];
  for (let i = 0; i < strokes.length; i++) {
    const input: VecPoint[] = strokes[i].points;
    if (input === undefined || input === null || input.length < 5) {
      continue;
    }
    const result = SketchToVector.convert(input);
    if (result === null || result.points.length < 2) {
      continue;
    }
    // 以识别结果首点作为簇中心，相近（<120）视为同一分支
    const cx: number = result.points[0].x;
    const cy: number = result.points[0].y;
    let label: string = result.shape === 'line' ? '分支' : result.shape;
    // 检查是否已有相近节点 → 合并（不重复建）
    let merged: boolean = false;
    for (let k = 0; k < map.nodes.length; k++) {
      const n: HCMindNode = map.nodes[k];
      const dx: number = n.x - cx;
      const dy: number = n.y - cy;
      if (dx * dx + dy * dy < 120 * 120 && n.parentId === rootId) {
        merged = true;
        break;
      }
    }
    if (merged) {
      continue;
    }
    const node: HCMindNode | null = MindMapModel.addNode(map, rootId, label);
    if (node !== null) {
      // 用识别中心覆盖默认布局位置（更贴近手绘）
      node.x = Math.round(cx);
      node.y = Math.round(cy);
    }
    seen.push(result.shape);
  }
  return map;
}

/** 供外部扫描用：判断一条笔迹能否识别为有效几何（SketchToVector 能力接线） */
export function canRecognize(points: VecPoint[]): boolean {
  if (points === undefined || points === null || points.length < 5) {
    return false;
  }
  const result = SketchToVector.convert(points);
  return result !== null;
}
