/**
 * run-node-verify.mjs — Honghui v2.0 阶段一 P0 核心代码逻辑验证（QA）
 *
 * 通过 ets-loader.mjs 在 Node 环境直接运行真实 .ets 源文件（mock 鸿蒙 SDK 模块），
 * 对 S1T01~S1T03 交付的纯逻辑模块做运行验证：
 *   - BrushRegistry（6 笔刷 / 压感曲线采样 / 未知回退）
 *   - CanvasElement（联合类型结构判别）
 *   - LayerManager（纸/页图层只读语义、merge/duplicate/group/ungroup/export）
 *   - TextBlockTool（创建/编辑/位置）
 *   - CRDTOp（getElementTypeOfOp / deserializeNodeID / compareNodeIds）
 *   - PaperLayerRenderer（5 模板 / renderPaper 边界）
 *   - PDFRasterizer（.caj 降级 / 免费版 10 页上限 / 返回结构）
 *   - DocumentImporter（类型识别 / 导入编排 / 错误路径）
 *
 * 运行：node --experimental-transform-types --experimental-loader=./ets-loader.mjs run-node-verify.mjs
 */
import { writeFileSync, mkdirSync } from 'node:fs';

// ─── 断言工具 ───
let total = 0;
let passed = 0;
const failures = [];

function assert(cond, name, detail) {
  total++;
  if (cond) {
    passed++;
  } else {
    failures.push({ name, detail });
  }
}

function assertEq(actual, expected, name) {
  total++;
  if (Object.is(actual, expected)) {
    passed++;
  } else {
    failures.push({ name, detail: `expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}` });
  }
}

function assertThrows(fn, name, codeHint) {
  total++;
  try {
    fn();
    failures.push({ name, detail: 'expected throw, no throw' });
  } catch (e) {
    if (codeHint !== undefined && e.code !== codeHint) {
      failures.push({ name, detail: `expected code=${codeHint} actual=${e.code} msg=${e.message}` });
    } else {
      passed++;
    }
  }
}

function assertNoThrow(fn, name) {
  total++;
  try {
    fn();
    passed++;
  } catch (e) {
    failures.push({ name, detail: `expected no throw, got: ${e && e.message ? e.message : e}` });
  }
}

// ─── 导入真实源文件 ───
const base = '../entry/src/main/ets/';
const { BrushRegistry, BrushTool, BrushShape, BlendMode } = await import(base + 'engine/BrushRegistry.ets');
const { CanvasElementType, getCanvasElementType, getCanvasElementTypeLabel } = await import(base + 'engine/types/CanvasElement.ets');
const { LayerManager } = await import(base + 'engine/LayerManager.ets');
const { TextBlockTool, TextAlign } = await import(base + 'engine/TextBlockTool.ets');
const { getElementTypeOfOp, deserializeNodeID, compareNodeIds, serializeNodeID } = await import(base + 'crdt/types/CRDTOp.ets');
const { PaperLayerRenderer, PaperTemplate } = await import(base + 'engine/PaperLayerRenderer.ets');
const { DocumentRasterizeError, DOC_RASTERIZE_ERROR_CODE, ITextRasterizer } = await import(base + 'engine/document/ITextRasterizer.ets');
const { PDFRasterizer } = await import(base + 'engine/document/PDFRasterizer.ets');
const { DocumentImporter, DocFormat, DocumentImportError } = await import(base + 'engine/document/DocumentImporter.ets');

console.log('=== Honghui v2.0 阶段一核心逻辑运行验证 ===\n');

