/**
 * BackButton.ets — 统一返回按钮组件（v1.0）
 *
 * 用途：
 *  1. 全局统一的返回按钮样式与交互
 *  2. 支持自定义标题文字
 *  3. 支持自定义返回回调
 *  4. 自动适配主题色 HCColor
 *
 * 约束：
 *  - 默认调用 router.back()，可通过 onBack 覆盖
 *  - 标题居中，按钮居左，对称占位
 *
 * v1.1（2026-08-29 修复）：
 *  - 返回箭头改用 SymbolGlyph 系统符号（跨设备一致），不再使用半角 ‹ 字符（部分设备字体不渲染、字色与背景对比度低）
 *  - 按钮底色改为 HCColor.SURFACE + 1px BORDER，标题栏背景为 SURFACE 时也能明显区分
 */

import { router } from '@kit.ArkUI';
import { HCColor } from '../theme/DesignTokens';
import { IconComponent } from './IconComponent';
import { IconSymbols } from '../IconConstants';

export interface BackButtonProps {
  title?: string;           // 页面标题（默认不显示）
  onBack?: () => void;      // 自定义返回回调
  rightAction?: () => void; // 右侧操作按钮回调
  rightIcon?: string;       // 右侧操作按钮文字
}

@Component
export struct BackButton {
  private title: string = '';
  private onBack?: () => void;
  private rightAction?: () => void;
  private rightIcon: string = '';

  build() {
    Row() {
      // 返回按钮：使用 SymbolGlyph 系统箭头（深色、清晰可辨）
      // 🔧 修复：原方案用 ‹ 字符 + PAGE_BG 浅灰底，在白底页面上几乎不可见
      Button() {
        IconComponent({
          symbol: IconSymbols.BACK,
          iconSize: 22,
          color: HCColor.TEXT_PRIMARY
        })
      }
      .width(40)
      .height(40)
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(20)
      .border({ width: 1, color: HCColor.BORDER })
      .shadow({ radius: 2, color: '#08000000' })
      .onClick(() => {
        if (this.onBack) {
          this.onBack();
        } else {
          router.back();
        }
      })

      // 标题（居中）
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(HCColor.TEXT_PRIMARY)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      } else {
        Blank().layoutWeight(1)
      }

      // 右侧操作按钮（可选）
      if (this.rightIcon.length > 0 && this.rightAction) {
        Button() {
          Text(this.rightIcon)
            .fontSize(14)
            .fontColor(HCColor.PRIMARY)
            .fontWeight(FontWeight.Medium)
        }
        .width(40)
        .height(40)
        .backgroundColor(HCColor.PRIMARY_BG)
        .borderRadius(20)
        .onClick(() => {
          this.rightAction!();
        })
      } else {
        Blank().width(40)
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 8, right: 8 })
    .backgroundColor(HCColor.SURFACE)
  }
}
