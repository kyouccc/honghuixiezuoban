# V2-Q1 pdf.js 栅格化可行性侦察报告

- 任务：V2-Q1 pdf.js 可行性侦察（PDFRasterizer 白底位图 → 真实内容栅格化）
- 执行：工程师 寇豆码
- 日期：2026-08-05（429 断线后重派）
- 纪律声明：**本报告只写文档，未触碰任何 .ets 源码**（QA t5 执行期间源码静止）。产物仅本 .md。
- 结论摘要（TL;DR）：
  1. **pdf.js 能在 ArkTS 上跑——但不是直引上游 pdfjs-dist，而是用 TPC 适配版 `@ohos/pdfjs`（已迁 CPF-ApplicationTPC，Apache-2.0，API10~12 验证过）或 vendor 源码二次适配**；核心剩余风险是「render → PixelMap 桥」与「文本/字体渲染在 ArkUI Canvas 子集上的行为」，均为未确证，需冒烟验证。
  2. **重大发现（重构了 Plan B 排序）**：本工程 `build-profile.json5` 显示 `runtimeOS: "HarmonyOS"`、`compatibleSdkVersion: "5.0.0(12)"`、`targetSdkVersion: "6.1.1(24)"`——是 **HarmonyOS NEXT 工程而非纯 OpenHarmony**。HarmonyOS NEXT 系统级 **PDF Kit（`@kit.PDFKit`，PDFium 内核，API 12+）** 原生提供 `pdfPage.getPagePixelMap() → image.PixelMap`，与 `ITextRasterizer.RasterizedPage.bitmap: PixelMap` **契约一字不差**，且零三方依赖（契合"全程零新增三方依赖"纪律）。→ **pdf.js 应从架构首选降级为备选/兜底，系统 PDF Kit 应升为 P0 验证主线**。

---

## 0. 侦察对象与平台事实

### 0.1 替换点
- `entry/src/main/ets/engine/document/PDFRasterizer.ets:132-135` `rasterizePageContent()` 目前 `createBlankBitmap` 产白底位图（P0 占位）。
- 文件头注释（:11-13）已预留替换点：pdf.js 接入只需替换该方法内部实现，接口 `ITextRasterizer` 不动。
- 契约：`RasterizedPage { index, width, height, bitmap: image.PixelMap | null }`；`RasterizeOptions { maxPages, scale, backgroundColor }`。

### 0.2 平台事实（决定性问题）
| 项 | 值 | 含义 |
|---|---|---|
| runtimeOS | **HarmonyOS**（非 OpenHarmony） | 商业 HarmonyOS NEXT，系统 PDF Kit 可用 |
| compatibleSdkVersion | 5.0.0(12) | **与 PDF Kit 的 API 12 起始版本精确对齐** |
| targetSdkVersion | 6.1.1(24) | 新版 SDK，能力只多不少 |
| 现有三方依赖 | `oh-package.json5` dependencies 为空 | 维持「零新增三方依赖」的现状基线 |

> 注意：任务背景说"OpenHarmony ArkTS"，但工程实际是 HarmonyOS NEXT。两者生态（尤其系统 PDF 能力）差异巨大，本报告以工程实测配置为准。

---

## Q1 pdfjs-dist 能否在 ArkTS 上运行 —— 逐条判定

判定符号：✅ 有/可行 ｜ ⚠️ 有条件可行 ｜ ❌ 无/不可行 ｜ ❓ 未确证