// ═══ 1. BrushRegistry ═══
console.log('--- BrushRegistry ---');
const brushConfigs = BrushRegistry.getBrushConfigs();
assertEq(brushConfigs.length, 6, '[BR-01] 笔刷总数=6');
const expectedTools = [BrushTool.PEN, BrushTool.PENCIL, BrushTool.HIGHLIGHTER, BrushTool.MARKER, BrushTool.BRUSH, BrushTool.LASER];
for (const t of expectedTools) {
  assert(BrushRegistry.isSupportedTool(t), `[BR-02] 支持工具 ${t}`);
  const cfg = BrushRegistry.getBrushConfig(t);
  assert(cfg.tool === t, `[BR-02] ${t} 配置 tool 字段`);
  assert(cfg.opacity >= 0 && cfg.opacity <= 1, `[BR-02] ${t} opacity∈[0,1]`);
  assert(cfg.minWidth > 0 && cfg.maxWidth >= cfg.minWidth, `[BR-02] ${t} 宽度范围合法`);
  assert(cfg.blendMode === BlendMode.NORMAL || cfg.blendMode === BlendMode.MULTIPLY, `[BR-02] ${t} blendMode 合法`);
  assert(cfg.brushShape === BrushShape.ROUND || cfg.brushShape === BrushShape.FLAT || cfg.brushShape === BrushShape.TEXTURE, `[BR-02] ${t} brushShape 合法`);
  assert(cfg.pressureCurve.length >= 2, `[BR-02] ${t} 压感曲线≥2 控制点`);
}
// 压感曲线采样：端点
const penCurve = BrushRegistry.getBrushConfig(BrushTool.PEN).pressureCurve; // [0,0.3,0.7,1.0]
assertEq(BrushRegistry.samplePressureCurve(penCurve, 0), 0, '[BR-03] 采样 t=0 → 曲线端点 0');
assertEq(BrushRegistry.samplePressureCurve(penCurve, 1), 1.0, '[BR-03] 采样 t=1 → 曲线端点 1.0');
// 插值：t=0.5 → idx=1 frac=0.5 → 0.3+(0.7-0.3)*0.5 = 0.5
assertEq(BrushRegistry.samplePressureCurve(penCurve, 0.5), 0.5, '[BR-04] 线性插值 t=0.5 → 0.5');
// 越界 clamp
assertEq(BrushRegistry.samplePressureCurve(penCurve, -0.5), 0, '[BR-05] t<0 clamp → 曲线端点 0');
assertEq(BrushRegistry.samplePressureCurve(penCurve, 1.5), 1.0, '[BR-05] t>1 clamp → 曲线端点 1.0');
// 空数组/单元素
assertEq(BrushRegistry.samplePressureCurve([], 0.5), 1.0, '[BR-06] 空曲线 → 1.0');
assertEq(BrushRegistry.samplePressureCurve([0.4], 0.9), 0.4, '[BR-06] 单元素曲线 → 0.4');
// 未知回退
const fallback = BrushRegistry.getBrushConfig('unknown_tool_xyz');
assertEq(fallback.tool, BrushTool.PEN, '[BR-07] 未知笔型回退 pen');
assert(!BrushRegistry.isSupportedTool('unknown_tool_xyz'), '[BR-07] isSupportedTool(未知)=false');
// clone 防篡改
const cfg1 = BrushRegistry.getBrushConfig(BrushTool.PEN);
cfg1.pressureCurve[0] = 999;
const cfg2 = BrushRegistry.getBrushConfig(BrushTool.PEN);
assertEq(cfg2.pressureCurve[0], 0, '[BR-08] 配置副本防篡改');
assertEq(BrushRegistry.getBrushNames().length, 6, '[BR-09] getBrushNames 6 个');

// ═══ 2. CanvasElement 判别 ═══
console.log('--- CanvasElement ---');
const baseElem = { id: 'e1', layerId: 'l1', createdBy: 'u1', createdAt: 1 };
const strokeEl = { ...baseElem, tool: 'pen', color: '#000', width: 2, points: [{ x: 0, y: 0, t: 0, pressure: 0.5 }] };
const shapeEl = { ...baseElem, shapeType: 'rectangle', x: 0, y: 0, width: 10, height: 10, color: '#000', rotation: 0, lineWidth: 2 };
const textEl = { ...baseElem, text: 'hi', x: 0, y: 0, fontSize: 20, fontFamily: 'HarmonyOS Sans', align: 'left', color: '#000' };
const annEl = { ...baseElem, annotationType: 'highlight', pageIndex: 3, refDocId: 'doc_x', refElementId: '', color: '#ff0', points: [], width: 2 };
const imgEl = { ...baseElem, imageHash: 'abc123', mimeType: 'image/png', x: 0, y: 0, width: 10, height: 10, binaryRef: '', uri: '', rotation: 0, scale: 1 };
assertEq(getCanvasElementType(strokeEl), CanvasElementType.STROKE, '[CE-01] stroke 判别');
assertEq(getCanvasElementType(shapeEl), CanvasElementType.SHAPE, '[CE-02] shape 判别');
assertEq(getCanvasElementType(textEl), CanvasElementType.TEXT_BLOCK, '[CE-03] text_block 判别');
assertEq(getCanvasElementType(annEl), CanvasElementType.ANNOTATION, '[CE-04] annotation 判别');
assertEq(getCanvasElementType(imgEl), CanvasElementType.IMAGE_REF, '[CE-05] image_ref 判别');
// 关键：AnnotationData 含 points 字段，不得被误判为 stroke（无 tool 字段）
assertEq(getCanvasElementType({ ...annEl, points: [{ x: 1, y: 1, t: 0, pressure: 0.5 }] }), CanvasElementType.ANNOTATION, '[CE-06] annotation+points 不被误判 stroke');
assertEq(getCanvasElementTypeLabel('stroke'), '笔迹', '[CE-07] 标签 stroke');
assertEq(getCanvasElementTypeLabel('unknown_type'), '未知', '[CE-07] 标签未知');

