/**
 * CrashRecoveryDialog.ets - 崩溃恢复提示对话框（F-04 崩溃兜底）
 * 
 * 功能：
 * 1. 显示崩溃恢复提示
 * 2. 提供恢复/丢弃选项
 * 3. 显示笔记信息预览
 */

import { CrashRecoveryData, RecoverOutcome, crashRecoveryService } from '../common/services/CrashRecoveryService';
import { router, promptAction } from '@kit.ArkUI';
import { HCColor } from '../common/theme/DesignTokens';
import { Logger } from '../common/Logger';

@CustomDialog
export struct CrashRecoveryDialog {
  controller: CustomDialogController;
  
  // 恢复数据
  @State recoveryData: CrashRecoveryData | null = null;
  
  // 回调
  onRecover?: () => void;
  onDiscard?: () => void;
  
  aboutToAppear(): void {
    this.recoveryData = crashRecoveryService.getRecoveryData();
  }
  
  build() {
    Column() {
      // 标题
      Text('检测到未保存的内容')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ bottom: 16 })
      
      // 提示信息
      Text('上次编辑时应用异常退出，检测到未保存的内容。是否恢复？')
        .fontSize(14)
        .fontColor(HCColor.TEXT_TERTIARY)
        .textAlign(TextAlign.Center)
        .margin({ bottom: 24 })
      
      // 笔记信息预览
      if (this.recoveryData) {
        this.NoteInfoCard()
      }
      
      // 按钮组
      Row() {
        // 丢弃按钮
        Button('丢弃')
          .width(120)
          .height(40)
          .fontSize(16)
          .backgroundColor(HCColor.DIVIDER)
          .fontColor(HCColor.TEXT_TERTIARY)
          .borderRadius(8)
          .onClick(() => {
            this.handleDiscard();
          })
        
        // 恢复按钮
        Button('恢复')
          .width(120)
          .height(40)
          .fontSize(16)
          .backgroundColor(HCColor.PRIMARY)
          .fontColor(HCColor.SURFACE)
          .borderRadius(8)
          .margin({ left: 16 })
          .onClick(() => {
            this.handleRecover();
          })
      }
      .margin({ top: 24 })
    }
    .width('100%')
    .padding(24)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(16)
  }
  
  /**
   * 笔记信息卡片
   */
  @Builder
  NoteInfoCard() {
    Column() {
      Row() {
        Text('写')
          .fontSize(20)
          .margin({ right: 8 })
        
        Column() {
          Text(this.recoveryData?.title || '未命名笔记')
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(HCColor.TEXT_PRIMARY)
          
          Text(this.formatTime(this.recoveryData?.timestamp || 0))
            .fontSize(12)
            .fontColor(HCColor.ICON_SECONDARY)
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      
      // 笔记统计
      Row() {
        this.StatItem('笔画', this.recoveryData?.content.strokes.length || 0)
        this.StatItem('图片', this.recoveryData?.content.images.length || 0)
        this.StatItem('图层', this.recoveryData?.content.layers.length || 0)
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceEvenly)
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(HCColor.PAGE_BG)
    .borderRadius(8)
  }
  
  /**
   * 统计项
   */
  @Builder
  StatItem(label: string, value: number) {
    Column() {
      Text(value.toString())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.PRIMARY)
      
      Text(label)
        .fontSize(12)
        .fontColor(HCColor.ICON_SECONDARY)
        .margin({ top: 4 })
    }
  }
  
  /**
   * 格式化时间
   */
  private formatTime(timestamp: number): string {
    const date = new Date(timestamp);
    const year = date.getFullYear();
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const hour = date.getHours().toString().padStart(2, '0');
    const minute = date.getMinutes().toString().padStart(2, '0');
    return `${year}-${month}-${day} ${hour}:${minute}`;
  }
  
  /**
   * 处理恢复
   */
  private async handleRecover(): Promise<void> {
    try {
      // v2.6.0：recoverNote 返回结构化结果，内部已含「另存为新笔记」兜底 ——
      //   只要本地存储可用就一定能恢复出来，不再出现"点了恢复却什么都没发生"。
      const outcome: RecoverOutcome = await crashRecoveryService.recoverNote();

      if (outcome.ok) {
        // 调用恢复回调
        if (this.onRecover) {
          this.onRecover();
        }

        // 关闭对话框
        this.controller.close();

        promptAction.showToast({
          message: outcome.importedAsNew ? '已恢复为新笔记' : '已恢复未保存内容',
          duration: 2000
        });

        // 恢复后跳转到笔记编辑页（WhiteboardPage）
        router.pushUrl({
          url: 'pages/WhiteboardPage',
          params: {
            noteId: outcome.noteId,
            title: outcome.title
          }
        }).catch((err: Error) => {
          promptAction.showToast({ message: '已恢复，请到笔记列表打开', duration: 2500 });
        });
      } else {
        promptAction.showToast({ message: `恢复失败：${outcome.errorMessage}`, duration: 3000 });
      }
    } catch (error) {
      Logger.error('CrashRecoveryDialog', '恢复失败: ' + JSON.stringify(error));
      promptAction.showToast({ message: '恢复异常，未保存内容仍保留，可重试', duration: 3000 });
    }
  }
  
  /**
   * 处理丢弃
   */
  private async handleDiscard(): Promise<void> {
    try {
      await crashRecoveryService.clearRecoveryData();

      // 调用丢弃回调
      if (this.onDiscard) {
        this.onDiscard();
      }

      // 关闭对话框
      this.controller.close();
      // 🔧 v2.5.5：丢弃操作也要有可见反馈
      promptAction.showToast({ message: '已丢弃未保存内容', duration: 2000 });
    } catch (error) {
      Logger.error('CrashRecoveryDialog', '丢弃失败: ' + JSON.stringify(error));
      promptAction.showToast({ message: '丢弃失败，请重试', duration: 2500 });
    }
  }
}
