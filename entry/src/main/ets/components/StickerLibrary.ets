import { HCColor } from '../common/theme/DesignTokens';
import { IconComponent } from '../common/components/IconComponent';
import { IconSymbols } from '../common/IconConstants';
/**
 * StickerLibrary.ets — 贴纸素材库（S2-B / T2-3 新建）
 *
 * 内置 emoji 贴纸素材面板：点击贴纸 → 回调插入（WhiteboardPage 以图片层/元素插入）。
 * 纯受控组件（无内部业务状态），父页以 Stack 浮层 + 条件渲染方式挂载（与 BrushPanel 同模式）。
 */

/** 内置贴纸（emoji 字符 + 名称；渲染期按文字绘制到画布） */
const STICKERS: string[] = ['📌', '⭐', '❤️', '🔥', '✅', '❗', '💡', '🎯', '🚀', '🎉', '📝', '🔔'];

const TAG_MODULE = 'StickerLibrary';

@Component
export struct StickerLibrary {
  /** 当前画笔颜色（贴纸填充色，用于非 emoji 场景；emoji 直接渲染字符） */
  @Prop currentColor: string = '#000000';

  /** 贴纸插入回调：emoji + 屏幕位置 */
  onInsert: (sticker: string) => void = (sticker: string) => {};
  /** 关闭面板 */
  onClose: () => void = () => {};

  build() {
    Column() {
      Row() {
        Text('贴纸')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(HCColor.TEXT_PRIMARY)

        Blank()

        IconComponent({ symbol: IconSymbols.CLOSE, iconSize: 18, color: HCColor.ICON_SECONDARY })
          .width(28)
          .height(28)
          .onClick(() => this.onClose())
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 10, bottom: 6 })

      Grid() {
        ForEach(STICKERS, (s: string) => {
          GridItem() {
            Text(s)
              .fontSize(30)
              .width(56)
              .height(56)
              .textAlign(TextAlign.Center)
              .backgroundColor('#F5F7FA')
              .borderRadius(10)
              .onClick(() => {
                this.onInsert(s);
              })
          }
        }, (s: string) => s)
      }
      .columnsTemplate('1fr 1fr 1fr 1fr')
      .columnsGap(10)
      .rowsGap(10)
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
      // v2.5.2 审核修复：滑动到边界需有反馈动效
      .edgeEffect(EdgeEffect.Spring)
    }
    .width(320)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius({ topLeft: 18, topRight: 18 })
    .shadow({ radius: 18, color: '#22000000', offsetX: 0, offsetY: -4 })
  }
}