// ═══ 3. LayerManager ═══
console.log('--- LayerManager ---');
const lm = LayerManager.getInstance();
lm.reset();
const drawLayer = lm.createLayer('画图层', 'draw');
const paperLayer = lm.createPaperLayer('网格底纸', PaperTemplate.GRID);
const pageLayer = lm.createPageLayer('文档页 1', 'doc_x:0');
assertEq(paperLayer.type, 'paper', '[LM-01] createPaperLayer type=paper');
assertEq(paperLayer.paperTemplate, PaperTemplate.GRID, '[LM-01] paperTemplate 记录');
assertEq(pageLayer.type, 'page', '[LM-02] createPageLayer type=page');
assertEq(pageLayer.pageRef, 'doc_x:0', '[LM-02] pageRef 记录');
// 只读语义：paper/page 拒绝写元素
assertEq(lm.addElement(paperLayer.id, shapeEl), false, '[LM-03] paper 图层写元素被拒');
assertEq(lm.addElement(pageLayer.id, shapeEl), false, '[LM-03] page 图层写元素被拒');
assertEq(lm.getElements(paperLayer.id).length, 0, '[LM-03] paper 图层无元素');
// draw 图层写入分派
assertEq(lm.addElement(drawLayer.id, strokeEl), true, '[LM-04] draw 写入 stroke');
assertEq(lm.addElement(drawLayer.id, shapeEl), true, '[LM-04] draw 写入 shape');
assertEq(lm.addElement(drawLayer.id, textEl), true, '[LM-04] draw 写入 text');
assertEq(lm.addElement(drawLayer.id, annEl), true, '[LM-04] draw 写入 annotation');
assertEq(lm.addElement(drawLayer.id, imgEl), true, '[LM-04] draw 写入 image');
assertEq(lm.getStrokes(drawLayer.id).length, 1, '[LM-04] strokes=1');
assertEq(lm.getShapes(drawLayer.id).length, 1, '[LM-04] shapes=1');
assertEq(lm.getTextBlocks(drawLayer.id).length, 1, '[LM-04] textBlocks=1');
assertEq(lm.getAnnotations(drawLayer.id).length, 1, '[LM-04] annotations=1');
assertEq(lm.getImages(drawLayer.id).length, 1, '[LM-04] images=1');
assertEq(lm.getElements(drawLayer.id).length, 5, '[LM-04] getElements 汇总=5');
// 不存在的图层
assertEq(lm.addElement('no_such_layer', strokeEl), false, '[LM-05] 不存在图层写入 false');
assertEq(lm.addElement(drawLayer.id, { ...baseElem, shapeType: 'circle', x: 0, y: 0, width: 1, height: 1, color: '#000', rotation: 0, lineWidth: 1 }), true, '[LM-05b] circle shape 写入');
// mergeLayers：元素引用迁移
lm.reset();
const la = lm.createLayer('A', 'draw');
const lb = lm.createLayer('B', 'draw');
const sA = { ...baseElem, tool: 'pen', color: '#000', width: 2, points: [{ x: 0, y: 0, t: 0, pressure: 0.5 }] };
const sB = { ...baseElem, id: 'stroke_b', tool: 'pen', color: '#111', width: 3, points: [{ x: 1, y: 1, t: 0, pressure: 0.5 }] };
const shB = { ...baseElem, id: 'shape_b', shapeType: 'line', x: 0, y: 0, width: 5, height: 5, color: '#000', rotation: 0, lineWidth: 1 };
lm.addElement(la.id, sA);
lm.addElement(lb.id, sB);
lm.addElement(lb.id, shB);
const beforeCount = lm.getLayerCount(); // 默认 + A + B = 3
const merged = lm.mergeLayers([la.id, lb.id], '合并层');
assert(merged !== null, '[LM-06] mergeLayers 返回目标层');
assertEq(lm.getLayerCount(), beforeCount - 1, '[LM-06] 合并后图层数=3-2+1=2');
assertEq(lm.getElements(merged.id).length, 3, '[LM-06] 目标图层 3 个元素');
const mergedStrokes = lm.getStrokes(merged.id);
const mergedStrokeIds = mergedStrokes.map(s => s.id);
assert(mergedStrokeIds.includes('e1') && mergedStrokeIds.includes('stroke_b'), '[LM-06] 全部源元素 id 保留');
assert(mergedStrokes.length === 2, '[LM-06] 目标图层 2 个 stroke');
assert(mergedStrokes[0].value.layerId === merged.id, '[LM-06] 元素 layerId 迁移到目标层');
assertEq(lm.getLayer(la.id), null, '[LM-06] 源图层 A 已删除');
assertEq(lm.getLayer(lb.id), null, '[LM-06] 源图层 B 已删除');
// 空源
assertEq(lm.mergeLayers([], '空'), null, '[LM-07] 无有效源返回 null');
// duplicateLayer
lm.reset();
const ld = lm.createLayer('D', 'draw');
const sD = { ...baseElem, tool: 'pencil', color: '#222', width: 2, points: [{ x: 0, y: 0, t: 0, pressure: 0.5 }] };
lm.addElement(ld.id, sD);
const dup = lm.duplicateLayer(ld.id);
assert(dup !== null, '[LM-08] duplicateLayer 返回副本');
assert(dup.id !== ld.id, '[LM-08] 副本图层 id 全新');
const dupStrokes = lm.getStrokes(dup.id);
assertEq(dupStrokes.length, 1, '[LM-08] 副本元素数量一致');
assert(dupStrokes[0].id !== sD.id, '[LM-08] 副本元素生成全新 id');
assertEq(dupStrokes[0].value.tool, 'pencil', '[LM-08] 副本保留结构与样式');
assertEq(dupStrokes[0].value.layerId, dup.id, '[LM-08] 副本元素 layerId 指向副本');
assert(lm.getLayer(ld.id) !== null, '[LM-08] 源图层保留');
// groupLayers / ungroupLayer
lm.reset();
const g1 = lm.createLayer('G1', 'draw');
const g2 = lm.createLayer('G2', 'draw');
const group = lm.groupLayers([g1.id, g2.id]);
assert(group !== null, '[LM-09] groupLayers 返回分组');
assertEq(group.type, 'group', '[LM-09] 分组 type=group');
assertEq(lm.getLayer(g1.id).groupId, group.id, '[LM-09] G1.groupId → group');
assertEq(lm.getLayer(g2.id).groupId, group.id, '[LM-09] G2.groupId → group');
assertEq(lm.getGroupedLayerIds(group.id).length, 2, '[LM-09] 成员 2 个');
assertEq(lm.groupLayers([g1.id]), null, '[LM-10] 单层分组返回 null');
assertEq(lm.ungroupLayer(g1.id), false, '[LM-11] 对非 group 图层 ungroup false');
assertEq(lm.ungroupLayer(group.id), true, '[LM-11] ungroup 成功');
assertEq(lm.getLayer(g1.id).groupId, '', '[LM-11] 成员 groupId 清空');
assertEq(lm.getLayer(group.id), null, '[LM-11] 分组容器删除');
// exportLayer
lm.reset();
const le = lm.createLayer('导出层', 'draw');
lm.addElement(le.id, sD);
const exportData = lm.exportLayer(le.id);
assert(exportData !== null, '[LM-12] exportLayer 返回快照');
assertEq(exportData.elements.length, 1, '[LM-12] 快照元素=1');
assertEq(exportData.type, 'draw', '[LM-12] 快照 type');
assert(typeof exportData.exportedAt === 'number', '[LM-12] exportedAt 存在');
assertEq(lm.exportLayer('no_such'), null, '[LM-13] 导出不存在图层 null');
// getElements 过滤 deleted
lm.reset();
const lf = lm.createLayer('F', 'draw');
lm.addElement(lf.id, sD);
lm.getStrokes(lf.id)[0].deleted = true;
assertEq(lm.getElements(lf.id).length, 0, '[LM-14] getElements 过滤已删除 stroke');

