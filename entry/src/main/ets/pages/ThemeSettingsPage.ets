/**
 * ThemeSettingsPage.ets - 主题设置页面（F-01 暗色模式 + U-05 主题皮肤系统）
 *
 * v3.1 审核修复：
 *  - 深色模式下多个 Text/SURFACE 颜色映射错误导致"看不清"，全部改用
 *    TEXT_PRIMARY/TEXT_SECONDARY/TEXT_TERTIARY 三色阶（深色下对应反相灰阶）
 *  - 主题皮肤切换增加 Toast 反馈、aboutToDisappear 清理 listener
 *  - 主题模式切换同样增加 Toast
 *
 * 功能：
 * 1. 主题模式切换（浅色/暗色/跟随系统）
 * 2. 主题皮肤选择（U-05：经典白 / 星夜蓝 / 护眼绿 / 暖阳米）
 * 3. 画布纸张样式选择
 * 4. 实时预览
 */

import { ThemeManager, ThemeMode, CanvasPaperStyle, ThemeConfig, themeManager } from '../common/theme/ThemeManager';
import { PaperStyleSelector } from '../components/CanvasPaper';
import { HCColor, HCRadius } from '../common/theme/DesignTokens';
import { BackButton } from '../common/components/BackButton';
import { promptAction } from '@kit.ArkUI';
import { Logger } from '../common/Logger';

/** U-05：主题皮肤定义 */
interface ThemeSkin {
  key: string;
  name: string;
  cardBg: string;
  barColor: string;
  lineColor: string;
}

/** v2.6.0：主题模式单选按钮的按引用传参类型（ArkTS 禁止匿名对象字面量作类型） */
interface ModeOptionParam {
  mode: ThemeMode;
  name: string;
  icon: string;
  selected: boolean;
}

@Entry
@Component
struct ThemeSettingsPage {
  @State private currentMode: ThemeMode = ThemeMode.SYSTEM;
  @State private currentPaper: CanvasPaperStyle = CanvasPaperStyle.LIGHT;
  @State private isDarkMode: boolean = false;
  @State private currentSkin: string = 'classic';

  // 🔧 v3.1 修复：保留 listener 引用，aboutToDisappear 时清理避免重复触发
  private themeListener: ((newConfig: ThemeConfig) => void) | null = null;

  private readonly skins: ThemeSkin[] = [
    { key: 'classic', name: '经典白', cardBg: '#F7F8FA', barColor: '#1A1A1A', lineColor: '#C4C8CE' },
    { key: 'night', name: '星夜蓝', cardBg: '#22345F', barColor: '#FFFFFF', lineColor: '#FFFFFF' },
    { key: 'green', name: '护眼绿', cardBg: '#E8F1E8', barColor: '#2E5E3E', lineColor: '#7FA88B' },
    { key: 'warm', name: '暖阳米', cardBg: '#F7F0E2', barColor: '#8A6D3B', lineColor: '#C4A87C' },
  ];

  aboutToAppear(): void {
    // 🔧 修复：先从持久化加载主题设置，确保皮肤/模式/纸张跨启动一致
    themeManager.loadFromPreferences().then(() => {
      const config = themeManager.getConfig();
      this.currentMode = config.mode;
      this.currentPaper = config.canvasPaper;
      this.currentSkin = config.skin;
      this.isDarkMode = themeManager.isDarkMode();
    });

    // 🔧 v3.1 修复：保存 listener 引用，aboutToDisappear 时移除避免反复进入页面时重复触发
    this.themeListener = (newConfig) => {
      this.currentMode = newConfig.mode;
      this.currentPaper = newConfig.canvasPaper;
      this.currentSkin = newConfig.skin;
      this.isDarkMode = themeManager.isDarkMode();
    };
    themeManager.addListener(this.themeListener);
  }

  aboutToDisappear(): void {
    // 🔧 v3.1 修复：清理监听器，避免下次进入页面时累积重复触发
    if (this.themeListener) {
      themeManager.removeListener(this.themeListener);
      this.themeListener = null;
    }
  }