| # | 依赖项 | ArkTS 侧有无 | 替代方案 | 判定 | 证据 / 置信度 |
|---|---|---|---|---|---|
| 1 | **OffscreenCanvas / OffscreenCanvasRenderingContext2D** | ✅ 有：`OffscreenCanvas(w,h)` 构造 API8+；`getContext("2d")` API10+；`transferToImageBitmap()` 有 | 无替代，直接用；另有 **`getPixelMap(sx,sy,sw,sh)`**（华为官方架构指南「Canvas 图片绘制常见使用场景」场景三示例：`offContext.getPixelMap(0,0,w,h)` 直接得 `image.PixelMap`） | ✅ **主链路成立**：OffscreenCanvas 渲染 → getPixelMap → PixelMap，即 `rasterizePageContent` 需要的最终产物 | 华为开发者官网 + 架构指南，高 |
| 2 | **CanvasRenderingContext2D（部分 API）** | ✅ 有（Web Canvas API 的子集实现，API8+ 持续扩充） | 无（pdf.js 直接用它） | ⚠️ 子集覆盖是关键风险面：pdf.js 用到的 `putImageData`/`createImageData`/9 参 `drawImage`/`setTransform(DOMMatrix)`/渐变/Pattern/字体等是否逐项支持**未逐项核** | 官网组件文档，中；**具体缺口清单 ❓未确证** |
| 3 | **Path2D** | ✅ 有：ArkTS 组件级 `Path2D`（API9+，`rect/ellipse/moveTo/lineTo/...`） | 无 | ✅ | 华为 ArkUI Path2D 文档，高 |
| 4 | **DOMMatrix** | ❌ **无全局 DOMMatrix** | ① 画布 `Matrix2D`（`setTransform(matrix)`）；② `@ohos.graphics.drawing.Matrix`；③ 自写 6 元矩阵 | ⚠️ pdf.js display 层大量使用 DOMMatrix（viewport 变换/SVG 输出），**必须适配替换**。TPC 适配版已做此工作；自引上游需自改 | 华为 ArkUI Matrix2D / drawing.Matrix 文档，高；**适配细节 ❓未确证** |
| 5 | **Web Worker（pdf.worker.js）** | ⚠️ `@ohos.worker`（`worker.ThreadWorker`）有，但 **worker 脚本必须是 ets 目录下编译可见的文件**（`{moduleName}/ets/workers/...`），**不能直指 node_modules 的 pdf.worker.js** | pdf.js 自带主线程 fake-worker 降级（worker 不可用时在 main 线程执行 worker 代码） | ⚠️ 本项目是「逐页栅格化 ≤10 页、一次性出位图」场景，**主线程降级可接受**；渲染耗时/卡顿数值 ❓未确证（需冒烟实测） | @ohos.worker 官方文档 + pdf.js 机制，高；性能 ❓ |
| 6 | **fetch** | ✅ API12+ 有全局 fetch；`@ohos.net.http` 也有 | **本项目不需要**：走 `@ohos.file.fs` 读本地文件 → `Uint8Array` → `getDocument()`；pdf.js 的 network stream 仅 URL 加载才触发 | ✅ 非阻塞项 | 高 |
| 7 | **TextDecoder** | ✅ `util.TextDecoder`（`@ohos.util`）有 | 无 | ✅ 基础字符串解码够用；pdf.js 的其余编码细节由适配版处理 | 中；细节 ❓ |
| 8 | **TypedArray** | ✅ 标准 TypedArray 全家桶支持 | 无 | ✅ | 高 |
| 9 | **ArkTS 静态类型约束（no-any/禁止解构等）** | ⚠️ ArkTS 禁 `any/unknown`、名义类型、对象字面量必须标类型；但 **.js 模块可直接被 .ets import（JS 混编桥接，官方与社区均有实证）**；ESM npm 包可接入（社区案例 lodash/axios） | 对纯 JS 库：① 用 TPC 已适配包（类型已收拾好）；② vendor 源码 + 自己写 `declare` 声明；③ 直接 import .js（编译器桥接，但类型体验差） | ⚠️ **上游 pdfjs-dist 直引 = 高成本**（它的 JS 体量 + 动态类型会大面积触发 ArkTS 检查），**不建议**；推荐走适配版 | 华为开发者论坛 + 混编实战文章，高 |
| 10 | **打包链（ohpm/hvigor 吃 ESM）** | ⚠️ hvigor 可打包 npm/ohpm 的 ESM 包（有案例）；**现成适配案例 = TPC `@ohos/pdfjs`**（npm 分发，工程内即 pdf.js 的 core/display/shared 目录结构，API10~12 验证通过） | 用适配包 / vendor 源码（走 hvigor 正常编译路径） | ⚠️ **打包链可行性 = 有现成案例（确证）**；pdfjs-dist 上游包体积 ~1MB+ 对本工程 HAP 的影响、与当前 hvigor 版本兼容性 ❓未实测 | TPC gitee/gitcode 项目，高；本工程实测 ❓ |

### Q1 总判定
- **「pdf.js 能否在 ArkTS 上运行」= 能，但形态是「TPC 适配版 @ohos/pdfjs 或 vendor 源码二次适配」，不是上游 pdfjs-dist 直引。**
- TPC 适配版已被官方 TPC 组织在 API10 → API12（DevEco 4.0 → NEXT Beta1）多版本验证过展示链路，Apache-2.0，可放心作为技术底座。
- **三项未确证（决定成败，必须冒烟，见 Q4）**：
  1. `render()` 渲染到 ArkTS Canvas 后能否稳定导出像素（README 只明示 getDocument/getPage/getViewport 解析链路，**render→PixelMap 桥未在 README 明示**）——但架构指南已证明 OffscreenCanvasRenderingContext2D.getPixelMap 存在，桥大概率成立；
  2. 文本/字体渲染在 ArkUI Canvas 子集上的行为（PDF 内嵌字体 → 自绘字形路径 vs 系统字体 fillText 的差异）；
  3. 主线程逐页渲染耗时（影响 UX 是否可接受）。