// ═══ 4. TextBlockTool ═══
console.log('--- TextBlockTool ---');
const tbt = new TextBlockTool();
tbt.setFontSize(30);
tbt.setFontFamily('HarmonyOS Sans');
tbt.setAlign(TextAlign.CENTER);
tbt.setColor('#FF0000');
const block = tbt.createTextBlock('测试文本', 10, 20, 'layer_x', 'user_y');
assertEq(block.text, '测试文本', '[TB-01] createTextBlock text');
assertEq(block.x, 10, '[TB-01] x');
assertEq(block.y, 20, '[TB-01] y');
assertEq(block.layerId, 'layer_x', '[TB-01] layerId');
assertEq(block.createdBy, 'user_y', '[TB-01] createdBy');
assertEq(block.fontSize, 30, '[TB-01] fontSize');
assertEq(block.align, TextAlign.CENTER, '[TB-01] align');
assertEq(block.color, '#FF0000', '[TB-01] color');
assert(block.id.startsWith('text_'), '[TB-01] id 前缀');
assertEq(tbt.getFontSize(), 30, '[TB-02] getFontSize');
tbt.setFontSize(500);
assertEq(tbt.getFontSize(), 120, '[TB-03] setFontSize clamp 上限 120');
tbt.setFontSize(-5);
assertEq(tbt.getFontSize(), 8, '[TB-03] setFontSize clamp 下限 8');
tbt.setAlign('bogus');
assertEq(tbt.getAlign(), 'center', '[TB-04] 非法 align 忽略');
const edited = tbt.updateText(block, '新文本');
assertEq(edited.text, '新文本', '[TB-05] updateText 更新文本');
assertEq(edited.id, block.id, '[TB-05] updateText 保持 id');
assertEq(edited.layerId, block.layerId, '[TB-05] updateText 保持 layerId');
assertEq(edited.createdAt, block.createdAt, '[TB-05] updateText 保持 createdAt');
assert(block.text !== edited.text, '[TB-05] 不可变语义（原对象不变）');
const moved = tbt.updatePosition(block, 100, 200);
assertEq(moved.x, 100, '[TB-06] updatePosition x');
assertEq(moved.y, 200, '[TB-06] updatePosition y');
assertEq(moved.id, block.id, '[TB-06] updatePosition 保持 id');
assertEq(TextBlockTool.estimateWidth('abc', 20), 33, '[TB-07] estimateWidth(abc,20)=ceil(3*11)=33');
assertEq(TextBlockTool.estimateHeight(20, 2), 56, '[TB-08] estimateHeight(20,2)=ceil(2*28)=56');

