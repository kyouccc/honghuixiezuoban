/**
 * 用户反馈对话框组件
 * 支持文字反馈、截图上传、评分功能
 */
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { analytics, AnalyticsEvent } from '../common/services/AnalyticsService';
import { HCColor } from '../common/theme/DesignTokens';

const TAG = 'FeedbackDialog';
const DOMAIN = 0x0000;

export enum FeedbackType {
  BUG_REPORT = 'bug_report',
  FEATURE_REQUEST = 'feature_request',
  GENERAL = 'general',
  RATING = 'rating'
}

interface FeedbackTrackProps extends Record<string, string | number | boolean> {
  feedback_type: FeedbackType;
  rating: number;
  has_screenshot: boolean;
  text_length: number;
}

interface FeedbackData {
  type: FeedbackType;
  rating: number;
  content: string;
  includeScreenshot: boolean;
  timestamp: number;
  deviceId: string;
  appVersion: string;
}

@Component
export struct FeedbackDialog {
  @Link isVisible: boolean;
  @State feedbackType: FeedbackType = FeedbackType.GENERAL;
  @State feedbackText: string = '';
  @State rating: number = 0;
  @State isSubmitting: boolean = false;
  @State includeScreenshot: boolean = false;
  
  private context: common.UIAbilityContext | null = null;
  
