# DevEco Studio 验证指令（交付 GLM-5 执行）

> 复制本文件全文，粘贴给 DevEco Studio 内置 AI（GLM-5）执行。
> 目标项目：鸿绘协作板（OpenHarmony ArkTS 笔记应用）

## 项目定位
- 根目录：`C:\Users\27968\WorkBuddy\2026-08-03-10-35-19\honghui`
- 第一步：打开该项目，等 Sync 完成（File → Sync / 自动触发）

## 任务总目标
对项目做「Previewer/构建环境可达到的最大验证」，覆盖 V1~V6，输出验证报告并落盘。

## 验证清单

### V1 编译检查（最高优先，本项目全程未跑过真机构建）
执行构建：Build → Build Hap(s)/App(s)，或命令行 `hvigorw assembleHap`（在项目根目录）。
- 报告：构建成功 / 失败；失败则逐条列出错误（文件:行号 + 错误信息），不修复
- 若构建成功：启动 Previewer，确认 Index 首页能渲染，点进 NotePage / WhiteboardPage 不白屏
- 重点关注模块：entryability、pages/ 全部页面、engine/（含 document/、memory/、crdt/）、common/services/ExportService

### V2 PDF Kit 冒烟（读方向，T2-1 遗留 P0 的验收前置）
验证系统 `@kit.PDFKit`（API 12+）读方向：`PdfDocument.loadDocument → getPage(0) → getPagePixelMap() → image.PixelMap`
- 前置：准备一个 1~2 页测试 PDF（可用任意 PDF 文件放入项目临时目录）
- 最小验证：PDF 复制到 `filesDir` → loadDocument → 取第 0 页 PixelMap → 采样像素非全白 + 目检文字可辨
- 相关代码：`entry/src/main/ets/engine/document/PDFRasterizer.ets`（:132 `rasterizePageContent` 为替换点）、`ITextRasterizer.ets`（契约 bitmap: PixelMap）
- **重要**：若 Previewer 不支持系统 PDF Kit（预期大概率不支持），明确报告「Previewer 不支持 @kit.PDFKit，需模拟器/真机」，并降级为**代码路径审查**：核对 PDFRasterizer 的 PDF 解析逻辑（签名校验/MediaBox/页数）与 PDF Kit 官方 API 调用方式是否一致，给出替换点改造建议（只写建议，不改代码）
- 输出：✅ 可行（附像素/截图证据）/ ⚠️ Previewer 不支持（附降级审查结论）

### V3 压感事件（A2-3）
验证 `entry/src/main/ets/engine/PressureSampler.ets` 压感路径：`TouchEvent.getHistoricalPoints().force` 与当前触点 `force`。
- Previewer 通常无压感数据 → 重点验证**速度模拟回退路径**（无 force 时 estimateVelocityPressure 输出连续、无跳变）
- 输出：force 是否可得 + 回退路径表现（逻辑层已 Node 验证 45 项，这里确认真机侧事件 API 行为）

### V4 导出 PDF 可打开性（A2-7a）
- 若 V2 可行（代码能跑）：调 `common/services/ExportService.ets` 的 `exportBitmapsToPDF` 产出一个测试 PDF，用系统阅读器/Previewer 打开确认可读
- 若不可行：重点确认 `Canvas.toDataURL('image/jpeg')` 在 Previewer/真机 ArkUI 是否可用（JPEG 参数）；手写 PDF 容器结构（%PDF-1.4/xref/startxref/%%EOF/DCTDecode）代码层已 Node 验证 45 项，不需重验

### V5 跨端双设备（A-T25-8）
- Previewer 单窗口，**双设备 op 收敛无法验证**——明确标注「需两台设备/模拟器」
- 可验证：单端 `engine/CrdtSessionRegistry.ets` 的 acquire/release 生命周期、oplog 落盘读回

### V6 闪卡/导图/贴纸 UI（A2-4/A2-5）
- Previewer 打开 FlashcardPage / MindMapPage 入口，目检渲染与基本交互（翻卡、导图节点显示、贴纸插入）
- 输出：可交互 / 仅渲染 / 崩溃（附截图）

## 输出要求
1. 报告落盘：`C:\Users\27968\WorkBuddy\2026-08-03-10-35-19\honghui\docs\device-verify-report.md`
2. 每项格式：「结论（✅/⚠️/❌）+ 方法 + 证据 + 阻塞项」
3. 纪律：
   - **只验证，不改源码**（所有功能批次在验收中，源码须静止；发现编译错误只报告「文件:行号+错误信息」，不自行修复）
   - 诚实标注「Previewer 不支持 X」，不尝试绕过
   - 每项给「当前环境能做到的最大验证」
   - 报告写完才算完成（先落盘）
4. 若项目在 Previewer 完全无法运行（构建失败），仍要输出报告：构建错误清单 + 修复建议（只建议不代改）