// ═══ 5. CRDTOp ═══
console.log('--- CRDTOp ---');
assertEq(getElementTypeOfOp({ type: 'insert', elementType: 'shape' }), 'shape', '[CR-01] InsertOp.elementType=shape');
assertEq(getElementTypeOfOp({ type: 'insert' }), 'stroke', '[CR-02] 未标注回退 stroke');
assertEq(getElementTypeOfOp({ type: 'delete', targetId: { lamportTs: 1, siteId: 's' }, vectorClock: {}, timestamp: 1 }), 'stroke', '[CR-03] DeleteOp 回退 stroke');
const nid = deserializeNodeID('42:site_a');
assert(nid !== null && nid.lamportTs === 42 && nid.siteId === 'site_a', '[CR-04] deserializeNodeID 合法');
assertEq(deserializeNodeID(''), null, '[CR-05] 空串 → null');
assertEq(deserializeNodeID('abc'), null, '[CR-05] 无冒号 → null');
assertEq(deserializeNodeID(':site'), null, '[CR-06] 空 lamport → null');
assertEq(deserializeNodeID('5:'), null, '[CR-06] 空 site → null');
const n1 = { lamportTs: 5, siteId: 'a' };
const n2 = { lamportTs: 7, siteId: 'b' };
const n3 = { lamportTs: 5, siteId: 'b' };
assert(compareNodeIds(n1, n2) < 0, '[CR-07] lamport 5<7 → 负（实现返回差值）');
assert(compareNodeIds(n2, n1) > 0, '[CR-07] 7>5 → 正（实现返回差值）');
assert(compareNodeIds(n1, n3) < 0, '[CR-07] 同 lamport site a<b → 负');
assertEq(serializeNodeID(n1), '5:a', '[CR-08] serializeNodeID');

// ═══ 6. PaperLayerRenderer ═══
console.log('--- PaperLayerRenderer ---');
const templates = PaperLayerRenderer.getTemplates();
assertEq(templates.length, 5, '[PP-01] 5 种底纸模板');
for (const t of templates) {
  assert(PaperLayerRenderer.isSupported(t.template), `[PP-02] isSupported ${t.template}`);
}
assert(!PaperLayerRenderer.isSupported('lined_paper_v1'), '[PP-02] 未知模板 false');
// mock CanvasRenderingContext2D
function makeCtx() {
  return {
    save() {}, restore() {}, beginPath() {}, moveTo() {}, lineTo() {}, stroke() {}, fillRect() {}, arc() {}, fill() {},
    setLineDash() {},
    globalAlpha: 1, globalCompositeOperation: 'source-over',
    fillStyle: '', strokeStyle: '', lineWidth: 1,
  };
}
// 边界：0/负尺寸 → no-op 不抛
assertNoThrow(() => PaperLayerRenderer.renderPaper(makeCtx(), PaperTemplate.GRID, 0, 100), '[PP-03] w=0 边界');
assertNoThrow(() => PaperLayerRenderer.renderPaper(makeCtx(), PaperTemplate.GRID, 100, -1), '[PP-03] h<0 边界');
assertNoThrow(() => PaperLayerRenderer.renderPaper(null, PaperTemplate.GRID, 100, 100), '[PP-04] ctx=null 边界');
// 5 种模板正常渲染不抛
for (const t of templates) {
  assertNoThrow(() => PaperLayerRenderer.renderPaper(makeCtx(), t.template, 800, 600), `[PP-05] render ${t.template}`);
}
// 未知模板回退 blank（不抛）
assertNoThrow(() => PaperLayerRenderer.renderPaper(makeCtx(), 'nope', 800, 600), '[PP-06] 未知模板回退');
// 语义：renderPaper 不产生 CRDT 元素 —— 无 RGA/LayerManager 依赖，由模块静态审查确认
console.log('   [PP-07] 语义审查：PaperLayerRenderer 仅绘制 Canvas，无 CRDT 写入调用（静态确认）');

