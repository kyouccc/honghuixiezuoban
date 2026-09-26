# Honghui v2.0 阶段一（S1T01~S1T03）QA 测试说明

> 作者：严过关（QA）· 2026-08-04
> 验证对象：`entry/src/main/ets/engine/` 下 BrushRegistry / PaperLayerRenderer / TextBlockTool /
> document（ITextRasterizer / PDFRasterizer / DocumentImporter）/ types/CanvasElement，
> 以及修改的 LayerManager / StrokeEngine / ShapeTool / ImageManager / CRDTOp / Constants

## 1. 验证方式

工程现有测试基建为**手写测试类**（`entry/src/main/ets/tests/RGAEngineTest.ets`，hilog 输出，
无标准 ohosTest 框架）。本次沿用该模式新增：

| 文件 | 类型 | 说明 |
|------|------|------|
| `entry/src/main/ets/tests/S1CoreTest.ets` | ArkTS 测试类（工程内可集成） | 与 v1 RGAEngineTest 同模式；在 `EntryAbility.onWindowStageCreate` 调用 `new S1CoreTest().runAll()` 执行 |
| `tests/ets-loader.mjs` | Node loader | 将 ArkTS(.ets) 按 TypeScript 转译运行，mock 鸿蒙 SDK 模块（@kit/@ohos），供本地逻辑验证 |
| `tests/run-node-verify.mjs` | Node 运行验证脚本 | 直接运行真实 .ets 源文件，207 条断言 |

**运行方式（Node ≥22.7，需 --experimental-transform-types）：**

```bash
cd honghui/tests
node --experimental-transform-types --experimental-loader=./ets-loader.mjs run-node-verify.mjs
```

## 2. 运行验证结果（2026-08-04）

**Round 1**（首轮）：`Total: 207 | Passed: 207 | Failed: 0`

**Round 2**（工程师修复 E-1/E-2/E-3 后回归）：`Total: 217 | Passed: 216 | Failed: 1`
- 原 207 断言全部保持通过（无回归）；
- E-2 专项（4 用例）：缺 refDocId / refDocId 空串 / pageIndex 负数 → 被 `LayerManager.addElement` 拒绝；合法 annotation 正常写入 ✅
- E-3 专项（3 用例）：经 DocumentImporter 无 backgroundColor → 位图非 null ✅；
  **PDFRasterizer 直连（不经 DocumentImporter）无 backgroundColor → 位图 null ❌（新增发现 E-3b，建议在 rasterize 内兜底）**
- 遗留边界：缺 pageIndex 的畸形对象在判别层落入默认 stroke 分支（E2-05 观察，低危）

覆盖清单：

- **BrushRegistry**（BR-01~09）：6 笔刷配置完整；压感曲线端点/线性插值/clamp；未知笔型回退钢笔；配置副本防篡改
- **CanvasElement**（CE-01~07）：5 类元素结构判别（stroke/shape/text_block/annotation/image_ref）；含 points 的 annotation 不被误判为 stroke
- **LayerManager**（LM-01~14）：paper/page 只读语义（写元素被拒）；addElement 统一分派；mergeLayers 元素引用迁移（id 保留、layerId 更新、源删除）；duplicateLayer 全新 id；group/ungroup；exportLayer 快照；getElements 过滤 deleted
- **TextBlockTool**（TB-01~08）：创建/编辑/位置；字号 clamp [8,120]；非法 align 忽略；不可变语义
- **CRDTOp**（CR-01~08）：getElementTypeOfOp 判别与回退；deserializeNodeID 输入验证；compareNodeIds/serializeNodeID
- **PaperLayerRenderer**（PP-01~07）：5 种底纸模板；isSupported；renderPaper 边界（0/负/null ctx 不抛异常）；未知模板回退
- **PDFRasterizer**（PDF-01~10）：.caj 降级（code 1105 + 提示）；无效 PDF 抛错；免费版 10 页上限（PDF_FREE_PAGE_LIMIT）；maxPages 截断；MediaBox 尺寸解析；返回结构完整
- **DocumentImporter**（DI-01~10）：类型识别（pdf/epub/caj/unknown）；未知/CAJ/EPUB 错误路径；PDF 导入编排（DocMeta 结构、PageLayer 创建与 pageRef 绑定、PageLayer 只读）；getPageBitmap/getDocPageCount/clearDoc

## 3. 边界观察（非失败项，已记入 QA 报告）

- 畸形 Annotation（缺 pageIndex/refDocId）经 `getCanvasElementType` 判别会落入默认 stroke 分支；
  架构 §8.1 约定 5 要求"无效元素拒绝入 RGA"——建议工程师在 `LayerManager.addElement` 补校验。
- `DocumentImporter.normalizeOptions` 对缺 backgroundColor 的部分 options 会透传 undefined，
  `PDFRasterizer.createBlankBitmap` 内部捕获后返回 null 位图（不崩溃，但页面位图丢失）。

## 4. 与工程构建的关系

- 以上 Node 验证证明**引擎层逻辑可执行且断言通过**；
- **ArkTS 完整编译（类型检查/严格模式）仍需在 DevEco/hvigor 执行完整构建确认**：
  当前 `entry/build` 与 `.preview` 的 CompileArkTS 产物中**不含任何新文件**
  （BrushRegistry/PaperLayerRenderer/TextBlockTool/CanvasElement/PDFRasterizer/DocumentImporter/ITextRasterizer），
  即最近一次完整构建未包含本次新增代码。
