/**
 * FullscreenOverlay.ets — 全屏阅读模式叠加层（P0 缺失功能 UI 组件）
 *
 * 底部显示页码/进度条/退出按钮，点击边缘翻页
 */
import { FullscreenReadingMode, ReadingState } from '../engine/FullscreenReadingMode';
import { HCColor } from '../common/theme/DesignTokens';

const TAG = 'FullscreenOverlay';

@Component
export struct FullscreenOverlay {
  private readingMode: FullscreenReadingMode = FullscreenReadingMode.getInstance();
  @State currentPage: number = 1;
  @State totalPages: number = 1;
  @State visible: boolean = false;

  /** 翻页回调 */
  onPrevPage?: () => void;
  onNextPage?: () => void;
  onExit?: () => void;

  build() {
    Stack() {
      if (this.visible) {
        // 半透明遮罩（点击触发翻页或显示控制栏）
        Column() {
          // 点击右侧→下一页
          Row() {
            Column().width('30%').height('100%')
              .onClick(() => { this.onPrevPage?.(); })
            Column().width('40%').height('100%')
              .onClick(() => {
                this.readingMode.showOverlay();
              })
            Column().width('30%').height('100%')
              .onClick(() => { this.onNextPage?.(); })
          }
          .height('100%')
        }
        .width('100%').height('100%')
        .hitTestBehavior(HitTestMode.Block)

        // 底部控制栏
        Column() {
          Row() {
            // 页码
            Text(`${this.currentPage} / ${this.totalPages}`)
              .fontSize(14).fontColor('#FFFFFF')

            // 进度条
            Slider({
              value: this.currentPage,
              min: 1,
              max: Math.max(this.totalPages, 1),
              step: 1
            })
              .width(200)
              .onChange((v: number) => {
                // 跳转页码
              })

            // 退出按钮
            Button('退出阅读')
              .fontSize(13).fontColor('#FFFFFF')
              .backgroundColor('#66000000')
              .borderRadius(16)
              .height(32)
              .onClick(() => {
                this.onExit?.();
              })
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 8 })
          .justifyContent(FlexAlign.SpaceBetween)
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .align(Alignment.Bottom)
        .padding({ bottom: 56 })
        .backgroundColor('#99000000')
      }
    }
    .width('100%').height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
  }
}
