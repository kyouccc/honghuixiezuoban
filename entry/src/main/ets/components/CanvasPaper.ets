/**
 * CanvasPaper.ets - 画布纸张组件（支持深色纸张）
 * 
 * 功能：
 * 1. 提供多种纸张样式（白色/深色/暖色/褐色）
 * 2. 支持网格/点阵/横线等背景
 * 3. 响应主题切换
 */

import { ThemeManager, CanvasPaperStyle, themeManager } from '../common/theme/ThemeManager';
import { HCColor } from '../common/theme/DesignTokens';

@Component
export struct CanvasPaper {
  // 纸张样式（可由外部控制）
  @Prop paperStyle: CanvasPaperStyle = CanvasPaperStyle.LIGHT;
  
  // 纸张类型：blank / grid / dot / line / four_line
  @Prop paperType: string = 'blank';
  
  // 纸张尺寸（重命名避免与基类width/height方法冲突）
  @Prop paperWidth: number = 1080;
  @Prop paperHeight: number = 1920;
  
  // 是否响应主题变化
  @Prop followTheme: boolean = true;
  
  // 内部状态
  @State private currentPaperColor: ResourceColor = HCColor.SURFACE;
  @State private currentGridColor: ResourceColor = HCColor.BORDER;
  
  aboutToAppear(): void {
    this.updatePaperColors();
    
    // 监听主题变化
    if (this.followTheme) {
      themeManager.addListener(() => {
        this.updatePaperColors();
      });
    }
  }
  
  aboutToDisappear(): void {
    // 清理监听器
  }
  
  /**
   * 更新纸张颜色
   */
  private updatePaperColors(): void {
    if (this.followTheme) {
      this.currentPaperColor = themeManager.getCanvasPaperColor();
      this.currentGridColor = themeManager.getCanvasGridColor();
    } else {
      // 使用指定的纸张样式
      switch (this.paperStyle) {
        case CanvasPaperStyle.LIGHT:
          this.currentPaperColor = HCColor.SURFACE;
          this.currentGridColor = HCColor.BORDER;
          break;
        case CanvasPaperStyle.DARK:
          this.currentPaperColor = HCColor.TEXT_PRIMARY;
          this.currentGridColor = HCColor.TEXT_PRIMARY;
          break;
        case CanvasPaperStyle.DARK_ALT:
          this.currentPaperColor = HCColor.TEXT_PRIMARY;
          this.currentGridColor = HCColor.TEXT_PRIMARY;
          break;
        case CanvasPaperStyle.WARM:
          this.currentPaperColor = HCColor.WARNING_BG;
          this.currentGridColor = '#E8DFD0';
          break;
        case CanvasPaperStyle.SEPIA:
          this.currentPaperColor = '#F4ECD8';
          this.currentGridColor = '#DDD5C5';
          break;
      }
    }
  }
  
  build() {
    Stack() {
      // 底层：纸张背景色
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.currentPaperColor)
      
      // 上层：纸张图案（网格/点阵/横线）
      if (this.paperType !== 'blank') {
        this.PaperPattern()
      }
    }
    .width(this.paperWidth)
    .height(this.paperHeight)
  }
  
  /**
   * 纸张图案组件
   */
  @Builder
  PaperPattern() {
    Canvas(this.getPatternContext())
      .width('100%')
      .height('100%')
      .onReady(() => {
        this.drawPattern();
      })
  }
  
  /**
   * 获取 Canvas 上下文
   */
  private getPatternContext(): CanvasRenderingContext2D {
    // 创建 Canvas 上下文（不需要Settings参数）
    const context = new CanvasRenderingContext2D();
    return context;
  }
  
  /**
   * 绘制纸张图案
   */
  private drawPattern(): void {
    // 根据纸张类型绘制不同图案
    // 注意：这里需要实际的 Canvas 引用
    // 实际实现中需要在 onReady 回调中获取 context
  }
}

/**
 * 纸张样式项接口
 */
interface PaperStyleItem {
  style: CanvasPaperStyle;
  name: string;
  icon: string;
}

/**
 * 纸张样式选择器组件
 */
@Component
export struct PaperStyleSelector {
  @Link currentStyle: CanvasPaperStyle;
  @State private isDarkMode: boolean = false;
  
  private paperStyles: PaperStyleItem[] = [
    { style: CanvasPaperStyle.LIGHT, name: '白色', icon: '亮' } as PaperStyleItem,
    { style: CanvasPaperStyle.DARK, name: '深色', icon: '暗' } as PaperStyleItem,
    { style: CanvasPaperStyle.DARK_ALT, name: '深色变体', icon: '深' } as PaperStyleItem,
    { style: CanvasPaperStyle.WARM, name: '护眼', icon: '暖' } as PaperStyleItem,
    { style: CanvasPaperStyle.SEPIA, name: '复古', icon: '卷' } as PaperStyleItem
  ];
  
  aboutToAppear(): void {
    this.isDarkMode = themeManager.isDarkMode();
    themeManager.addListener(() => {
      this.isDarkMode = themeManager.isDarkMode();
    });
  }
  
  build() {
    Column() {
      Text('纸张样式')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 12 })
      
      Row() {
        ForEach(this.paperStyles, (item: PaperStyleItem) => {
          Column() {
            Text(item.icon)
              .fontSize(24)
            
            Text(item.name)
              .fontSize(12)
              .margin({ top: 4 })
          }
          .width(56)
          .height(72)
          .justifyContent(FlexAlign.Center)
          .borderRadius(8)
          .backgroundColor(this.currentStyle === item.style ? 
            (this.isDarkMode ? '#2A5A8C' : HCColor.PRIMARY_BG) : 
            (this.isDarkMode ? '#2A2A2A' : HCColor.PAGE_BG))
          .border({
            width: this.currentStyle === item.style ? 2 : 1,
            color: this.currentStyle === item.style ? HCColor.PRIMARY : (this.isDarkMode ? HCColor.TEXT_PRIMARY : HCColor.BORDER)
          })
          .onClick(() => {
            this.currentStyle = item.style;
            themeManager.setCanvasPaper(item.style);
          })
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .width('100%')
    .padding(16)
  }
}
