# 鸿绘协作板 · 上架前差距清单 v3.1

> **基线**：2026-08-21 代码 ｜ **对照**：v3.0 报告（2026-08-08）  
> **结论**：功能 +0.8，就绪度 −2.2 —— 补了 6 块真功能，引入 2 个审核级阻断

---

## 0. Delta 摘览：v3.0 → v3.1

| 维度 | v3.0 | v3.1 | 变化 | 原因 |
|------|------|------|------|------|
| 功能完成度 | 7.2 | **8.0** | ▲ +0.8 | PDF 批注 / 主题 / 隐私 / 协作加入 / 设备管理 / 崩溃恢复 全部落地 |
| 上架就绪度 | 7.2 | **5.0** | ▼ −2.2 | 暗色模式假装修 + 导航双轨冲突，两个新 P0 |

### v3.0 建议落地追踪

| v3.0 建议 | 优先级 | 状态 | 依据 |
|-----------|--------|------|------|
| 暗色模式 | P0 | ⚠️ **资源有 / 接线缺** | `dark/element/color.json` 28 键齐全；但 605 处硬编码 hex，`$r()` 引用 0 处 |
| 设计令牌 + 矢量图标 | P0 | ✅ 已落地 | `DesignTokens.ets` / `IconComponent.ets` / `BackButton.ets` |
| PDF 真实渲染 | P0 | ✅ 已落地 | `PDFRasterizer` + 能力降级 |
| PDF 批注页 | P0 | ✅ 已落地 | `AnnotationPage.ets` 三层画布 + 每页笔迹强绑 |
| 全文搜索 | P0 | ✅ 已落地 | `NoteSearchService` 接入笔记列表 |
| 导出完整落盘 | P0 | ✅ 已落地 | `ExportService.saveToFile`，PNG 二进制分支修复 |
| 崩溃兜底 / 自动保存 | P0 | ✅ 已落地 | `CrashRecoveryService` + `EmergencySaveService` |
| 隐私合规清零 | P0 | ✅ 已落地 | `PrivacyPage.ets` + `PermissionManager.ets` |
| 底部导航骨架 | U-01 | ⚠️ **半残** | Tab 存在但「协作 / 我的」= placeholder toast；与 Index 卡片导航双轨冲突 |
| CRDT 协同接线 | P1 | 🔶 展示壳 | `JoinRoomPage` 真联网但画布无 `broadcastRemoteOp` / `applyRemoteOp` |
| 华为账号 + 云同步 | P1 | ❌ 缺失 | 无 Account Kit、无云端存储 |
| 收藏 / 闪卡 / 导图 | P2 | ❓ 可达性存疑 | Service 在但入口置灰或可达性未验证 |

---

## 1. 🔴 P0 阻断 — 不修不过审

### P0-A：暗色模式 = 假装修

| | |
|---|---|
| **现象** | `dark/element/color.json` 28 个语义键齐全且值正确，但全代码 605 处仍用 `HCColor.*` 硬编码浅色 hex。`$r('app.color…')` 引用 **0 处**。系统切深色 → UI 纹丝不动。 |
| **佐证** | `ThemeSettingsPage.ets` 出现 `this.isDarkMode ? HCColor.PAGE_BG : HCColor.PAGE_BG` — 两边相同的三元 = 空操作 |
| **审核风险** | 2026 元服务「深色模式显示异常」驳回点 — **提交即被打回** |
| **根因** | `DesignTokens.HCColor` 字段返回 hex string 而非 `$r()` 资源引用，base/dark 同名键自动替换机制未被激活 |

**修复路径（改 1 处 vs 改 605 处）：**

```
DesignTokens.ets  HCColor.* 字段
  BEFORE:  static readonly PRIMARY: string = '#007DFF'
  AFTER:   static readonly PRIMARY: Resource = $r('app.color.hc_primary')
  
  映射规则: 字段名 → hc_ + 全小写
  类型变更: string → Resource | string
```

- ✅ 605 处调用点零改动
- ✅ base/dark 同名键自动切换
- ✅ 浅色模式值不变（base 已有 26 个 `hc_*` 键）
- ⚠️ 排查把 `HCColor.X` 用于字符串拼接 / Canvas 2D `fillStyle` 的位置（需改用 `HCPrimary` / `HCGray` 原始常量）
- ⚠️ 字段类型 `string → Resource` 后，`@Prop` / 函数返回值 / 数组类型需同步放宽到 `ResourceColor`

**验收标准（DoD）：**
1. DevEco 切系统深色模式，逐页核对：白板 / 笔记列表 / 批注 / 设置 / 隐私 / 对话框
2. 全页面背景变深、文字变亮、无残留白底
3. 切回浅色模式无异常

---

### P0-B：导航双轨冲突