// ═══ 7. PDFRasterizer ═══
console.log('--- PDFRasterizer ---');
const pdfR = new PDFRasterizer();
assertEq(pdfR.supports('pdf'), true, '[PDF-01] supports(pdf)=true');
assertEq(pdfR.supports('caj'), false, '[PDF-01] supports(caj)=false');
// .caj 降级
const cajErr = await pdfR.rasterize('/tmp/x.CAJ', { maxPages: 10, scale: 1, backgroundColor: '#FFFFFF' })
  .then(() => null)
  .catch(e => e);
assert(cajErr instanceof DocumentRasterizeError, '[PDF-02] .caj 抛 DocumentRasterizeError');
assertEq(cajErr.code, DOC_RASTERIZE_ERROR_CODE, '[PDF-02] .caj 错误码 1105');
assert(cajErr.detail.includes('CAJ'), '[PDF-02] .caj 提示含 CAJ');
// 无效 PDF
const invalidErr = await pdfR.rasterize('/tmp/not_pdf.txt', { maxPages: 10, scale: 1, backgroundColor: '#FFFFFF' })
  .then(() => null)
  .catch(e => e);
assert(invalidErr instanceof DocumentRasterizeError, '[PDF-03] 无效 PDF 抛错');
assertEq(invalidErr.code, DOC_RASTERIZE_ERROR_CODE, '[PDF-03] 无效 PDF 错误码 1105');
// 构造 12 页 PDF（免费版截断到 10）
const tmpDir = './.qa_tmp';
mkdirSync(tmpDir, { recursive: true });
const pdf12 = tmpDir + '/sample12.pdf';
let pdfHead = '%PDF-1.4\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n2 0 obj\n<< /Type /Pages /Count 12 /Kids [3 0 R 4 0 R] >>\nendobj\n';
for (let i = 0; i < 12; i++) {
  pdfHead += `${i + 3} 0 obj\n<< /Type /Page /MediaBox [0 0 595 842] /Parent 2 0 R >>\nendobj\n`;
}
writeFileSync(pdf12, pdfHead);
const pages12 = await pdfR.rasterize(pdf12, { maxPages: 0, scale: 1, backgroundColor: '#FFFFFF' });
assertEq(pages12.length, 10, '[PDF-04] 免费版上限 10 页（maxPages=0 走默认 PDF_FREE_PAGE_LIMIT）');
assertEq(pages12[0].index, 0, '[PDF-05] 返回结构 index 从 0 开始');
assertEq(pages12[9].index, 9, '[PDF-05] 最后一页 index=9');
assert(pages12[0].width > 0 && pages12[0].height > 0, '[PDF-06] 页面尺寸>0');
assert(pages12[0].bitmap !== null, '[PDF-07] 位图非 null（mock）');
// options.maxPages=2 → 2 页
const pages2 = await pdfR.rasterize(pdf12, { maxPages: 2, scale: 1, backgroundColor: '#FFFFFF' });
assertEq(pages2.length, 2, '[PDF-08] maxPages=2 截断');
// 3 页 PDF 全量
const pdf3 = tmpDir + '/sample3.pdf';
let pdf3Head = '%PDF-1.4\n2 0 obj\n<< /Type /Pages /Count 3 /Kids [3 0 R] >>\nendobj\n';
for (let i = 0; i < 3; i++) {
  pdf3Head += `${i + 3} 0 obj\n<< /Type /Page /MediaBox [0 0 400 600] /Parent 2 0 R >>\nendobj\n`;
}
writeFileSync(pdf3, pdf3Head);
const pages3 = await pdfR.rasterize(pdf3, { maxPages: 10, scale: 1, backgroundColor: '#FFFFFF' });
assertEq(pages3.length, 3, '[PDF-09] 3 页 PDF 返回 3 页');
assertEq(pages3[0].width, 400, '[PDF-10] MediaBox 尺寸解析 400');
assertEq(pages3[0].height, 600, '[PDF-10] MediaBox 尺寸解析 600');

