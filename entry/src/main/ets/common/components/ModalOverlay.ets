/**
 * ModalOverlay.ets — 统一模态浮层组件
 *
 * 白板页大量使用「半透明遮罩 + 居中内容面板」模式。
 * 此组件封装通用结构，消除重复代码。
 *
 * 用法：
 *   ModalOverlay({ show: isOpen, onClose: () => { close(); } }) {
 *     Column() { ... }
 *   }
 */
import { HCColor, HCRadius, HCSpace } from '../theme/DesignTokens';

@Component
export struct ModalOverlay {
  @Prop show: boolean = false;
  private onClose?: () => void;
  @BuilderParam content: () => void;

  build() {
    if (this.show) {
      Stack() {
        // 半透明背景
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#33000000')
          .onClick(() => {
            if (this.onClose) {
              this.onClose();
            }
          })

        // 内容面板
        this.content()
      }
      .width('100%')
      .height('100%')
      .position({ x: 0, y: 0 })
    }
  }
}
