/**
 * ConfirmDialog.ets — 统一确认对话框组件
 *
 * 在删除确认、操作确认等场景下统一使用。
 * 支持自定义标题、消息、取消/确认按钮文字及回调。
 */
import { HCColor, HCSpace, HCRadius, HCFont } from '../theme/DesignTokens';

export interface ConfirmDialogProps {
  title: string;
  message: string;
  cancelText?: string;
  confirmText?: string;
  onCancel?: () => void;
  onConfirm?: () => void;
}

@Component
export struct ConfirmDialog {
  private title: string = '';
  private message: string = '';
  private cancelText: string = '取消';
  private confirmText: string = '确认';
  private onCancel?: () => void;
  private onConfirm?: () => void;

  build() {
    Column() {
      // 标题
      Text(this.title)
        .fontSize(HCFont.TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .textAlign(TextAlign.Center)
        .margin({ bottom: HCSpace.MD })

      // 消息
      Text(this.message)
        .fontSize(HCFont.BODY)
        .fontColor(HCColor.TEXT_SECONDARY)
        .textAlign(TextAlign.Center)
        .maxLines(5)
        .margin({ bottom: HCSpace.XL })

      // 按钮行
      Row() {
        // 取消
        Button(this.cancelText)
          .fontSize(HCFont.BODY)
          .fontColor(HCColor.TEXT_PRIMARY)
          .backgroundColor(HCColor.SURFACE_TERTIARY)
          .borderRadius(HCRadius.PILL)
          .height(40)
          .layoutWeight(1)
          .margin({ right: HCSpace.SM })
          .onClick(() => {
            if (this.onCancel) {
              this.onCancel();
            }
          })

        // 确认
        Button(this.confirmText)
          .fontSize(HCFont.BODY)
          .fontColor(HCColor.WHITE)
          .backgroundColor(HCColor.ACCENT)
          .borderRadius(HCRadius.PILL)
          .height(40)
          .layoutWeight(1)
          .margin({ left: HCSpace.SM })
          .onClick(() => {
            if (this.onConfirm) {
              this.onConfirm();
            }
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(HCSpace.XL)
    .backgroundColor(HCColor.SURFACE_PRIMARY)
    .borderRadius(HCRadius.LG)
    .shadow({ radius: 12, color: '#33000000', offsetX: 0, offsetY: 4 })
  }
}
