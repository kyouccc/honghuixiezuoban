# 图标系统迁移指南

**创建日期**: 2026-08-08  
**目标**: 将Emoji图标迁移到HarmonyOS SymbolGlyph系统图标

---

## 一、迁移背景

### 当前问题

项目中大量使用Emoji字符作为图标（如✏、🧹、⬜等），存在以下问题：

1. **视觉不一致**: Emoji在不同设备上渲染差异大
2. **无法适配深色模式**: Emoji颜色固定，无法自动适配主题
3. **专业性不足**: 缺乏统一的视觉语言
4. **可访问性差**: 屏幕阅读器支持不佳

### 解决方案

使用HarmonyOS内置的SymbolGlyph图标系统：

- ✅ 自动适配深色模式
- ✅ 统一的视觉风格
- ✅ 多尺寸支持
- ✅ 符合HarmonyOS设计规范
- ✅ 零资源文件依赖

---

## 二、迁移步骤

### 步骤1: 导入图标常量

```typescript
// 在文件顶部添加导入
import { IconSymbols, IconSize, IconColor, CommonIcons } from '../common/IconConstants';
import { IconUtils } from '../common/components/IconComponent';
```

### 步骤2: 替换工具栏图标

**修改前**（使用Emoji）:
```typescript
Button('✏')
  .fontSize(20)
  .width(48)
  .height(48)
```

**修改后**（使用SymbolGlyph）:
```typescript
SymbolGlyph($r('sys.symbol.' + IconSymbols.PEN))
  .fontSize(IconSize.STANDARD)
  .fontColor(this.currentTool === 'pen' ? IconColor.ACTIVE : IconColor.INACTIVE)
```

### 步骤3: 替换文本中的图标

**修改前**:
```typescript
Text('🎨 贴纸库')
```

**修改后**:
```typescript
Row() {
  SymbolGlyph($r('sys.symbol.' + IconSymbols.STICKER))
    .fontSize(IconSize.COMPACT)
    .fontColor(IconColor.SECONDARY)
  Text('贴纸库')
    .fontSize(14)
}
```

---

## 三、图标映射表

### 绘图工具

| Emoji | SymbolGlyph | 说明 |
|-------|-------------|------|
| ✏ | edit | 画笔 |
| 🧹 | eraser | 橡皮擦 |
| 🖌 | brush | 笔刷 |
| ⬜ | shape | 形状 |
| 📏 | ruler | 尺子 |

### 内容类型

| Emoji | SymbolGlyph | 说明 |
|-------|-------------|------|
| 📷 | image | 图片 |
| 📝 | text | 文本 |
| 🎨 | emoji | 贴纸/表情 |

### 操作按钮

| Emoji | SymbolGlyph | 说明 |
|-------|-------------|------|
| 🗑️ | delete | 删除 |
| ⚙️ | settings | 设置 |
| 🔍 | search | 搜索 |
| ↩ | undo | 撤销 |
| ↪ | redo | 重做 |

### 导航图标

| Emoji | SymbolGlyph | 说明 |
|-------|-------------|------|
| ← | arrowLeft | 返回 |
| ✕ | close | 关闭 |
| ☰ | menu | 菜单 |
| ⋯ | more | 更多 |

---

## 四、实施计划

### 阶段1: 核心工具栏（优先级P0）

**文件**: `WhiteboardPage.ets`

**修改位置**:
- Line 2037-2045: 手机竖屏工具栏
- Line 2138-2140: 平板工具栏
- Line 2245-2270: 工具按钮组

**预期收益**:
- 提升核心工具的专业感
- 改善深色模式体验
- 统一视觉语言

### 阶段2: 辅助功能（优先级P1）

**修改位置**:
- 更多菜单中的图标
- 设置页面的图标
- 状态指示图标

### 阶段3: 全面迁移（优先级P2）

**修改位置**:
- 所有文本中的图标
- 空状态图标
- 导航图标

---

## 五、代码示例

### 示例1: 工具栏按钮

```typescript
@Builder buildToolBtn(tool: string, symbolName: string) {
  Column() {
    SymbolGlyph($r('sys.symbol.' + symbolName))
      .fontSize(IconSize.STANDARD)
      .fontColor(this.currentTool === tool ? IconColor.ACTIVE : IconColor.INACTIVE)
  }
  .width(48)
  .height(48)
  .borderRadius(8)
  .backgroundColor(this.currentTool === tool ? '#E6F2FF' : '#F5F5F5')
  .onClick(() => {
    this.currentTool = tool;
  })
}
```

### 示例2: 带文本的图标

```typescript
@Builder buildIconText(symbol: string, text: string) {
  Row({ space: 8 }) {
    SymbolGlyph($r('sys.symbol.' + symbol))
      .fontSize(IconSize.COMPACT)
      .fontColor(IconColor.SECONDARY)
    
    Text(text)
      .fontSize(14)
      .fontColor('#333333')
  }
}
```

### 示例3: 状态图标

```typescript
@Builder buildStatusIcon(type: 'success' | 'warning' | 'error') {
  const config = {
    success: { symbol: IconSymbols.SUCCESS, color: IconColor.SUCCESS },
    warning: { symbol: IconSymbols.WARNING, color: IconColor.WARNING },
    error: { symbol: IconSymbols.ERROR, color: IconColor.ERROR }
  };
  
  SymbolGlyph($r('sys.symbol.' + config[type].symbol))
    .fontSize(IconSize.STANDARD)
    .fontColor(config[type].color)
}
```

---

## 六、注意事项

### 1. 兼容性检查

SymbolGlyph需要API Version 11+，建议添加版本检查：

```typescript
if (canIUse('SystemCapability.ArkUI.ArkUI.Full')) {
  // 使用SymbolGlyph
} else {
  // 降级到Emoji
}
```

### 2. 深色模式适配

SymbolGlyph会自动适配深色模式，无需额外处理：

```typescript
// 自动适配深色模式
SymbolGlyph($r('sys.symbol.edit'))
  .fontSize(24)
  // 无需设置fontColor，系统自动处理
```

### 3. 性能优化

避免在循环中重复创建SymbolGlyph：

```typescript
// ❌ 不推荐
ForEach(items, (item) => {
  SymbolGlyph($r('sys.symbol.edit'))
})

// ✅ 推荐
@Builder iconBuilder() {
  SymbolGlyph($r('sys.symbol.edit'))
}

ForEach(items, (item) => {
  this.iconBuilder()
})
```

---

## 七、验证清单

迁移完成后，请验证以下内容：

- [ ] 所有Emoji图标已替换为SymbolGlyph
- [ ] 深色模式下图标显示正常
- [ ] 图标大小符合规范（16/20/24/32/48）
- [ ] 激活态和非激活态颜色正确
- [ ] 无性能退化
- [ ] 屏幕阅读器支持正常
- [ ] 所有设备上显示一致

---

## 八、回滚方案

如果迁移后出现问题，可以快速回滚：

1. 保留Emoji映射表（EmojiToSymbolMap）
2. 使用IconMode.EMOJI强制使用Emoji模式
3. 通过配置开关控制显示模式

```typescript
// 配置开关
const USE_SYMBOL_ICON = false; // 设为false回滚到Emoji

if (USE_SYMBOL_ICON) {
  SymbolGlyph($r('sys.symbol.' + symbol))
} else {
  Text(emoji)
}
```

---

**文档维护**: 随着迁移进度更新本文档  
**最后更新**: 2026-08-08
