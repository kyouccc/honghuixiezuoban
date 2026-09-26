/**
 * LoadingView.ets — 统一加载视图组件
 *
 * 在数据加载期间展示 Loading 动画 + 提示文字。
 * 支持自定义提示文字。
 */
import { HCColor, HCSpace, HCFont } from '../theme/DesignTokens';

export interface LoadingProps {
  text?: string; // 加载提示文字（默认：「加载中…」）
}

@Component
export struct LoadingView {
  private text: string = '加载中…';

  build() {
    Column() {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(HCColor.ACCENT)
        .margin({ bottom: HCSpace.MD })

      Text(this.text)
        .fontSize(HCFont.BODY)
        .fontColor(HCColor.TEXT_SECONDARY)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