---

## Q2 Plan B 按可行性排序（HarmonyOS NEXT / OpenHarmony 生态现实）

> 原任务给的 Plan B 候选：native PDF Kit（系统级）/ NAPI 封装 pdfium / 服务端栅格化 / 维持白底。按本工程实测平台（HarmonyOS NEXT API12+）重排如下。

### 1️⃣ 系统 PDF Kit（`@kit.PDFKit`，PDFium 内核）—— **P0 首选**
- **证据（官方文档 + 官方样例，高置信）**：
  - `pdfService.PdfDocument.loadDocument(filePath, password)` → `getPageCount()` → `getPage(index)` → **`page.getPagePixelMap() → Promise<image.PixelMap>`**（API 12+，即 5.0.0(12)，与本工程 compatibleSdkVersion 精确对齐）；
  - 另有 `getCustomPagePixelMap()`（支持区域翻转/XY 偏移/宽高/黑白/是否绘制批注）、`convertToImage()`（整本转图，每页一张）；
  - `pdfViewManager.PdfController` 提供预览组件（布局/缩放/滚动），与本需求无直接关系但证明能力成熟。
- **契合度**：产出即 `image.PixelMap`，与 `RasterizedPage.bitmap` 零转换；**零三方依赖**（系统能力，不违反"全程零新增三方依赖"纪律）；原生 PDFium 渲染，性能与兼容性最优。
- **前置条件**：需沙箱路径（官方 FAQ 明确"外部 PDF 必须先复制到 context.filesDir 再加载"）——导入管线需先落 filesDir（现有 DocSessionManager 已有文件落地逻辑，改动小）。
- **风险/未确证**：① 收费/授权模式（华为将其列为"闭源开放能力"，是否有商业计费 ❓未确证，需查证或按商务评估）；② 加密/损坏 PDF 的异常行为未验证；③ Table 设备支持未明示（文档标注 Phone/PC/2in1）。

### 2️⃣ @ohos/pdfjs（TPC 适配版）或 vendor pdf.js 源码 —— **次选（PDF Kit 不可用/受限时）**
- 证据：TPC pdfViewer 项目 API10~12 验证通过、Apache-2.0、最近仍维护（gitcode CPF-ApplicationTPC，1 个月前有提交）。
- 代价：① 新增三方依赖或 vendor ~1MB+ 源码，与"零三方依赖"纪律冲突（**需架构师裁决**）；② render→PixelMap 桥需自研（风险见 Q1）；③ 主线程渲染性能。
- 价值：作为 PDF Kit 之外的**独立渲染兜底**（某些 PDF Kit 不支持的畸形 PDF 可尝试 pdf.js）。

### 3️⃣ NAPI 封装 pdfium（自研）—— **远期，不建议近期投入**
- 证据：OpenHarmony-SIG 2026-06-30 会议刚批准新建 `third_party_pdfium` / `open_pdf_kit` 仓（归属 sig_basicsoftwareservice，**未毕业**）；社区 PdfKit（OpenHarmonyPCDeveloper/PdfKit）仅 1 commit，极早期。
- 代价：编译 pdfium + 平台适配 + NAPI 桥 + 像素导出，工程量最大；生态未成熟。**在系统 PDF Kit 已验证可用的前提下，本项无现实收益。**

### 4️⃣ 服务端栅格化 —— **兜底（逃逸舱），不作为主线**
- 可行性：高（任意客户端都能做），但引入网络依赖、隐私（文档内容外发）、服务器成本；与本地优先/离线批注的产品价值主张冲突。
- 适用：PDF Kit 与 pdf.js 都搞不定的极端 PDF（或未来跨端场景）时启用。

### 5️⃣ Web 组件内置 PDF 预览（web-pdf-preview）—— **否决（不兼容 ITextRasterizer）**
- Web 组件整页展示 PDF，**拿不到逐页 PixelMap**，无法作为 PageLayer 底图叠批注；除非把批注方案整体改为 Web 内嵌（架构级改动），不在本次范围。

