/**
 * S1NoteTest.ets — Honghui v2.4 阶段一「笔记文档」单元测试（T1-2）
 *
 * 测试范围（纯内存逻辑，不触磁盘，可在预览器/真机直接跑）：
 *  - 数值量化：quantize / quantizeClamped / roundSize，以及 q(q(x)) === q(x) 幂等性
 *  - 底纸模板归一：白名单命中 + 非法值降级 blank
 *  - FNV-1a 校验和：格式、稳定性、雪崩、中文可复现
 *  - StrokeRecord ↔ HCStroke 双向映射：点位展平/还原、默认值兜底、layerId 兜底与回写
 *  - ImageRefData ↔ HCImage 双向映射（uri-only，U-4）
 *  - Layer → HCLayer 白名单投影：必须剔除 offscreenCanvas（S-3），保留 paperTemplate
 *  - serialize / deserialize 往返一致 + **字节级幂等**（A1-7）
 *  - 容错：空文本 / 非 JSON / 魔数非法 一律 ok=false 且 content 非空（S-5）
 *  - 版本：低版本迁移直通、高版本 forwardRaw 原样保留（§2.8）
 *  - composeContent：底纸归一写回 meta、笔画兜底层为绘制层而非底纸层（C-4 回归）
 *  - 工厂与文案：createNoteId 格式、normalizeNoteTitle 截断、保存三态文案/配色（U-2）
 *
 * 运行方式：在 EntryAbility.onWindowStageCreate 中调用 `new S1NoteTest().runAll()`
 *（与 tests/S1CoreTest.ets 完全同模式）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NoteDeserializeResult, NoteSerializer } from '../engine/NoteSerializer';
import { Layer, LayerManager } from '../engine/LayerManager';
import { ImageRefData } from '../engine/types/CanvasElement';
import {
  HCImage,
  HCLayer,
  HCNoteFileRaw,
  HCStroke,
  HC_CHECKSUM_PREFIX,
  HC_DEFAULT_PAPER,
  HC_LOCAL_AUTHOR,
  HC_NOTE_MAGIC,
  HC_NOTE_SCHEMA_VERSION,
  NoteContent,
  NoteMeta,
  NoteSaveState,
  StrokeRecord,
  createEmptyNoteContent,
  createNoteId,
  createNoteMeta,
  normalizeNoteTitle,
  noteSaveStateColor,
  noteSaveStateText
} from '../engine/types/NoteModel';

const TAG = 'S1NoteTest';
const DOMAIN = 0x0000;

export class S1NoteTest {
  private passed: number = 0;
  private failed: number = 0;
  private assertions: number = 0;

  runAll(): void {
    hilog.info(DOMAIN, TAG, '=== T1-2 笔记序列化 / 模型层测试 ===');
    this.runOne('Quantize', (): void => this.testQuantize());
    this.runOne('PaperTemplate', (): void => this.testPaperTemplate());
    this.runOne('Checksum', (): void => this.testChecksum());
    this.runOne('StrokeMapping', (): void => this.testStrokeMapping());
    this.runOne('ImageMapping', (): void => this.testImageMapping());
    this.runOne('LayerProjection', (): void => this.testLayerProjection());
    this.runOne('SerializeRoundTrip', (): void => this.testSerializeRoundTrip());
    this.runOne('Idempotent', (): void => this.testIdempotent());
    this.runOne('Corrupted', (): void => this.testCorrupted());
    this.runOne('SchemaVersion', (): void => this.testSchemaVersion());
    this.runOne('ComposeContent', (): void => this.testComposeContent());
    this.runOne('ModelFactory', (): void => this.testModelFactory());
    this.printSummary();
  }

  private runOne(name: string, fn: () => void): void {
    try {
      fn();
    } catch (error) {
      this.fail(name, error as Error);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  // 一、数值量化
  // ═══════════════════════════════════════════════════════════════
  private testQuantize(): void {
    this.assert(NoteSerializer.quantize(1.23456) === 1.23, 'NQ-01 向下量化 2 位');
    this.assert(NoteSerializer.quantize(1.239) === 1.24, 'NQ-01 四舍五入');
    this.assert(NoteSerializer.quantize(-1.23456) === -1.23, 'NQ-02 负数量化');
    this.assert(NoteSerializer.quantize(0) === 0, 'NQ-03 零');
    this.assert(NoteSerializer.quantize(-0.001) === 0, 'NQ-03 -0 归零');
    this.assert(NoteSerializer.quantize(Number.NaN) === 0, 'NQ-04 NaN 归零');
    this.assert(NoteSerializer.quantize(Number.POSITIVE_INFINITY) === 0, 'NQ-04 Infinity 归零');

    // 幂等：q(q(x)) === q(x)，字节级幂等的基石
    const samples: number[] = [0.005, 1.005, 12.3456, -7.891, 199.999, 0.1 + 0.2];
    for (let i = 0; i < samples.length; i++) {
      const once: number = NoteSerializer.quantize(samples[i]);
      const twice: number = NoteSerializer.quantize(once);
      this.assert(once === twice, `NQ-05 量化幂等 ${samples[i]}`);
    }

    this.assert(NoteSerializer.quantizeClamped(5, 0, 1) === 1, 'NQ-06 上界 clamp');
    this.assert(NoteSerializer.quantizeClamped(-5, 0, 1) === 0, 'NQ-06 下界 clamp');
    this.assert(NoteSerializer.quantizeClamped(0.456, 0, 1) === 0.46, 'NQ-06 区间内量化');

    this.assert(NoteSerializer.roundSize(1079.6) === 1080, 'NQ-07 尺寸取整');
    this.assert(NoteSerializer.roundSize(-10) === 0, 'NQ-07 负尺寸归零');
    this.assert(NoteSerializer.roundSize(Number.NaN) === 0, 'NQ-07 NaN 尺寸归零');
    this.pass('Quantize');
  }

  // ═══════════════════════════════════════════════════════════════
  // 二、底纸模板
  // ═══════════════════════════════════════════════════════════════
  private testPaperTemplate(): void {
    const legal: string[] = ['blank', 'grid', 'dot', 'lined', 'four_line'];
    for (let i = 0; i < legal.length; i++) {
      this.assert(NoteSerializer.normalizePaperTemplate(legal[i]) === legal[i], `NP-01 白名单 ${legal[i]}`);
    }
    this.assert(NoteSerializer.normalizePaperTemplate('bogus') === HC_DEFAULT_PAPER, 'NP-02 未知降级 blank');
    this.assert(NoteSerializer.normalizePaperTemplate('') === HC_DEFAULT_PAPER, 'NP-02 空串降级 blank');
    this.assert(NoteSerializer.normalizePaperTemplate('GRID') === HC_DEFAULT_PAPER, 'NP-03 大小写敏感，非白名单降级');
    this.pass('PaperTemplate');
  }

  // ═══════════════════════════════════════════════════════════════
  // 三、校验和
  // ═══════════════════════════════════════════════════════════════
  private testChecksum(): void {
    const a: string = NoteSerializer.checksum('hello');
    this.assert(a.indexOf(HC_CHECKSUM_PREFIX) === 0, 'NC-01 前缀 fnv1a:');
    this.assert(a.length === HC_CHECKSUM_PREFIX.length + 8, 'NC-02 定长 8 位十六进制');
    this.assert(NoteSerializer.checksum('hello') === a, 'NC-03 同输入同输出');
    this.assert(NoteSerializer.checksum('hellp') !== a, 'NC-04 单字符差异雪崩');
    this.assert(NoteSerializer.checksum('') === NoteSerializer.checksum(''), 'NC-05 空串稳定');
    const cn: string = NoteSerializer.checksum('鸿绘协作板·中文标题');
    this.assert(cn === NoteSerializer.checksum('鸿绘协作板·中文标题'), 'NC-06 中文可复现');
    this.assert(cn.length === HC_CHECKSUM_PREFIX.length + 8, 'NC-06 中文同样定长');
    this.pass('Checksum');
  }

  // ═══════════════════════════════════════════════════════════════
  // 四、笔画映射
  // ═══════════════════════════════════════════════════════════════
  private buildStroke(id: number, layerId: string): StrokeRecord {
    return {
      id: id,
      tool: 'highlighter',
      color: '#FFD700',
      width: 12.3456,
      points: [{ x: 10.129, y: 20.994 }, { x: 30.5, y: 40.5 }, { x: 50.001, y: 60.009 }],
      opacity: 0.4,
      blendMode: 'multiply',
      brushShape: 'flat',
      layerId: layerId,
      createdAt: 1700000000000,
    };
  }

  private testStrokeMapping(): void {
    const record: StrokeRecord = this.buildStroke(7, 'layer_draw');
    const hc: HCStroke = NoteSerializer.strokeRecordToHC(record, 'layer_fallback');

    this.assert(hc.id === 's_7', 'NS-01 落盘 id 前缀');
    this.assert(hc.layerId === 'layer_draw', 'NS-02 保留原 layerId');
    this.assert(hc.tool === 'highlighter', 'NS-03 tool 透传');
    this.assert(hc.blendMode === 'multiply', 'NS-03 blendMode 透传');
    this.assert(hc.brushShape === 'flat', 'NS-03 brushShape 透传');
    this.assert(hc.createdBy === HC_LOCAL_AUTHOR, 'NS-04 作者恒为 local');
    this.assert(hc.points.length === 6, 'NS-05 点位展平为 2n');
    this.assert(hc.points[0] === 10.13, 'NS-05 x 量化');
    this.assert(hc.points[1] === 20.99, 'NS-05 y 量化');
    this.assert(hc.width === 12.35, 'NS-06 宽度量化');
    this.assert(hc.opacity === 0.4, 'NS-06 透明度量化');

    // 量化必须回写内存，否则第二次保存字节不同
    this.assert(record.points[0].x === 10.13, 'NS-07 量化回写内存 x');
    this.assert(record.width === 12.35, 'NS-07 量化回写内存 width');

    // layerId 兜底
    const orphan: StrokeRecord = this.buildStroke(8, '');
    const hcOrphan: HCStroke = NoteSerializer.strokeRecordToHC(orphan, 'layer_fallback');
    this.assert(hcOrphan.layerId === 'layer_fallback', 'NS-08 空 layerId 走兜底');
    this.assert(orphan.layerId === 'layer_fallback', 'NS-08 兜底同样回写内存');

    // 反向还原
    const back: StrokeRecord[] = NoteSerializer.hcToStrokeRecords([hc]);
    this.assert(back.length === 1, 'NS-09 批量还原数量');
    this.assert(back[0].id === 0, 'NS-09 id 按下标重排');
    this.assert(back[0].points.length === 3, 'NS-10 点位还原为 n 对');
    this.assert(back[0].points[0].x === 10.13 && back[0].points[0].y === 20.99, 'NS-10 坐标一致');
    this.assert(back[0].opacity === 0.4 && back[0].blendMode === 'multiply', 'NS-11 笔刷参数一致');
    this.assert(back[0].layerId === 'layer_draw', 'NS-11 layerId 一致');

    // 脏数据：奇数长度点位丢弃孤立分量
    const dirty: HCStroke = {
      id: 's_9', layerId: 'l1', tool: 'pen', color: '#000000', width: 3, opacity: 1,
      blendMode: 'normal', brushShape: 'round', texture: '', points: [1, 2, 3],
      createdAt: 0, createdBy: HC_LOCAL_AUTHOR,
    };
    const fixed: StrokeRecord = NoteSerializer.hcToStrokeRecord(dirty, 0);
    this.assert(fixed.points.length === 1, 'NS-12 奇数点位丢弃孤立分量');
    this.pass('StrokeMapping');
  }

  // ═══════════════════════════════════════════════════════════════
  // 五、插图映射（uri-only）
  // ═══════════════════════════════════════════════════════════════
  private testImageMapping(): void {
    const ref: ImageRefData = {
      id: 'image_ref_1', layerId: 'layer_draw', createdBy: HC_LOCAL_AUTHOR, createdAt: 1700000000000,
      imageHash: '', mimeType: 'image/png',
      x: 12.345, y: 23.456, width: 300.111, height: 300.999,
      binaryRef: '', uri: 'file://media/Photo/1/IMG_0001.jpg', rotation: 0, scale: 1,
    };
    const hc: HCImage = NoteSerializer.imageRefToHC(ref);
    this.assert(hc.uri === ref.uri, 'NI-01 uri 透传');
    this.assert(hc.x === 12.35 && hc.y === 23.46, 'NI-02 坐标量化');
    this.assert(hc.width === 300.11 && hc.height === 301, 'NI-02 尺寸量化');

    const back: ImageRefData[] = NoteSerializer.hcToImageRefs([hc]);
    this.assert(back.length === 1, 'NI-03 批量还原数量');
    this.assert(back[0].uri === ref.uri, 'NI-03 uri 往返一致');
    this.assert(back[0].layerId === ref.layerId, 'NI-03 layerId 往返一致');
    this.assert(back[0].binaryRef === '', 'NI-04 阶段一不内嵌二进制（U-4）');
    this.pass('ImageMapping');
  }

  // ═══════════════════════════════════════════════════════════════
  // 六、图层投影（S-3）
  // ═══════════════════════════════════════════════════════════════
  private testLayerProjection(): void {
    const lm: LayerManager = LayerManager.getInstance();
    lm.reset();
    const draw: Layer = lm.getLayers()[0];
    const paper: Layer = lm.createPaperLayer('底纸', 'grid');
    lm.moveDown(paper.id);

    const projected: HCLayer[] = NoteSerializer.projectLayers(lm.getLayers());
    this.assert(projected.length === lm.getLayers().length, 'NL-01 投影数量一致');

    const text: string = JSON.stringify(projected);
    this.assert(text.indexOf('offscreenCanvas') < 0, 'NL-02 剔除 offscreenCanvas（S-3 必须）');
    this.assert(text.length > 0, 'NL-02 投影可 JSON 序列化');

    let paperFound: boolean = false;
    let drawFound: boolean = false;
    for (let i = 0; i < projected.length; i++) {
      const l: HCLayer = projected[i];
      if (l.id === paper.id) {
        paperFound = true;
        this.assert(l.type === 'paper', 'NL-03 底纸层 type=paper');
        this.assert(l.paperTemplate === 'grid', 'NL-03 底纸层保留 paperTemplate');
      }
      if (l.id === draw.id) {
        drawFound = true;
        this.assert(l.type === 'draw', 'NL-04 绘制层 type=draw');
      }
      this.assert(l.opacity >= 0 && l.opacity <= 1, 'NL-05 opacity∈[0,1]');
    }
    this.assert(paperFound, 'NL-06 底纸层在投影中');
    this.assert(drawFound, 'NL-06 绘制层在投影中');

    // C-4 回归：兜底层必须是绘制层，不能是底纸层
    const fallback: string = NoteSerializer.pickDrawLayerId(lm.getLayers(), paper.id);
    this.assert(fallback === draw.id, 'NL-07 C-4 笔画兜底层 = 绘制层');
    lm.reset();
    this.pass('LayerProjection');
  }

  // ═══════════════════════════════════════════════════════════════
  // 七、序列化往返
  // ═══════════════════════════════════════════════════════════════
  private buildSampleContent(): NoteContent {
    const lm: LayerManager = LayerManager.getInstance();
    lm.reset();
    const draw: Layer = lm.getLayers()[0];
    const paper: Layer = lm.createPaperLayer('底纸', 'grid');
    lm.moveDown(paper.id);

    const meta: NoteMeta = createNoteMeta('note_1700000000000_abc123', '测试笔记', 'grid');
    meta.createdAt = 1700000000000;
    meta.updatedAt = 1700000001000;

    const records: StrokeRecord[] = [this.buildStroke(1, draw.id), this.buildStroke(2, draw.id)];
    const images: ImageRefData[] = [{
      id: 'image_ref_9', layerId: draw.id, createdBy: HC_LOCAL_AUTHOR, createdAt: 1700000000000,
      imageHash: '', mimeType: 'image/png', x: 1, y: 2, width: 300, height: 300,
      binaryRef: '', uri: 'file://media/Photo/9/IMG_9.jpg', rotation: 0, scale: 1,
    }];

    return NoteSerializer.composeContent(
      meta, 'grid', paper.id, lm.getLayers(), records, images, 1080, 1920, ''
    );
  }

  private testSerializeRoundTrip(): void {
    const content: NoteContent = this.buildSampleContent();
    const text: string = NoteSerializer.serialize(content);

    this.assert(text.indexOf(`"magic":"${HC_NOTE_MAGIC}"`) >= 0, 'NR-01 写入魔数');
    this.assert(text.indexOf(HC_CHECKSUM_PREFIX) >= 0, 'NR-02 写入校验和');
    this.assert(content.meta.sizeBytes === text.length, 'NR-03 真实体积回写内存');

    const result: NoteDeserializeResult = NoteSerializer.deserialize(text, 'fallback_id');
    this.assert(result.ok, 'NR-04 反序列化成功');
    this.assert(result.checksumMatched, 'NR-05 校验和自洽');
    this.assert(!result.migrated, 'NR-06 同版本不触发迁移');
    this.assert(result.fileSchemaVersion === HC_NOTE_SCHEMA_VERSION, 'NR-06 版本号一致');

    const back: NoteContent = result.content;
    this.assert(back.meta.id === content.meta.id, 'NR-07 id 一致');
    this.assert(back.meta.title === content.meta.title, 'NR-07 标题一致');
    this.assert(back.meta.createdAt === content.meta.createdAt, 'NR-07 createdAt 一致');
    this.assert(back.meta.paperTemplate === 'grid', 'NR-08 底纸一致');
    this.assert(back.paper.template === 'grid', 'NR-08 paper 段一致');
    this.assert(back.strokes.length === 2, 'NR-09 笔画数量一致');
    this.assert(back.meta.strokeCount === 2, 'NR-09 strokeCount 与实际一致');
    this.assert(back.images.length === 1, 'NR-10 插图数量一致');
    this.assert(back.canvasWidth === 1080 && back.canvasHeight === 1920, 'NR-11 画布尺寸一致');
    this.assert(back.forwardRaw === '', 'NR-12 同版本无前向数据');
    LayerManager.getInstance().reset();
    this.pass('SerializeRoundTrip');
  }

  /** A1-7：同一内容反复序列化必须字节完全相同 */
  private testIdempotent(): void {
    const content: NoteContent = this.buildSampleContent();
    const t1: string = NoteSerializer.serialize(content);
    const t2: string = NoteSerializer.serialize(content);
    this.assert(t1 === t2, 'NIdem-01 连续两次 serialize 字节相同');

    const parsed: NoteDeserializeResult = NoteSerializer.deserialize(t1, content.meta.id);
    const t3: string = NoteSerializer.serialize(parsed.content);
    this.assert(t1 === t3, 'NIdem-02 serialize→deserialize→serialize 字节相同（A1-7）');

    const parsed2: NoteDeserializeResult = NoteSerializer.deserialize(t3, content.meta.id);
    const t4: string = NoteSerializer.serialize(parsed2.content);
    this.assert(t3 === t4, 'NIdem-03 二次往返仍稳定');
    LayerManager.getInstance().reset();
    this.pass('Idempotent');
  }

  // ═══════════════════════════════════════════════════════════════
  // 八、容错（S-5：绝不抛异常、绝不返回 null）
  // ═══════════════════════════════════════════════════════════════
  private testCorrupted(): void {
    const empty: NoteDeserializeResult = NoteSerializer.deserialize('', 'note_fb_1');
    this.assert(!empty.ok, 'NE-01 空文本 ok=false');
    this.assert(empty.content !== null && empty.content !== undefined, 'NE-01 空文本仍返回内容');
    this.assert(empty.content.meta.id === 'note_fb_1', 'NE-01 使用兜底 id');
    this.assert(empty.errorMessage.length > 0, 'NE-01 带错误说明');

    const broken: NoteDeserializeResult = NoteSerializer.deserialize('{not json', 'note_fb_2');
    this.assert(!broken.ok, 'NE-02 非法 JSON ok=false');
    this.assert(broken.content.strokes.length === 0, 'NE-02 内容为空文档');

    const noMagic: NoteDeserializeResult = NoteSerializer.deserialize('{"schemaVersion":1}', 'note_fb_3');
    this.assert(!noMagic.ok, 'NE-03 缺魔数 ok=false');
    this.assert(noMagic.errorMessage.length > 0, 'NE-03 带错误说明');

    const wrongMagic: NoteDeserializeResult = NoteSerializer.deserialize('{"magic":"XXXX"}', 'note_fb_4');
    this.assert(!wrongMagic.ok, 'NE-04 魔数不匹配 ok=false');

    // 结构极简但魔数正确：应可用（字段全部走兜底）
    const minimal: NoteDeserializeResult =
      NoteSerializer.deserialize(`{"magic":"${HC_NOTE_MAGIC}","schemaVersion":${HC_NOTE_SCHEMA_VERSION}}`, 'note_fb_5');
    this.assert(minimal.ok, 'NE-05 最小合法文件可用');
    this.assert(minimal.content.meta.id === 'note_fb_5', 'NE-05 meta 缺失走兜底 id');
    this.assert(minimal.content.meta.title === '未命名笔记', 'NE-05 标题缺失走默认');
    this.assert(minimal.content.meta.paperTemplate === HC_DEFAULT_PAPER, 'NE-05 底纸缺失走 blank');
    this.pass('Corrupted');
  }

  // ═══════════════════════════════════════════════════════════════
  // 九、版本迁移与前向兼容（§2.8）
  // ═══════════════════════════════════════════════════════════════
  private testSchemaVersion(): void {
    // 低版本：迁移直通，不产生前向数据
    const oldText: string =
      `{"magic":"${HC_NOTE_MAGIC}","schemaVersion":0,"meta":{"id":"note_old","title":"旧档"},"strokes":[]}`;
    const oldResult: NoteDeserializeResult = NoteSerializer.deserialize(oldText, 'fb');
    this.assert(oldResult.ok, 'NV-01 低版本可读');
    this.assert(oldResult.migrated, 'NV-01 标记已迁移');
    this.assert(oldResult.fileSchemaVersion === 0, 'NV-01 记录原始版本');
    this.assert(oldResult.content.forwardRaw === '', 'NV-02 低版本无前向数据');
    this.assert(oldResult.content.meta.schemaVersion === HC_NOTE_SCHEMA_VERSION, 'NV-02 升级到当前版本');

    // 高版本：已知字段照读，全文原样保留
    const futureText: string =
      `{"magic":"${HC_NOTE_MAGIC}","schemaVersion":99,"meta":{"id":"note_future","title":"未来档"},` +
      `"paper":{"template":"dot"},"strokes":[],"layers":[],"images":[],"futureOnlyField":{"x":1}}`;
    const futureResult: NoteDeserializeResult = NoteSerializer.deserialize(futureText, 'fb');
    this.assert(futureResult.ok, 'NV-03 高版本可读');
    this.assert(futureResult.fileSchemaVersion === 99, 'NV-03 记录高版本号');
    this.assert(futureResult.content.forwardRaw === futureText, 'NV-04 前向兼容桶保留全文');
    this.assert(futureResult.content.meta.paperTemplate === 'dot', 'NV-04 已知字段正常解析');

    // migrate 桩：任何版本都不得丢字段（ArkTS 严格模式：结果显式断言为 HCNoteFileRaw）
    const raw = JSON.parse(futureText) as HCNoteFileRaw;
    const migrated = NoteSerializer.migrate(raw, 99);
    this.assert(migrated !== null && migrated !== undefined, 'NV-05 migrate 不返回空');
    this.pass('SchemaVersion');
  }

  // ═══════════════════════════════════════════════════════════════
  // 十、composeContent 组装
  // ═══════════════════════════════════════════════════════════════
  private testComposeContent(): void {
    const lm: LayerManager = LayerManager.getInstance();
    lm.reset();
    const draw: Layer = lm.getLayers()[0];
    const paper: Layer = lm.createPaperLayer('底纸', 'lined');
    lm.moveDown(paper.id);

    const meta: NoteMeta = createNoteMeta('note_compose_1', '组装测试', 'blank');
    // 传入非法模板：必须归一并写回 meta
    const orphanStroke: StrokeRecord = this.buildStroke(1, '');
    const content: NoteContent = NoteSerializer.composeContent(
      meta, 'not_a_template', paper.id, lm.getLayers(), [orphanStroke], [], 800.4, 600.6, 'RAW'
    );

    this.assert(content.paper.template === HC_DEFAULT_PAPER, 'NCC-01 非法模板降级 blank');
    this.assert(content.meta.paperTemplate === HC_DEFAULT_PAPER, 'NCC-01 归一结果写回 meta');
    this.assert(content.paper.layerId === paper.id, 'NCC-02 paper 段记录纸图层 id');
    this.assert(content.canvasWidth === 800 && content.canvasHeight === 601, 'NCC-03 画布尺寸取整');
    this.assert(content.forwardRaw === 'RAW', 'NCC-04 前向桶透传');
    this.assert(content.strokes.length === 1, 'NCC-05 笔画已投影');

    // C-4 回归：空 layerId 的笔画必须落到绘制层，绝不能挂到底纸层
    this.assert(content.strokes[0].layerId === draw.id, 'NCC-06 C-4 空 layerId 落到绘制层');
    this.assert(content.strokes[0].layerId !== paper.id, 'NCC-06 C-4 不得落到底纸层');
    lm.reset();
    this.pass('ComposeContent');
  }

  // ═══════════════════════════════════════════════════════════════
  // 十一、模型工厂与文案
  // ═══════════════════════════════════════════════════════════════
  private testModelFactory(): void {
    const id: string = createNoteId();
    this.assert(id.indexOf('note_') === 0, 'NM-01 id 前缀 note_');
    const parts: string[] = id.split('_');
    this.assert(parts.length === 3, 'NM-01 id 三段式');
    this.assert(parts[1].length === 13, 'NM-01 时间戳 13 位');
    this.assert(parts[2].length === 6, 'NM-01 随机后缀 6 位');
    this.assert(createNoteId() !== id, 'NM-02 连续生成不重复');

    this.assert(normalizeNoteTitle('  标题  ', '兜底') === '标题', 'NM-03 去首尾空白');
    this.assert(normalizeNoteTitle('   ', '兜底') === '兜底', 'NM-03 空标题走兜底');
    let long: string = '';
    for (let i = 0; i < 80; i++) {
      long += 'A';
    }
    this.assert(normalizeNoteTitle(long, '兜底').length === 60, 'NM-04 超长截断到 60');

    const meta: NoteMeta = createNoteMeta('note_x', '标题', 'grid');
    this.assert(meta.favorite === false, 'NM-05 阶段一收藏恒 false（U-7）');
    this.assert(meta.tags.length === 0, 'NM-05 tags 恒空');
    this.assert(meta.thumbRef === 'thumbs/note_x.txt', 'NM-05 缩略图路径约定');
    this.assert(meta.schemaVersion === HC_NOTE_SCHEMA_VERSION, 'NM-05 写入当前版本');

    const emptyContent: NoteContent = createEmptyNoteContent('note_y', '空档', 'dot');
    this.assert(emptyContent.strokes.length === 0, 'NM-06 空内容无笔画');
    this.assert(emptyContent.paper.template === 'dot', 'NM-06 空内容保留底纸');
    this.assert(emptyContent.viewport.scale === 1, 'NM-06 默认视口 scale=1');

    // U-2 三态文案 / 配色
    this.assert(noteSaveStateText(NoteSaveState.SAVING) === '保存中…', 'NM-07 保存中文案');
    this.assert(noteSaveStateText(NoteSaveState.SAVED) === '✓ 已保存', 'NM-07 已保存文案');
    this.assert(noteSaveStateText(NoteSaveState.FAILED).indexOf('重试') > 0, 'NM-07 失败文案含重试');
    this.assert(noteSaveStateText(NoteSaveState.IDLE) === '未保存', 'NM-07 空闲文案');
    this.assert(noteSaveStateColor(NoteSaveState.SAVED) !== noteSaveStateColor(NoteSaveState.FAILED), 'NM-08 成败配色不同');
    this.pass('ModelFactory');
  }

  // ═══════════════════════════════════════════════════════════════
  // 断言辅助
  // ═══════════════════════════════════════════════════════════════
  private assert(condition: boolean, message: string): void {
    this.assertions++;
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
    hilog.info(DOMAIN, TAG, '=== S1NoteTest Summary ===');
    hilog.info(DOMAIN, TAG,
      `Suites Passed: ${this.passed} | Failed: ${this.failed} | Assertions: ${this.assertions}`);
  }
}