| | |
|---|---|
| **现象** | `BottomTabBar` 三 Tab：「协作」「我的」= `placeholder: true`，点击只弹 toast。但 `Index.ets` 本身就是「我的」页，用卡片链到 `JoinRoomPage` / `DeviceManagePage` / `PrivacyPage` / `ThemeSettingsPage` — 这些页已真实写好。 |
| **矛盾** | 底部「协作」永远进不去（toast），「我的」卡片里却能进 `JoinRoomPage` — 两套导航范式并存，用户认知混乱 |
| **用户伤害** | 点不动 = 死路 = 信任崩塌 |

**修复路径（推荐 A）：**

| 方案 | 做法 | 优劣 |
|------|------|------|
| **A（推荐）** | 底部 Tab 直跳真实页：协作 → `JoinRoomPage`；我的 → 整合页（主题 / 隐私 / 设备 / 关于）；删除 Index 冗余卡片 | 消除双入口，所见即所得 |
| B | 底部 Tab 只留「笔记」一个真入口，另两个整体隐藏 | 最快，但浪费已写好的页面 |

**验收标准（DoD）：**
1. 底部每个 Tab 点击都能进入真实页面，无 toast 占位
2. 无两个入口指向同一页面
3. 主链路「笔记 → 白板 → 返回」无死循环

---

## 2. 🟠 P1 重要 — 影响口碑与增长

### P1-A：协同是展示壳

| | |
|---|---|
| **现状** | `JoinRoomPage` 调 `RoomAPI.joinRoom` 真联网、`DeviceManagePage` 用 `DeviceDiscovery` 真发现设备 |
| **缺口** | `WhiteboardPage` 未接 CRDT 同步管道（无 `broadcastRemoteOp` / `applyRemoteOp` / RGA）；`CollabStatusService` 仅显示本地态 |
| **风险** | 用户「加入房间」后画布不动 → 预期落差 → 差评 |

**建议：** 上架版本把协同标为「即将上线 / 内测」，用真实进度填充 `CollabStatusService` 状态文案。真同步作为 2.0 独立发布事件。

### P1-B：华为账号 + 云同步缺失

无 Account Kit、无云端存储。这是元服务账号合规红利（无需自建账号）的最大落地点，也是「多端接续」核心抓手。需在 2.0 路线占坑。

### P1-C：编译未验证

08-21 新增 5 页 + 复杂引用关系（`CollabStatusService` / `DeviceDiscovery` / `RoleAssigner` / `PDFAnnotationWriter` / `DocSessionManager` 互引），极可能存在编译错误。

**建议：** 上架前第一件事 — `hvigorw assembleHap`，编译错误清零。

---

## 3. 🟡 P2 打磨项

| 项 | 现状 | 动作 |
|----|------|------|
| 收藏 Tab | 置灰可点 | 接 `FavoriteService` 持久化 或 隐藏，不要「灰着可点」误导 |
| 闪卡 / 导图入口 | 页存在，可达性待确认 | 从笔记列表 flash/mind 筛选 Tab 验证；不可达则补入口 |
| 权限裁剪 | 声明 INTERNET / DISTRIBUTED_DATASYNC / READ_WRITE_MEDIA | 协同未真同步时 DISTRIBUTED_DATASYNC 可能触发「单机联网」质疑；按实际裁剪 |
| 隐私政策外链 | 仅应用内 PrivacyPage | 上架需在应用市场 listing 填公网可访问的隐私政策 URL |

---

## 4. 两周冲刺排程

```
Week 1                          Week 2
─────────────────────────       ─────────────────────────
D1  编译清零 (前提)              D8  打磨: 收藏/闪卡/导图入口
D2  ┐                           D9  打磨: 图标收尾/空状态补全
D3  ┘ 暗色模式接线 (P0-A)        D10 真机回归: 主链路 × 浅/深双主题
D4  导航统一 (P0-B)              D11 ┐
D5  ┐                           D12 ┘ 上架材料: 截图/描述/隐私URL
D6  ┘ 协同如实化 (P1-A)          D13 ┐
D7  权限+隐私合规 (P1-C/P2)      D14 ┘ 缓冲: 审核反馈 + 2.0 素材
```

---

## 5. 如果只做三件事

| 序号 | 事项 | 理由 | 就绪度影响 |
|------|------|------|-----------|
| ① | **编译清零** | 一切白搭的前提 | 0 → 可构建 |
| ② | **暗色模式接线** | 审核硬门槛 | 消除头号驳回风险 |
| ③ | **导航统一** | 首屏可用性 | 半残 → 完整 |

> 三件做完，上架就绪度 **5.0 → 8.0+**

---

*v3.1 · 2026-08-21 代码基线 · 对照 v3.0 报告*