### 6️⃣ 维持白底管线 —— **否决（非完成态）**
- 即现状：页数/尺寸对、能批注，但每页全白。团队已判定不可作为阶段二完成态。

**推荐路径**：P0 先冒烟验证系统 PDF Kit（Q4 方案 A）；通过 → 主线定为 PDF Kit（替换 `rasterizePageContent` 内部为 `loadDocument + getPagePixelMap`，接口不动）。PDF Kit 冒烟失败 → 立即转 @ohos/pdfjs 冒烟（Q4 方案 B），pdf.js 适配可行性同时落档闭环。

---

## Q3 对 ITextRasterizer 接口的影响（只提方案，架构师裁决）

> 现状：`rasterize(uri, options): Promise<RasterizedPage[]>` 一次性全页循环栅格化；`RasterizedPage.bitmap` 可空语义已存在。

| 关注点 | 现状问题 | 接口改动方案（不拍板） | 兼容性 |
|---|---|---|---|
| 异步/懒加载 | 长 PDF 全量栅格化耗时长、首屏慢 | ① 新增可选方法 `rasterizePage(uri, pageIndex, options): Promise<RasterizedPage>`（按需取页）；② 或 `rasterize` 增加回调 `onPageReady?: (page: RasterizedPage) => void`（首批 N 页即回、后台续栅格）；③ 免费版 10 页上限已天然限流 | ① 新增方法不破坏现有调用方；② 可选回调向后兼容 |
| 大文件内存 | PDF 全文 Uint8Array 一次性入内存（pdf.js 路径必然）；PDF Kit 路径由 native 管理、内存压力小 | `RasterizeOptions` 扩展可选字段：`maxConcurrentPages?: number`（并发栅格页数预算）、`maxBitmapPixels?: number`（单页位图像素上限，防 OOM） | 可选字段，旧调用方不传即默认值，向后兼容 |
| 取消/进度 | 无取消、无进度 | `RasterizeOptions` 扩展 `signal?: AbortSignal`、`onProgress?: (done: number, total: number) => void`；PDFRasterizer 内部检查 signal 中断循环 | 同上 |
| worker 化 | 主线程渲染（pdf.js 路径） | **对 ITextRasterizer 完全透明**：worker 与否是 PDFRasterizer 内部实现细节，接口不变 | 无 |
| 平台差异 | 本工程 runtimeOS=HarmonyOS；若未来要兼容纯 OpenHarmony，PDF Kit 不可用 | 建议 ITextRasterizer 保持平台无关；平台能力探测放 PDFRasterizer 内部（`canUseSystemPdfKit()` → 用 PDF Kit，否则回退 pdf.js） | 无 |

**需要架构师裁决的两个决策点**：
1. 「全程零新增三方依赖」纪律 vs pdf.js vendor 方案（若 PDF Kit 冒烟失败才触发；TPC 包是 ohpm 依赖、vendor 是进仓源码，两者都算引入第三方代码，只是形态不同）；
2. 是否采纳「PDF Kit 主线 + pdf.js 兜底」双引擎分层（多一套兜底 = 多一份维护成本，是否值得）。

---

## Q4 最小验证路径（冒烟）

> 目标：**比全量接入早 10 倍暴露风险**。两个冒烟都建议在**独立 scratch 工程**跑（不污染主工程、不违反 t5 执行期源码静止纪律）；若必须在主工程验证，需 team-lead 批准新增临时 Page。

### 方案 A：系统 PDF Kit → PixelMap（推荐，P0 主线，约半天）
1. scratch 工程（API12+，Stage 模型）；
2. 用任意含文字/矢量/图片的 PDF（≤3 页）放入 `context.filesDir`；
3. 代码路径（伪码，只作方案示意）：
   ```ts
   import { pdfService } from '@kit.PDFKit';
   const doc = new pdfService.PdfDocument();
   doc.loadDocument(filePath, '');          // 沙箱路径
   const page = doc.getPage(0);
   const pixelMap: image.PixelMap = await page.getPagePixelMap();
   // 采样像素：非全白即通过；Image(pixelMap) 目检文字/矢量可辨
   ```
4. 判定标准：`getPagePixelMap` 返回非空 PixelMap；采样像素**非全白**；目检文字/图形清晰；记录单页耗时。
5. 暴露风险：PDF Kit API 可用性、沙箱路径前置、授权/异常行为——全链路最小闭环。