  /**
   * 🔧 v3.1 修复：主题切换/皮肤切换 Toast 反馈，避免用户认为"点击无响应"
   */
  private showToast(message: string): void {
    try {
      promptAction.showToast({ message: message, duration: 1500 });
    } catch (error) {
      Logger.error('ThemeSettingsPage', 'showToast failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 🔧 v3.1 修复：根据深色模式返回正确的文字颜色（统一三色阶规则）
   * 深色模式下：浅色文字 (TEXT_PRIMARY 反相)、中色 (TEXT_SECONDARY)、暗色 (TEXT_TERTIARY)
   * 浅色模式下：默认三色阶
   * 注意：深色模式下使用 #FFFFFF 等浅色作为正文，禁用 SURFACE（同背景色）
   */
  private textPrimary(): ResourceColor {
    return this.isDarkMode ? '#E5E7EB' : HCColor.TEXT_PRIMARY;
  }
  private textSecondary(): ResourceColor {
    return this.isDarkMode ? '#9CA3AF' : HCColor.TEXT_SECONDARY;
  }
  private textTertiary(): ResourceColor {
    return this.isDarkMode ? '#6B7280' : HCColor.TEXT_TERTIARY;
  }

  /**
   * v2.5.2 审核修复：根据当前皮肤返回页面背景色（字符串），让用户切完皮肤立即看到变化
   */
  private getPageBgColor(): string {
    if (this.isDarkMode) {
      return '#121212';
    }
    switch (this.currentSkin) {
      case 'night': return '#1A2540';
      case 'green': return '#E8F1E8';
      case 'warm':  return '#F7F0E2';
      case 'classic':
      default:     return '#F7F8FA';
    }
  }

  /**
   * v2.6.0 审核修复（问题②-3）：画布纸张预览底色。
   *   让「画布纸张」选择在设置页内立即可见（真实画布底色同源，见 ThemeManager.getCanvasPaperColor）。
   */
  private paperPreviewColor(): string {
    try {
      return themeManager.getCanvasPaperColor();
    } catch (_e) {
      return '#FFFFFF';
    }
  }

  private paperName(): string {
    const map: Map<CanvasPaperStyle, string> = new Map<CanvasPaperStyle, string>([
      [CanvasPaperStyle.LIGHT, '白色'],
      [CanvasPaperStyle.DARK, '深色'],
      [CanvasPaperStyle.DARK_ALT, '深色变体'],
      [CanvasPaperStyle.WARM, '护眼暖色'],
      [CanvasPaperStyle.SEPIA, '复古褐色']
    ]);
    return map.get(this.currentPaper) ?? '白色';
  }

  build() {
    Column() {
      // 统一返回按钮
      BackButton({ title: '主题设置' })

      // 设置内容
      Scroll() {
        Column() {
          this.ThemeModeSection()

          Divider().color(HCColor.DIVIDER).margin({ top: 24, bottom: 24 })

          this.ThemeSkinSection()

          Divider().color(HCColor.DIVIDER).margin({ top: 24, bottom: 24 })

          this.CanvasPaperSection()

          Divider().color(HCColor.DIVIDER).margin({ top: 24, bottom: 24 })

          this.PreviewSection()
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    // v2.5.2 审核修复：使用 getPageBgColor() 替代 HCColor.PAGE_BG，让皮肤切换立即可见
    .backgroundColor(this.getPageBgColor())
  }

  /** 页面转场动画 */
  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }

  /**
   * 主题模式设置（F-01）
   */
  @Builder
  ThemeModeSection() {
    Column() {
      Text('主题模式')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
        .margin({ bottom: 16 })

      Row() {
        this.ModeOption({ mode: ThemeMode.LIGHT, name: '浅色', icon: 'A',
          selected: this.currentMode === ThemeMode.LIGHT })
        this.ModeOption({ mode: ThemeMode.DARK, name: '深色', icon: 'D',
          selected: this.currentMode === ThemeMode.DARK })
        this.ModeOption({ mode: ThemeMode.SYSTEM, name: '跟随系统', icon: 'S',
          selected: this.currentMode === ThemeMode.SYSTEM })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * v2.6.0 审核修复（问题②-1）：
   *   原 ModeOption(mode, name, icon) 是带参 @Builder，体内读 this.currentMode 决定高亮。
   *   ArkUI 的 @Builder 参数默认「按值传递」，状态变化不会刷新其内部 UI ——
   *   于是点「浅色/深色」后选中态不动，用户以为设置没生效（叠加"主页面仍跟随系统"的观感）。
   *   现改为对象字面量传参（按引用传递），把 selected 显式放进对象，保证高亮实时刷新。
   */
  @Builder
  ModeOption($$: ModeOptionParam) {
    Column() {
      Text($$.icon)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($$.selected ? HCColor.PRIMARY : HCColor.TEXT_TERTIARY)
        .width(40)
        .height(40)
        .borderRadius(20)
        .textAlign(TextAlign.Center)
        .lineHeight(40)
        .backgroundColor($$.selected ? HCColor.PRIMARY_BG : 'transparent')

      Text($$.name)
        .fontSize(14)
        .margin({ top: 8 })
        .fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
        .fontWeight($$.selected ? FontWeight.Medium : FontWeight.Regular)
    }
    .width(90)
    .height(100)
    .justifyContent(FlexAlign.Center)
    .borderRadius(HCRadius.MD)
    .backgroundColor($$.selected ? HCColor.PRIMARY_BG : HCColor.SURFACE)
    .border({
      width: $$.selected ? 2 : 1,
      color: $$.selected ? HCColor.PRIMARY : HCColor.BORDER
    })
    .onClick(() => {
      this.currentMode = $$.mode;
      themeManager.setThemeMode($$.mode);
      // 🔧 v3.1 修复：异步持久化，不阻塞 UI，并捕获错误
      themeManager.saveToPreferences().catch((err: Error): void => {
        Logger.error('ThemeSettingsPage', '保存主题模式失败: ' + err.message);
        this.showToast('保存失败，请重试');
      });
      this.showToast($$.mode === ThemeMode.LIGHT ? '已切换到浅色（全应用生效）' :
        $$.mode === ThemeMode.DARK ? '已切换到深色（全应用生效）' : '已切换到跟随系统');
    })
  }

  /**
   * U-05：主题皮肤选择（4 套）
   */
  @Builder
  ThemeSkinSection() {
    Column() {
      Text('主题皮肤')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
        .margin({ bottom: 4 })
      Text('为笔记库与编辑器换肤 · 经典白 / 星夜蓝 / 护眼绿 / 暖阳米')
        .fontSize(11)
        .fontColor(HCColor.TEXT_TERTIARY)
        .margin({ bottom: 14 })

      Row() {
        ForEach(this.skins, (skin: ThemeSkin) => {
          Column() {
            Column() {
              Row()
                .width(28)
                .height(6)
                .borderRadius(3)
                .backgroundColor(this.isDarkMode ? '#FFFFFF' : skin.barColor)
                .margin({ bottom: 6 })
              Row()
                .width(44)
                .height(5)
                .borderRadius(2.5)
                .backgroundColor(this.isDarkMode ? '#AAAAAA' : skin.lineColor)
                .opacity(0.6)
                .margin({ bottom: 4 })
              Row()
                .width(36)
                .height(5)
                .borderRadius(2.5)
                .backgroundColor(this.isDarkMode ? '#AAAAAA' : skin.lineColor)
                .opacity(0.4)
            }
            .width('100%')
            .height(52)
            .padding({ left: 10, right: 10, top: 10 })
            .alignItems(HorizontalAlign.Start)
            .borderRadius(8)
            // 🔧 修复：深色模式下使用暗色卡片背景，避免亮色卡片与暗色页面冲突
            .backgroundColor(this.isDarkMode ? '#2A2A2A' : skin.cardBg)

            Text(skin.name)
              .fontSize(11)
              .margin({ top: 6 })
              .fontColor(this.currentSkin === skin.key ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY)
              .fontWeight(this.currentSkin === skin.key ? FontWeight.Medium : FontWeight.Regular)
          }
          .layoutWeight(1)
          .margin({ left: 6, right: 6 })
          .padding(8)
          .borderRadius(HCRadius.MD)
          .backgroundColor(this.currentSkin === skin.key ? HCColor.PRIMARY_BG : 'transparent')
          .border({
            width: this.currentSkin === skin.key ? 2 : 1,
            color: this.currentSkin === skin.key ? HCColor.PRIMARY : HCColor.BORDER
          })
          .onClick(() => {
            this.currentSkin = skin.key;
            themeManager.setSkin(skin.key);
            // 🔧 v3.1 修复：异步持久化 + Toast 反馈
            themeManager.saveToPreferences().catch((err: Error): void => {
              Logger.error('ThemeSettingsPage', '保存主题皮肤失败: ' + err.message);
              this.showToast('保存失败，请重试');
            });
            this.showToast(`已切换到「${skin.name}」`);
          })
        }, (skin: ThemeSkin): string => skin.key)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 画布纸张设置
   */
  @Builder
  CanvasPaperSection() {
    Column() {
      Text('画布纸张')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
        .margin({ bottom: 4 })

      // v2.6.0：说明纸张样式（底色）与底纸图案的关系，并回显当前选择
      Text(`当前：${this.paperName()} · 底色会直接应用到画板底纸（图案在画板内「底纸」中切换）`)
        .fontSize(11)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width('100%')
        .margin({ bottom: 12 })

      PaperStyleSelector({ currentStyle: $currentPaper })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 预览区域
   */
  @Builder
  PreviewSection() {
    Column() {
      Text('预览')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
        .margin({ bottom: 16 })

      Column() {
        Row() {
          Column() {
            Text('示例笔记')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)

            Text('2026-08-08 10:30')
              .fontSize(12)
              .fontColor(HCColor.TEXT_TERTIARY)  // Resource 类型，自动暗色切换
              .margin({ top: 4 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Text('页')
            .fontSize(12)
            .fontColor(HCColor.PRIMARY)
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6)
            .backgroundColor(HCColor.PRIMARY_BG)
        }
        .width('100%')
        .padding(16)
        // v2.6.0：预览底纸使用与真实画布同源的纸张底色，设置即时可见
        .backgroundColor(this.paperPreviewColor())
        .borderRadius(8)

        Row() {
          Text('笔').fontSize(13).fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
          Text('色').fontSize(13).fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
          Text('形').fontSize(13).fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
          Text('擦').fontSize(13).fontColor(this.isDarkMode ? this.textPrimary() : HCColor.TEXT_PRIMARY)
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.SpaceEvenly)
        .backgroundColor(HCColor.SURFACE)  // Resource 类型，自动暗色切换
        .borderRadius(8)
        .margin({ top: 12 })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(HCColor.PAGE_BG)  // Resource 类型，自动暗色切换
      .borderRadius(HCRadius.MD)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
