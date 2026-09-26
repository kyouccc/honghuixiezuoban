# 折叠屏适配优化文档（F-05）

## 一、当前实现状态

### 1. 设备适配服务（DeviceAdapter.ets）

**已实现功能：**
- ✅ 设备类型检测（PHONE/TABLET/LARGE_SCREEN/TV）
- ✅ 折叠屏状态监听（UNKNOWN/EXPANDED/FOLDED/HALF_FOLDED）
- ✅ 显示模式检测（MAIN/FULL/SUB）
- ✅ 屏幕尺寸变化监听
- ✅ 响应式布局参数计算
- ✅ 折叠屏铰链区域检测

**关键接口：**
```typescript
export interface DeviceInfo {
  type: DeviceType;
  screenWidth: number;
  screenHeight: number;
  densityDPI: number;
  isFoldable: boolean;
  foldStatus: FoldStatus;
  foldDisplayMode: FoldDisplayMode;
  creaseTopVp: number;      // 铰链顶部位置（vp）
  creaseBottomVp: number;   // 铰链底部位置（vp）
  recommendedFontSize: number;
  recommendedToolbarHeight: number;
  recommendedCanvasPadding: number;
}
```

### 2. WhiteboardPage 折叠屏适配

**已实现功能：**
- ✅ 折叠状态监听（@StorageProp + @Watch）
- ✅ 半折叠悬停态判定（HALF_FOLDED）
- ✅ 铰链区域避让（creaseTopVp/creaseBottomVp）
- ✅ 响应式布局参数（响应式字体大小、工具栏高度、画布内边距）

**关键代码：**
```typescript
// 折叠状态监听
@StorageProp('hcFoldStatus') @Watch('onFoldStorageChange') foldStatusStorage: number = FoldStatus.UNKNOWN;

// 半折叠悬停态判定
get isHalfFolded(): boolean {
  return this.foldStatusStorage === 3; // HALF_FOLDED
}

// 折叠状态变化回调
onFoldStorageChange(): void {
  this.isHalfFolded = this.foldStatusStorage === 3;
  // 更新布局参数...
}
```

## 二、优化建议

### 1. 半折叠悬停态优化

**当前问题：**
- 工具栏在半折叠状态下可能被铰链遮挡
- 画布内容可能跨越铰链区域，影响书写体验

**优化方案：**
```typescript
// 在半折叠状态下，将工具栏移至下半屏
if (this.isHalfFolded) {
  // 工具栏位置调整
  this.toolbarPosition = { y: this.creaseBottomVp + 16 };
  
  // 画布区域限制在下半屏
  this.canvasHeight = this.screenHeight - this.creaseBottomVp - this.toolbarHeight;
}
```

### 2. 铰链区域避让优化

**当前实现：**
- 已检测铰链位置（creaseTopVp/creaseBottomVp）
- 但未在UI层面完全避让

**优化方案：**
```typescript
// 在铰链区域添加视觉提示
if (this.isHalfFolded) {
  // 铰链区域遮罩
  Rect()
    .width('100%')
    .height(this.creaseBottomVp - this.creaseTopVp)
    .position({ y: this.creaseTopVp })
    .fill('#0D000000')  // 半透明遮罩
    .hitTestBehavior(HitTestMode.Block)  // 阻止触摸事件
}
```

### 3. 响应式布局优化

**当前实现：**
- 已计算推荐字体大小、工具栏高度、画布内边距
- 但未完全应用到所有UI组件

**优化方案：**
```typescript
// 应用响应式字体大小
Text('示例文本')
  .fontSize(this.responsiveFontSize)

// 应用响应式工具栏高度
Row() {
  // 工具栏内容
}
.height(this.deviceInfo.recommendedToolbarHeight)

// 应用响应式画布内边距
Canvas()
  .padding({
    top: this.deviceInfo.recommendedCanvasPadding,
    bottom: this.deviceInfo.recommendedCanvasPadding
  })
```

### 4. 折叠屏手势优化

**当前问题：**
- 折叠屏设备通常屏幕较大，单手操作困难
- 工具栏可能距离手指较远

**优化方案：**
```typescript
// 在半折叠状态下，将常用工具移至屏幕底部
if (this.isHalfFolded) {
  // 快速工具栏移至下半屏底部
  this.quickBarPosition = { y: this.screenHeight - 120 };
  
  // 增大工具按钮触摸区域
  this.toolButtonSize = 56;  // 比普通状态更大
}
```

## 三、测试验证清单

### 1. 折叠屏状态切换测试

- [ ] 完全展开（EXPANDED）：工具栏、画布布局正常
- [ ] 完全折叠（FOLDED）：布局适配小屏
- [ ] 半折叠（HALF_FOLDED）：悬停态布局正确，铰链区域避让
- [ ] 快速切换：布局平滑过渡，无闪烁

### 2. 铰链区域避让测试

- [ ] 工具栏不被铰链遮挡
- [ ] 画布内容不跨越铰链
- [ ] 铰链区域触摸事件被阻止
- [ ] 铰链区域有视觉提示

### 3. 响应式布局测试

- [ ] 字体大小适配屏幕尺寸
- [ ] 工具栏高度适配屏幕尺寸
- [ ] 画布内边距适配屏幕尺寸
- [ ] 所有UI组件应用响应式参数

### 4. 手势操作测试

- [ ] 单手可触达常用工具
- [ ] 工具按钮触摸区域足够大
- [ ] 书写手势不受折叠状态影响
- [ ] 双指缩放、平移手势正常

## 四、实现优先级

### P0（必须实现）
1. ✅ 折叠状态监听
2. ✅ 半折叠悬停态判定
3. ⏳ 铰链区域避让（UI层面）
4. ⏳ 响应式布局参数应用

### P1（建议实现）
1. ⏳ 铰链区域视觉提示
2. ⏳ 折叠屏手势优化
3. ⏳ 布局平滑过渡动画

### P2（可选实现）
1. ⏳ 折叠屏专属布局模板
2. ⏳ 折叠屏多窗口模式支持

## 五、相关文件

- `entry/src/main/ets/common/services/DeviceAdapter.ets` - 设备适配服务
- `entry/src/main/ets/pages/WhiteboardPage.ets` - 白板页面（折叠屏适配）
- `entry/src/main/ets/pages/NotePage.ets` - 笔记页面（折叠屏适配）
- `entry/src/main/ets/common/theme/DesignTokens.ets` - 设计令牌（响应式参数）

## 六、参考资料

- [HarmonyOS 折叠屏适配指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/foldable-screen-V5)
- [HarmonyOS 响应式布局开发](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/responsive-layout-V5)
- [HarmonyOS 铰链区域避让](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides-V5/hinge-area-V5)