### 方案 B：@ohos/pdfjs → render → PixelMap（Q1 闭环，约半天）
1. scratch 工程（API10+ 即可）安装 `@ohos/pdfjs`（npm 分发；或直接从 CPF-ApplicationTPC/pdfViewer 的 pdfJs 目录 vendor）；
2. 代码路径（伪码）：
   ```ts
   import { getDocument } from '@ohos/pdfjs';
   const loadingTask = getDocument({ data: pdfBytes as Uint8Array });  // 本地文件字节
   const pdf = await loadingTask.promise;
   const page = await pdf.getPage(1);
   const viewport = page.getViewport({ scale: options.scale });
   const offCanvas = new OffscreenCanvas(viewport.width, viewport.height);
   const ctx = offCanvas.getContext('2d', settings);
   await page.render({ canvasContext: ctx, viewport }).promise;
   const pixelMap = ctx.getPixelMap(0, 0, viewport.width, viewport.height);
   ```
3. 判定标准：同上（非全白 + 目检 + 单页耗时）；**若此步通过，Q1 的三项未确证全部闭环**。
4. 附加记录：主线程渲染耗时、worker 降级是否触发、字体渲染是否有乱码/缺字。

### 建议
- **A 通过 → 主线定为系统 PDF Kit**，pdf.js 冒烟（B）可降级为可选（纯留档，确认兜底可用）。
- **A 失败 → B 立即执行**，作为 Q1 的最终硬证据。
- 两个冒烟合计 ≤1 天，投入产出比远高于直接全量接入后才发现平台不兼容。

---

## 证据附录

### 已确证（来源）
1. **系统 PDF Kit 存在且 API12+**：华为开发者官网 PDF Kit 文档（pdfViewManager / pdfService：`getPagePixelMap`、`getCustomPagePixelMap`、`convertToImage`，起始版本 5.0.0(12)）；官方架构指南「PDF Kit 提供的 PDF 转图片的多个 API 有什么区别」；51CTO 官方样例（`import { pdfService, pdfViewManager } from '@kit.PDFKit'`）。
2. **OffscreenCanvas + getPixelMap 桥**：华为官方「Canvas 图片绘制的常见使用场景」场景三（`offContext.getPixelMap(0,0,w,h)` → PixelMap → ImagePacker）。
3. **Path2D / Matrix2D / drawing.Matrix**：华为 ArkUI 组件文档。
4. **@ohos.worker 存在但脚本须 ets 目录编译可见**：@ohos.worker 官方文档 + 社区实战（路径规则 `{moduleName}/ets/workers/...`）。
5. **ArkTS 可 import .js 模块 / ESM npm 包可接入**：华为开发者论坛「JS 到 ArkTS 的适配」+ 混编实战（lodash/axios 案例）。
6. **TPC pdfViewer（@ohos/pdfjs）**：gitee openharmony-tpc/pdfViewer（已归档）→ gitcode CPF-ApplicationTPC/pdfViewer；API10~12 验证、Apache-2.0、pdf.js 的 core/display/shared 结构。
7. **pdfium 进 OpenHarmony-SIG**：OpenHarmony 架构 SIG 第 215 次会议纪要（2026-06-30，批准 third_party_pdfium/open_pdf_kit 建仓，未毕业）。

### 未确证（诚实清单）
1. `@ohos/pdfjs` 基于的上游 pdf.js 版本号（gitee 子 README 被验证码拦截，gitcode 页面未展开子 README）→ 冒烟 B 顺带记录。
2. `@ohos/pdfjs` 的 `render()` → 像素导出桥是否现成可用（README 未明示；OffscreenCanvas.getPixelMap 的存在性已确证，桥大概率可自建）。
3. ArkUI CanvasRenderingContext2D 相对 Web Canvas 的具体缺口清单（putImageData/createImageData/9 参 drawImage/字体等逐项差异）。
4. 主线程 pdf.js 逐页渲染耗时（真机/模拟器数据）。
5. 系统 PDF Kit 的收费/授权模式（"闭源开放能力"是否计费）。
6. 上游 pdfjs-dist（非适配版）在当前 hvigor/DevEco 版本下的直接打包兼容性与 HAP 体积增量。
7. 系统 PDF Kit 对加密/损坏/超大 PDF 的异常行为。

### 结论一句话
**Q1：pdf.js 在 ArkTS 上能跑（走 TPC 适配版/vendor 二次适配，非上游直引），三项未确证需冒烟闭环；但本工程是 HarmonyOS NEXT API12+，系统 PDF Kit 原生产出 PixelMap、零三方依赖、契约完全对齐，应作为 P0 主线，pdf.js 降为兜底。**
