/**
 * EmptyState.ets — 空状态占位组件
 *
 * 在列表/搜索无结果、功能未就绪等场景下统一展示。
 * 支持自定义图标、标题、描述、操作按钮。
 */
import { HCColor, HCSpace, HCFont, HCRadius } from '../theme/DesignTokens';
import { IconComponent } from './IconComponent';
import { IconSymbols } from '../IconConstants';

export interface EmptyStateProps {
  icon: string;           // SymbolGlyph 图标名称（如 'document'），统一矢量渲染
  title: string;          // 主标题
  description?: string;   // 描述文字（可选）
  actionText?: string;    // 操作按钮文字（可选，有值则显示按钮）
  onAction?: () => void;  // 操作按钮回调
}

@Component
export struct EmptyState {
  private icon: string = IconSymbols.DOC_TEXT;
  private title: string = '';
  private description: string = '';
  private actionText: string = '';
  private onAction?: () => void;

  build() {
    Column() {
      // 图标（矢量 SymbolGlyph）
      IconComponent({ symbol: this.icon, iconSize: 48, color: HCColor.ICON_SECONDARY })
        .margin({ bottom: HCSpace.MD })

      // 标题
      Text(this.title)
        .fontSize(HCFont.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .margin({ bottom: HCSpace.SM })

      // 描述
      if (this.description.length > 0) {
        Text(this.description)
          .fontSize(HCFont.BODY)
          .fontColor(HCColor.TEXT_SECONDARY)
          .textAlign(TextAlign.Center)
          .maxLines(3)
          .margin({ bottom: HCSpace.LG })
      }

      // 操作按钮
      if (this.actionText.length > 0 && this.onAction) {
        Button(this.actionText)
          .fontSize(HCFont.BODY)
          .fontColor(HCColor.WHITE)
          .backgroundColor(HCColor.ACCENT)
          .borderRadius(HCRadius.PILL)
          .height(40)
          .padding({ left: 24, right: 24 })
          .onClick(() => { this.onAction!(); })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