// ═══ 8. DocumentImporter ═══
console.log('--- DocumentImporter ---');
const di = DocumentImporter.getInstance();
assertEq(di.detectFormat('notes.pdf'), DocFormat.PDF, '[DI-01] detect .pdf');
assertEq(di.detectFormat('book.EPUB'), DocFormat.EPUB, '[DI-01] detect .epub（大小写不敏感）');
assertEq(di.detectFormat('paper.caj'), DocFormat.CAJ, '[DI-01] detect .caj');
assertEq(di.detectFormat('readme.txt'), DocFormat.UNKNOWN, '[DI-01] detect 未知');
// 未知类型错误路径
const unkErr = await di.import(pdf3, 'readme.txt')
  .then(() => null)
  .catch(e => e);
assert(unkErr instanceof DocumentImportError, '[DI-02] 未知类型抛 DocumentImportError');
assertEq(unkErr.code, DOC_RASTERIZE_ERROR_CODE, '[DI-02] 未知类型错误码 1105');
assert(unkErr.detail.includes('不支持'), '[DI-02] 未知类型提示');
// CAJ 降级
const cajImpErr = await di.import(pdf3, 'paper.caj')
  .then(() => null)
  .catch(e => e);
assert(cajImpErr instanceof DocumentImportError, '[DI-03] CAJ 导入抛错');
assert(cajImpErr.detail.includes('CAJ'), '[DI-03] CAJ 提示');
// EPUB 降级 P1
const epubImpErr = await di.import(pdf3, 'book.epub')
  .then(() => null)
  .catch(e => e);
assert(epubImpErr instanceof DocumentImportError, '[DI-04] EPUB 导入抛错（P1 降级）');
// 有效 PDF 导入编排
const meta = await di.import(pdf3, 'sample3.pdf');
assert(meta !== null && meta !== undefined, '[DI-05] import 成功');
assertEq(meta.format, DocFormat.PDF, '[DI-05] meta.format=pdf');
assertEq(meta.pageCount, 3, '[DI-05] meta.pageCount=3');
assertEq(meta.rasterized, true, '[DI-05] meta.rasterized=true');
assert(meta.docId.startsWith('doc_'), '[DI-05] docId 前缀');
assertEq(meta.pageLayers.length, 3, '[DI-05] pageLayers=3');
assertEq(meta.pageLayers[0].pageIndex, 0, '[DI-05] pageLayers[0].pageIndex=0');
// PageLayer 只读语义
const pageLayerId = meta.pageLayers[0].layerId;
const layerFromLm = lm.getLayer(pageLayerId);
assert(layerFromLm !== null, '[DI-06] PageLayer 已注册到 LayerManager');
assertEq(layerFromLm.type, 'page', '[DI-06] PageLayer type=page');
assertEq(layerFromLm.pageRef, `${meta.docId}:0`, '[DI-06] PageLayer pageRef=docId:0');
assertEq(lm.addElement(pageLayerId, shapeEl), false, '[DI-06] PageLayer 只读拒绝写入');
// getPageBitmap / getDocPageCount
const bmp = di.getPageBitmap(meta.docId, 1);
assert(bmp !== null, '[DI-07] getPageBitmap 返回位图');
assertEq(di.getDocPageCount(meta.docId), 3, '[DI-08] getDocPageCount=3');
assertEq(di.getPageBitmap('no_doc', 0), null, '[DI-09] 未知 docId → null');
di.clearDoc(meta.docId);
assertEq(di.getDocPageCount(meta.docId), 0, '[DI-10] clearDoc 后计数 0');

// ═══ 9. 边界场景（架构 §8.1 约定 5 / normalizeOptions 鲁棒性）═══
console.log('--- 边界场景 ---');
// 9.1 畸形 Annotation（缺 pageIndex/refDocId）：架构要求"视为无效元素拒绝入 RGA"
const badAnn = { ...baseElem, annotationType: 'highlight', color: '#ff0', points: [] };
const annType = getCanvasElementType(badAnn);
// 当前实现：判别函数会落到默认 stroke 分支（记录观察结果，供工程师确认是否符合约定 5）
console.log(`   [EDGE-01] 观察：缺 pageIndex 的 annotation 判别为 '${annType}'（架构约定 5 要求无效元素拒绝入 RGA）`);
// 9.2 部分 options（缺 backgroundColor）：normalizeOptions 透传 undefined → createBlankBitmap 内部捕获 → bitmap null
const pagesPartial = await pdfR.rasterize(pdf3, { maxPages: 2, scale: 1 });
assertEq(pagesPartial.length, 2, '[EDGE-02] 部分 options（无 backgroundColor）仍返回页数');
console.log(`   [EDGE-02] 观察：缺 backgroundColor 时页面 bitmap=${pagesPartial[0].bitmap === null ? 'null（内部捕获降级）' : '非 null'}`);