  aboutToAppear(): void {
    try {
      this.context = getContext(this) as common.UIAbilityContext;
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to get context: ${JSON.stringify(error)}`);
    }
  }

  build() {
    Stack() {
      if (this.isVisible) {
      // 遮罩层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.4)')
        .onClick(() => {
          this.isVisible = false;
        })

      // 对话框内容
      Column() {
        // 标题
        Row() {
          Text('反馈与建议')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor(HCColor.TEXT_PRIMARY)
          
          Blank()
          
          Button({ type: ButtonType.Circle }) {
            Text('×')
              .fontSize(24)
              .fontColor(HCColor.TEXT_TERTIARY)
          }
          .width(32)
          .height(32)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.isVisible = false;
          })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 16 })

        Divider().color('#e0e0e0')

        // 反馈类型选择
        Column() {
          Text('反馈类型')
            .fontSize(14)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ bottom: 8 })

          Row() {
            this.TypeButton('问题反馈', FeedbackType.BUG_REPORT)
            this.TypeButton('功能建议', FeedbackType.FEATURE_REQUEST)
            this.TypeButton('其他', FeedbackType.GENERAL)
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 16, bottom: 16 })
        .alignItems(HorizontalAlign.Start)

        // 评分（可选）
        if (this.feedbackType === FeedbackType.BUG_REPORT) {
          Column() {
            Text('问题严重程度')
              .fontSize(14)
              .fontColor(HCColor.TEXT_TERTIARY)
              .margin({ bottom: 8 })

            Row() {
              ForEach([1, 2, 3, 4, 5], (level: number) => {
                Button({ type: ButtonType.Circle }) {
                  Text(level.toString())
                    .fontSize(16)
                    .fontColor(this.rating >= level ? HCColor.SURFACE : HCColor.TEXT_TERTIARY)
                }
                .width(36)
                .height(36)
                .backgroundColor(this.rating >= level ? '#FF6B6B' : '#f0f0f0')
                .onClick(() => {
                  this.rating = level;
                })
              })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceEvenly)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 8, bottom: 16 })
          .alignItems(HorizontalAlign.Start)
        }

        // 反馈内容
        Column() {
          Text('详细描述')
            .fontSize(14)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ bottom: 8 })

          TextArea({ placeholder: '请详细描述您遇到的问题或建议...' })
            .width('100%')
            .height(120)
            .fontSize(14)
            .fontColor(HCColor.TEXT_PRIMARY)
            .placeholderColor(HCColor.ICON_SECONDARY)
            .backgroundColor('#f5f5f5')
            .borderRadius(8)
            .padding(12)
            .onChange((value: string) => {
              this.feedbackText = value;
            })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 8, bottom: 16 })
        .alignItems(HorizontalAlign.Start)

        // 附加选项
        Row() {
          Toggle({ type: ToggleType.Checkbox, isOn: this.includeScreenshot })
            .onChange((isOn: boolean) => {
              this.includeScreenshot = isOn;
            })
          
          Text('包含当前屏幕截图')
            .fontSize(14)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ left: 8 })
        }
        .width('100%')
        .padding({ left: 20, right: 20, bottom: 16 })

        // 提交按钮
        Button(this.isSubmitting ? '提交中...' : '提交反馈')
          .width('100%')
          .height(48)
          .fontSize(16)
          .fontColor(HCColor.SURFACE)
          .backgroundColor(this.isSubmitting ? HCColor.TEXT_DISABLED : '#4A90E2')
          .borderRadius(24)
          .enabled(!this.isSubmitting && this.feedbackText.length > 0)
          .margin({ left: 20, right: 20, bottom: 20 })
          .onClick(() => {
            this.submitFeedback();
          })
      }
      .width('85%')
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(16)
      .shadow({
        radius: 20,
        color: 'rgba(0, 0, 0, 0.15)',
        offsetX: 0,
        offsetY: 4
      })
      .position({ x: '7.5%', y: '20%' })
      .zIndex(1000)
      }
    }
    .width('100%')
    .height('100%')
    // CRITICAL: 空状态时不拦截触摸，否则会挡住下层画布的 onTouch 事件，导致写不上东西
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  TypeButton(text: string, type: FeedbackType) {
    Button(text)
      .fontSize(13)
      .fontColor(this.feedbackType === type ? HCColor.SURFACE : HCColor.TEXT_TERTIARY)
      .backgroundColor(this.feedbackType === type ? '#4A90E2' : '#f0f0f0')
      .borderRadius(16)
      .height(32)
      .padding({ left: 12, right: 12 })
      .onClick(() => {
        this.feedbackType = type;
      })
  }

  /**
   * 提交反馈
   */
  private async submitFeedback(): Promise<void> {
    this.isSubmitting = true;

    try {
      // 记录埋点
      const trackProps: FeedbackTrackProps = {
        feedback_type: this.feedbackType,
        rating: this.rating,
        has_screenshot: this.includeScreenshot,
        text_length: this.feedbackText.length
      };
      analytics.track(AnalyticsEvent.FEEDBACK_SUBMIT, trackProps);

      // 构建反馈数据
      const feedbackData: FeedbackData = {
        type: this.feedbackType,
        rating: this.rating,
        content: this.feedbackText,
        includeScreenshot: this.includeScreenshot,
        timestamp: Date.now(),
        deviceId: AppStorage.get<string>('siteId') || 'unknown',
        appVersion: '2.0.0'
      };

      // 诚实条款（F-08）：当前版本无上传通道，反馈仅记录到本地；
      // 接入服务端反馈接口后再启用实际上传（见 todo 跟踪项）。
      hilog.info(DOMAIN, TAG, `Feedback recorded locally: ${JSON.stringify(feedbackData)}`);

      // 显示成功提示（如实措辞，不暗示已送达服务器）
      this.showSuccessToast();
      
      // 关闭对话框
      this.isVisible = false;
      
      // 重置状态
      this.feedbackText = '';
      this.rating = 0;
      this.includeScreenshot = false;
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to submit feedback: ${JSON.stringify(error)}`);
      this.showErrorToast();
    } finally {
      this.isSubmitting = false;
    }
  }

  /**
   * 显示成功提示
   */
  private showSuccessToast(): void {
    // 如实提示：数据已记录到本地，当前版本暂不上传（无上传通道）。
    hilog.info(DOMAIN, TAG, 'Feedback recorded locally (no upload channel yet)');
    try {
      promptAction.showToast({
        message: '已记录到本地（当前版本暂不上传）',
        duration: 2000
      });
    } catch (error) {
      hilog.error(DOMAIN, TAG, `showToast failed: ${JSON.stringify(error)}`);
    }
  }

  /**
   * 显示错误提示
   */
  private showErrorToast(): void {
    hilog.error(DOMAIN, TAG, 'Failed to submit feedback');
  }
}
