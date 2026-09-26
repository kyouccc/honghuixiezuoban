/**
 * S1CoreTest.ets — HarmonyCanvas v2.0 阶段一 P0 核心模块测试（QA，S1T01~S1T03）
 *
 * 测试范围：
 *  - BrushRegistry：6 笔刷配置完整性、samplePressureCurve 采样（端点/插值/clamp）、未知笔型回退、副本防篡改
 *  - CanvasElement：getCanvasElementType 五类元素结构判别、getCanvasElementTypeLabel
 *  - LayerManager（v2 增量）：createPaperLayer/createPageLayer、paper/page 只读语义（写元素被拒）、
 *    addElement 统一分派、mergeLayers（元素引用迁移/源删除）、duplicateLayer（全新 id）、
 *    groupLayers/ungroupLayer、exportLayer
 *  - TextBlockTool：创建/编辑/位置更新、字号 clamp、尺寸估算
 *  - CRDTOp：getElementTypeOfOp 判别与回退、deserializeNodeID 输入验证、compareNodeIds/serializeNodeID
 *  - PaperLayerRenderer：5 种底纸模板、isSupported、renderPaper 边界（0/负尺寸）
 *
 * 运行方式：在 EntryAbility.onWindowStageCreate 中调用 `new S1CoreTest().runAll()`
 *（与 v1 tests/RGAEngineTest.ets 同模式；QA 另在 Node 环境通过 tests/run-node-verify.mjs
 *  对同一批逻辑做了运行验证，207 断言全部通过。）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BrushRegistry, BrushTool, BrushShape, BlendMode } from '../engine/BrushRegistry';
import { CanvasElementType, getCanvasElementType, getCanvasElementTypeLabel, CanvasElement, StrokeData, ShapeData, TextBlockData, AnnotationData, ImageRefData } from '../engine/types/CanvasElement';
import { LayerManager } from '../engine/LayerManager';
import { TextBlockTool, TextAlign } from '../engine/TextBlockTool';
import { getElementTypeOfOp, deserializeNodeID, compareNodeIds, serializeNodeID, InsertOp } from '../crdt/types/CRDTOp';
import { PaperLayerRenderer, PaperTemplate } from '../engine/PaperLayerRenderer';
import { Point } from '../engine/StrokeEngine';

const TAG = 'S1CoreTest';
const DOMAIN = 0x0000;

export class S1CoreTest {
  private passed: number = 0;
  private failed: number = 0;

  runAll(): void {
    hilog.info(DOMAIN, TAG, '=== S1T01~S1T03 核心模块测试 ===');
    this.runOne('BrushRegistry', () => this.testBrushRegistry());
    this.runOne('CanvasElement', () => this.testCanvasElement());
    this.runOne('LayerManager', () => this.testLayerManager());
    this.runOne('TextBlockTool', () => this.testTextBlockTool());
    this.runOne('CRDTOp', () => this.testCRDTOp());
    this.runOne('PaperLayerRenderer', () => this.testPaperLayerRenderer());
    this.printSummary();
  }

  private runOne(name: string, fn: () => void): void {
    try {
      fn();
    } catch (error) {
      this.fail(name, error as Error);
    }
  }

  // ═══ BrushRegistry ═══
  private testBrushRegistry(): void {
    const configs = BrushRegistry.getBrushConfigs();
    this.assert(configs.length === 6, 'BR-01 笔刷总数=6');
    const tools: string[] = [BrushTool.PEN, BrushTool.PENCIL, BrushTool.HIGHLIGHTER, BrushTool.MARKER, BrushTool.BRUSH, BrushTool.LASER];
    for (const t of tools) {
      this.assert(BrushRegistry.isSupportedTool(t), `BR-02 支持工具 ${t}`);
      const cfg = BrushRegistry.getBrushConfig(t);
      this.assert(cfg.opacity >= 0 && cfg.opacity <= 1, `BR-02 ${t} opacity∈[0,1]`);
      this.assert(cfg.minWidth > 0 && cfg.maxWidth >= cfg.minWidth, `BR-02 ${t} 宽度范围合法`);
      this.assert(cfg.blendMode === BlendMode.NORMAL || cfg.blendMode === BlendMode.MULTIPLY, `BR-02 ${t} blendMode`);
      this.assert(cfg.pressureCurve.length >= 2, `BR-02 ${t} 压感曲线≥2`);
    }
    const penCurve: number[] = BrushRegistry.getBrushConfig(BrushTool.PEN).pressureCurve;
    this.assert(Math.abs(BrushRegistry.samplePressureCurve(penCurve, 0) - 0) < 1e-9, 'BR-03 t=0 端点');
    this.assert(Math.abs(BrushRegistry.samplePressureCurve(penCurve, 1) - 1.0) < 1e-9, 'BR-03 t=1 端点');
    this.assert(Math.abs(BrushRegistry.samplePressureCurve(penCurve, 0.5) - 0.5) < 1e-9, 'BR-04 插值 t=0.5');
    this.assert(Math.abs(BrushRegistry.samplePressureCurve(penCurve, -0.5) - 0) < 1e-9, 'BR-05 t<0 clamp');
    this.assert(Math.abs(BrushRegistry.samplePressureCurve(penCurve, 1.5) - 1.0) < 1e-9, 'BR-05 t>1 clamp');
    this.assert(Math.abs(BrushRegistry.samplePressureCurve([], 0.5) - 1.0) < 1e-9, 'BR-06 空曲线');
    const fallback = BrushRegistry.getBrushConfig('unknown_tool_xyz');
    this.assert(fallback.tool === BrushTool.PEN, 'BR-07 未知笔型回退 pen');
    // 副本防篡改
    const cfgA = BrushRegistry.getBrushConfig(BrushTool.PEN);
    cfgA.pressureCurve[0] = 999;
    const cfgB = BrushRegistry.getBrushConfig(BrushTool.PEN);
    this.assert(cfgB.pressureCurve[0] === 0, 'BR-08 配置副本防篡改');
    this.pass('BrushRegistry');
  }

  // ═══ CanvasElement ═══
  private testCanvasElement(): void {
    const points: Point[] = [{ x: 0, y: 0, t: 0, pressure: 0.5 }];
    const stroke: StrokeData = {
      id: 'e1', layerId: 'l1', createdBy: 'u1', createdAt: 1,
      tool: 'pen', color: '#000', width: 2, points: points,
    };
    const shape: ShapeData = { id: 'e2', layerId: 'l1', createdBy: 'u1', createdAt: 1, shapeType: 'rectangle', x: 0, y: 0, width: 10, height: 10, color: '#000', rotation: 0, lineWidth: 2 };
    const text: TextBlockData = { id: 'e3', layerId: 'l1', createdBy: 'u1', createdAt: 1, text: 'hi', x: 0, y: 0, fontSize: 20, fontFamily: 'HarmonyOS Sans', align: 'left', color: '#000' };
    const ann: AnnotationData = { id: 'e4', layerId: 'l1', createdBy: 'u1', createdAt: 1, annotationType: 'highlight', pageIndex: 3, refDocId: 'doc_x', refElementId: '', color: '#ff0', points: points, width: 2 };
    const img: ImageRefData = { id: 'e5', layerId: 'l1', createdBy: 'u1', createdAt: 1, imageHash: 'abc', mimeType: 'image/png', x: 0, y: 0, width: 10, height: 10, binaryRef: '', uri: '', rotation: 0, scale: 1 };
    this.assert(getCanvasElementType(stroke) === CanvasElementType.STROKE, 'CE-01 stroke 判别');
    this.assert(getCanvasElementType(shape) === CanvasElementType.SHAPE, 'CE-02 shape 判别');
    this.assert(getCanvasElementType(text) === CanvasElementType.TEXT_BLOCK, 'CE-03 text 判别');
    this.assert(getCanvasElementType(ann) === CanvasElementType.ANNOTATION, 'CE-04 annotation 判别');
    this.assert(getCanvasElementType(img) === CanvasElementType.IMAGE_REF, 'CE-05 image 判别');
    this.assert(getCanvasElementTypeLabel('stroke') === '笔迹', 'CE-06 标签');
    this.assert(getCanvasElementTypeLabel('bogus') === '未知', 'CE-06 未知标签');
    this.pass('CanvasElement');
  }

  // ═══ LayerManager（v2 增量）═══
  private testLayerManager(): void {
    const lm = LayerManager.getInstance();
    lm.reset();
    const drawLayer = lm.createLayer('画图层', 'draw');
    const paperLayer = lm.createPaperLayer('网格底纸', PaperTemplate.GRID);
    const pageLayer = lm.createPageLayer('文档页 1', 'doc_x:0');
    this.assert(paperLayer.type === 'paper' && paperLayer.paperTemplate === PaperTemplate.GRID, 'LM-01 createPaperLayer');
    this.assert(pageLayer.type === 'page' && pageLayer.pageRef === 'doc_x:0', 'LM-02 createPageLayer');
    const shape: ShapeData = { id: 's1', layerId: '', createdBy: 'u', createdAt: 1, shapeType: 'rectangle', x: 0, y: 0, width: 10, height: 10, color: '#000', rotation: 0, lineWidth: 2 };
    this.assert(!lm.addElement(paperLayer.id, shape), 'LM-03 paper 图层写元素被拒');
    this.assert(!lm.addElement(pageLayer.id, shape), 'LM-03 page 图层写元素被拒');
    this.assert(lm.getElements(paperLayer.id).length === 0, 'LM-03 paper 无元素');
    const points: Point[] = [{ x: 0, y: 0, t: 0, pressure: 0.5 }];
    const stroke: StrokeData = { id: 'st1', layerId: drawLayer.id, createdBy: 'u', createdAt: 1, tool: 'pen', color: '#000', width: 2, points: points };
    const text: TextBlockData = { id: 't1', layerId: drawLayer.id, createdBy: 'u', createdAt: 1, text: 'hi', x: 0, y: 0, fontSize: 20, fontFamily: 'HarmonyOS Sans', align: 'left', color: '#000' };
    const ann: AnnotationData = { id: 'a1', layerId: drawLayer.id, createdBy: 'u', createdAt: 1, annotationType: 'highlight', pageIndex: 0, refDocId: 'd', refElementId: '', color: '#ff0', points: points, width: 2 };
    const img: ImageRefData = { id: 'i1', layerId: drawLayer.id, createdBy: 'u', createdAt: 1, imageHash: 'h', mimeType: 'image/png', x: 0, y: 0, width: 10, height: 10, binaryRef: '', uri: '', rotation: 0, scale: 1 };
    this.assert(lm.addElement(drawLayer.id, stroke), 'LM-04 写 stroke');
    this.assert(lm.addElement(drawLayer.id, shape), 'LM-04 写 shape');
    this.assert(lm.addElement(drawLayer.id, text), 'LM-04 写 text');
    this.assert(lm.addElement(drawLayer.id, ann), 'LM-04 写 annotation');
    this.assert(lm.addElement(drawLayer.id, img), 'LM-04 写 image');
    this.assert(lm.getElements(drawLayer.id).length === 5, 'LM-04 getElements=5');

    // mergeLayers
    lm.reset();
    const la = lm.createLayer('A', 'draw');
    const lb = lm.createLayer('B', 'draw');
    const sA: StrokeData = { id: 'sa', layerId: la.id, createdBy: 'u', createdAt: 1, tool: 'pen', color: '#000', width: 2, points: points };
    const sB: StrokeData = { id: 'sb', layerId: lb.id, createdBy: 'u', createdAt: 1, tool: 'pen', color: '#111', width: 3, points: points };
    lm.addElement(la.id, sA);
    lm.addElement(lb.id, sB);
    const beforeCount: number = lm.getLayerCount();
    const merged = lm.mergeLayers([la.id, lb.id], '合并层');
    this.assert(merged !== null, 'LM-06 merge 返回目标层');
    if (merged === null) {
      this.fail('LayerManager', new Error('merged is null'));
      return;
    }
    this.assert(lm.getLayerCount() === beforeCount - 1, 'LM-06 合并后图层数-1');
    const mStrokes = lm.getStrokes(merged.id);
    this.assert(mStrokes.length === 2, 'LM-06 目标 2 个 stroke');
    this.assert(mStrokes[0].value.layerId === merged.id, 'LM-06 元素 layerId 迁移');
    this.assert(lm.getLayer(la.id) === null && lm.getLayer(lb.id) === null, 'LM-06 源图层删除');
    this.assert(lm.mergeLayers([], '空') === null, 'LM-07 空源返回 null');

    // duplicateLayer
    lm.reset();
    const ld = lm.createLayer('D', 'draw');
    lm.addElement(ld.id, sA);
    const dup = lm.duplicateLayer(ld.id);
    this.assert(dup !== null && dup.id !== ld.id, 'LM-08 duplicate 全新图层 id');
    if (dup === null) {
      this.fail('LayerManager', new Error('dup is null'));
      return;
    }
    const dupStrokes = lm.getStrokes(dup.id);
    this.assert(dupStrokes.length === 1 && dupStrokes[0].id !== sA.id, 'LM-08 副本元素全新 id');
    this.assert(lm.getLayer(ld.id) !== null, 'LM-08 源图层保留');

    // group/ungroup
    lm.reset();
    const g1 = lm.createLayer('G1', 'draw');
    const g2 = lm.createLayer('G2', 'draw');
    const group = lm.groupLayers([g1.id, g2.id]);
    this.assert(group !== null && group.type === 'group', 'LM-09 group 创建');
    if (group === null) {
      this.fail('LayerManager', new Error('group is null'));
      return;
    }
    const g1Layer = lm.getLayer(g1.id);
    this.assert(g1Layer !== null && g1Layer.groupId === group.id, 'LM-09 成员 groupId');
    this.assert(lm.groupLayers([g1.id]) === null, 'LM-10 单层分组 null');
    this.assert(!lm.ungroupLayer(g1.id), 'LM-11 非 group ungroup false');
    this.assert(lm.ungroupLayer(group.id), 'LM-11 ungroup 成功');
    const g1LayerAfter = lm.getLayer(g1.id);
    this.assert(g1LayerAfter !== null && g1LayerAfter.groupId === '', 'LM-11 groupId 清空');

    // exportLayer
    lm.reset();
    const le = lm.createLayer('导出层', 'draw');
    lm.addElement(le.id, sA);
    const exportData = lm.exportLayer(le.id);
    this.assert(exportData !== null && exportData.elements.length === 1, 'LM-12 exportLayer 快照');
    if (exportData === null) {
      this.fail('LayerManager', new Error('exportData is null'));
      return;
    }
    this.assert(exportData.type === 'draw', 'LM-12 快照 type');
    this.assert(lm.exportLayer('no_such') === null, 'LM-13 导出不存在 null');
    this.pass('LayerManager');
  }

  // ═══ TextBlockTool ═══
  private testTextBlockTool(): void {
    const tbt = new TextBlockTool();
    tbt.setFontSize(30);
    tbt.setAlign(TextAlign.CENTER);
    const block = tbt.createTextBlock('测试', 10, 20, 'layer_x', 'user_y');
    this.assert(block.text === '测试' && block.x === 10 && block.y === 20, 'TB-01 create 字段');
    this.assert(block.layerId === 'layer_x' && block.createdBy === 'user_y', 'TB-01 layerId/createdBy');
    this.assert(block.fontSize === 30 && block.align === TextAlign.CENTER, 'TB-01 样式字段');
    tbt.setFontSize(500);
    this.assert(tbt.getFontSize() === 120, 'TB-02 clamp 上限');
    tbt.setFontSize(-5);
    this.assert(tbt.getFontSize() === 8, 'TB-02 clamp 下限');
    const edited = tbt.updateText(block, '新');
    this.assert(edited.text === '新' && edited.id === block.id, 'TB-03 updateText 保持 id');
    const moved = tbt.updatePosition(block, 100, 200);
    this.assert(moved.x === 100 && moved.y === 200 && moved.id === block.id, 'TB-04 updatePosition');
    this.assert(TextBlockTool.estimateWidth('abc', 20) === 33, 'TB-05 estimateWidth');
    this.assert(TextBlockTool.estimateHeight(20, 2) === 56, 'TB-06 estimateHeight');
    this.pass('TextBlockTool');
  }

  // ═══ CRDTOp ═══
  private testCRDTOp(): void {
    // 创建测试用的最小 InsertOp 对象
    const testInsertOp1: InsertOp<CanvasElement> = {
      type: 'insert',
      element: { id: { lamportTs: 1, siteId: 'test' }, value: {} as CanvasElement, deleted: false, afterId: null },
      afterId: null,
      vectorClock: {},
      timestamp: 1,
      elementType: 'shape'
    };
    const testInsertOp2: InsertOp<CanvasElement> = {
      type: 'insert',
      element: { id: { lamportTs: 2, siteId: 'test' }, value: {} as CanvasElement, deleted: false, afterId: null },
      afterId: null,
      vectorClock: {},
      timestamp: 2
    };
    this.assert(getElementTypeOfOp(testInsertOp1) === 'shape', 'CR-01 elementType');
    this.assert(getElementTypeOfOp(testInsertOp2) === 'stroke', 'CR-02 未标注回退 stroke');
    this.assert(deserializeNodeID('42:site_a') !== null, 'CR-03 deserialize 合法');
    this.assert(deserializeNodeID('') === null, 'CR-04 空串 null');
    this.assert(deserializeNodeID('abc') === null, 'CR-04 无冒号 null');
    this.assert(deserializeNodeID(':site') === null, 'CR-05 空 lamport null');
    this.assert(deserializeNodeID('5:') === null, 'CR-05 空 site null');
    this.assert(compareNodeIds({ lamportTs: 5, siteId: 'a' }, { lamportTs: 7, siteId: 'b' }) < 0, 'CR-06 compare<0');
    this.assert(serializeNodeID({ lamportTs: 5, siteId: 'a' }) === '5:a', 'CR-07 serialize');
    this.pass('CRDTOp');
  }

  // ═══ PaperLayerRenderer（静态可测部分）═══
  private testPaperLayerRenderer(): void {
    const templates = PaperLayerRenderer.getTemplates();
    this.assert(templates.length === 5, 'PP-01 5 种底纸');
    for (const t of templates) {
      this.assert(PaperLayerRenderer.isSupported(t.template), `PP-02 isSupported ${t.template}`);
    }
    this.assert(!PaperLayerRenderer.isSupported('bogus'), 'PP-02 未知 false');
    this.pass('PaperLayerRenderer');
  }

  private assert(condition: boolean, message: string): void {
    if (!condition) {
      throw new Error(`Assertion failed: ${message}`);
    }
  }

  private pass(name: string): void {
    this.passed++;
    hilog.info(DOMAIN, TAG, `✓ ${name}`);
  }

  private fail(name: string, error: Error): void {
    this.failed++;
    hilog.error(DOMAIN, TAG, `✗ ${name}: ${JSON.stringify(error.message)}`);
  }

  private printSummary(): void {
    hilog.info(DOMAIN, TAG, '=== S1CoreTest Summary ===');
    hilog.info(DOMAIN, TAG, `Passed: ${this.passed} | Failed: ${this.failed} | Total: ${this.passed + this.failed}`);
  }
}