// ═══ 10. Round 2 回归专项（E-2 Annotation 校验 / E-3 backgroundColor 兜底）═══
console.log('--- Round 2 回归专项 ---');
// E-2：addElement ANNOTATION 分支校验（LayerManager.ets:287-294）
lm.reset();
const e2Layer = lm.createLayer('E2层', 'draw');
// E2-01：缺 refDocId（undefined）→ 判别为 annotation → 应被拒
const badAnnNoRef = { ...baseElem, annotationType: 'highlight', pageIndex: 0, color: '#ff0', points: [] };
assertEq(getCanvasElementType(badAnnNoRef), CanvasElementType.ANNOTATION, '[E2-01a] 缺 refDocId 仍判别为 annotation');
assertEq(lm.addElement(e2Layer.id, badAnnNoRef), false, '[E2-01b] 缺 refDocId 被拒');
// E2-02：refDocId 空串 → 应被拒
const badAnnEmptyRef = { ...baseElem, annotationType: 'highlight', pageIndex: 0, refDocId: '', color: '#ff0', points: [] };
assertEq(lm.addElement(e2Layer.id, badAnnEmptyRef), false, '[E2-02] refDocId 空串被拒');
// E2-03：pageIndex 负数 → 应被拒
const badAnnNeg = { ...baseElem, annotationType: 'highlight', pageIndex: -1, refDocId: 'doc_x', color: '#ff0', points: [] };
assertEq(lm.addElement(e2Layer.id, badAnnNeg), false, '[E2-03] pageIndex<0 被拒');
// E2-04：合法 annotation → 正常写入
const goodAnn = { ...baseElem, annotationType: 'highlight', pageIndex: 0, refDocId: 'doc_x', refElementId: '', color: '#ff0', points: [], width: 2 };
assertEq(lm.addElement(e2Layer.id, goodAnn), true, '[E2-04] 合法 annotation 写入');
assertEq(lm.getAnnotations(e2Layer.id).length, 1, '[E2-04] annotations=1');
assertEq(lm.getElements(e2Layer.id).length, 1, '[E2-04] 仅合法元素入图层');
// E2-05（观察）：缺 pageIndex（undefined）→ 判别层落入默认 stroke（架构约定 5 要求拒绝）
const badAnnNoPage = { ...baseElem, annotationType: 'highlight', color: '#ff0', points: [], refDocId: 'doc_x' };
const tNoPage = getCanvasElementType(badAnnNoPage);
const rNoPage = lm.addElement(e2Layer.id, badAnnNoPage);
console.log(`   [E2-05] 观察：缺 pageIndex 的畸形 annotation → 判别='${tNoPage}', addElement=${rNoPage}（判别层默认 stroke 分支，见报告 E-2 边界）`);
// E-3：无 backgroundColor 时页面位图非 null（DocumentImporter.ets:199-200 兜底）
const pagesE3 = await pdfR.rasterize(pdf3, { maxPages: 2, scale: 1 });
assert(pagesE3[0].bitmap !== null, '[E3-01] 无 backgroundColor 位图非 null（E-3 修复生效）');
const metaE3 = await di.import(pdf3, 'sample_e3.pdf', { maxPages: 2, scale: 1 });
assert(metaE3.pageLayers.length === 2, '[E3-02] 部分 options 导入成功');
const bmpE3 = di.getPageBitmap(metaE3.docId, 0);
assert(bmpE3 !== null, '[E3-03] 部分 options 导入后位图可查（非 null）');
di.clearDoc(metaE3.docId);

// ═══ 汇总 ═══
console.log('\n=== 验证结果 ===');
console.log(`Total: ${total} | Passed: ${passed} | Failed: ${total - passed}`);
if (failures.length > 0) {
  console.log('\n--- 失败明细 ---');
  for (const f of failures) {
    console.log(`✗ ${f.name}: ${f.detail}`);
  }
  process.exitCode = 1;
} else {
  console.log('全部通过 ✓');
}
// QA 结果落盘（stdout 捕获异常时通过文件读取结果）
import { writeFileSync as _writeFileSync } from 'node:fs';
_writeFileSync(new URL('./_verify_result.txt', import.meta.url),
  `TOTAL=${total}\nPASSED=${passed}\nFAILED=${total - passed}\nEXIT_CODE=${process.exitCode || 0}\n` +
  (failures.length > 0 ? 'FAILURES:\n' + failures.map(f => `- ${f.name}: ${f.detail}`).join('\n') : 'ALL_PASS'));
