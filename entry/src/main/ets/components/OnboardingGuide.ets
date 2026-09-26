/**
 * 新手引导组件
 * 在首次使用时显示功能介绍和操作指引
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { analytics } from '../common/services/AnalyticsService';
import { HCColor } from '../common/theme/DesignTokens';

const TAG = 'OnboardingGuide';
const DOMAIN = 0x0000;

export interface GuideStep {
  id: string;
  title: string;
  description: string;
  icon: string;
  highlight?: string; // 高亮的 UI 元素选择器
}

const GUIDE_STEPS: GuideStep[] = [
  {
    id: 'welcome',
    title: '欢迎使用鸿绘协作板',
    description: '一款支持多设备实时协作的智能白板应用',
    icon: '画'
  },
  {
    id: 'tools',
    title: '绘图工具',
    description: '选择画笔、橡皮擦或形状工具进行绘制',
    icon: '笔',
    highlight: '.tool-bar'
  },
  {
    id: 'colors',
    title: '丰富的颜色',
    description: '点击颜色按钮选择 16 种预设颜色',
    icon: '画',
    highlight: '.color-picker'
  },
  {
    id: 'shapes',
    title: '形状工具',
    description: '绘制矩形、圆形、箭头和直线',
    icon: '空',
    highlight: '.shape-picker'
  },
  {
    id: 'undo_redo',
    title: '撤销与重做',
    description: '使用撤销/重做按钮修正操作',
    icon: '回',
    highlight: '.undo-redo'
  },
  {
    id: 'export',
    title: '导出作品',
    description: '将白板内容导出为图片',
    icon: '出',
    highlight: '.export-btn'
  },
  {
    id: 'collaboration',
    title: '多人协作',
    description: '邀请他人加入房间，实时协同绘制',
    icon: '人'
  },
  {
    id: 'feedback',
    title: '反馈与建议',
    description: '遇到问题或有建议？点击反馈按钮告诉我们',
    icon: '话',
    highlight: '.feedback-btn'
  }
];

@Component
export struct OnboardingGuide {
  @Link isVisible: boolean;
  @State currentStep: number = 0;
  @State isAnimating: boolean = false;
  
  private context: common.UIAbilityContext | null = null;
  
  aboutToAppear(): void {
    try {
      this.context = getContext(this) as common.UIAbilityContext;
    } catch (error) {
      hilog.error(DOMAIN, TAG, `Failed to get context: ${JSON.stringify(error)}`);
    }
  }

  build() {
    if (!this.isVisible) {
      return;
    }

    Column() {
      // 遮罩层
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0, 0, 0, 0.6)')
        .onClick(() => {
          // 点击遮罩不关闭
        })
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .zIndex(999)

    // 引导卡片
    Column() {
      // 进度指示器
      Row() {
        ForEach(GUIDE_STEPS, (step: GuideStep, index: number) => {
          Column()
            .width(this.currentStep === index ? 24 : 8)
            .height(8)
            .backgroundColor(this.currentStep === index ? '#4A90E2' : HCColor.TEXT_DISABLED)
            .borderRadius(4)
            .margin({ right: 4 })
        })
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
      .margin({ top: 20, bottom: 20 })

      // 图标
      Text(GUIDE_STEPS[this.currentStep].icon)
        .fontSize(64)
        .margin({ bottom: 20 })

      // 标题
      Text(GUIDE_STEPS[this.currentStep].title)
        .fontSize(24)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ bottom: 12 })

      // 描述
      Text(GUIDE_STEPS[this.currentStep].description)
        .fontSize(16)
        .fontColor(HCColor.TEXT_TERTIARY)
        .textAlign(TextAlign.Center)
        .lineHeight(24)
        .padding({ left: 32, right: 32 })
        .margin({ bottom: 32 })

      // 按钮区域
      Row() {
        // 跳过按钮
        if (this.currentStep < GUIDE_STEPS.length - 1) {
          Button('跳过')
            .fontSize(16)
            .fontColor(HCColor.TEXT_TERTIARY)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.skipGuide();
            })
        }

        Blank()

        // 下一步/完成按钮
        Button(this.currentStep < GUIDE_STEPS.length - 1 ? '下一步' : '开始使用')
          .fontSize(16)
          .fontColor(HCColor.SURFACE)
          .backgroundColor('#4A90E2')
          .borderRadius(24)
          .width(120)
          .height(44)
          .onClick(() => {
            this.nextStep();
          })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 24 })
    }
    .width('85%')
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(20)
    .shadow({
      radius: 30,
      color: 'rgba(0, 0, 0, 0.2)',
      offsetX: 0,
      offsetY: 10
    })
    .position({ x: '7.5%', y: '30%' })
    .zIndex(1000)
  }

  /**
   * 下一步
   */
  private nextStep(): void {
    if (this.currentStep < GUIDE_STEPS.length - 1) {
      this.currentStep++;
      
      // 记录埋点
      analytics.track('onboarding_step', { 
        step_id: GUIDE_STEPS[this.currentStep].id,
        step_index: this.currentStep
      });
    } else {
      this.completeGuide();
    }
  }

  /**
   * 跳过引导
   */
  private skipGuide(): void {
    analytics.track('onboarding_skipped', { 
      step_index: this.currentStep,
      total_steps: GUIDE_STEPS.length
    });
    
    this.completeGuide();
  }

  /**
   * 完成引导
   */
  private async completeGuide(): Promise<void> {
    this.isVisible = false;
    
    // 保存引导完成状态
    if (this.context) {
      try {
        const prefs = await preferences.getPreferences(this.context, 'onboarding');
        await prefs.put('completed', true);
        await prefs.put('completedAt', Date.now());
        await prefs.flush();
        
        hilog.info(DOMAIN, TAG, 'Onboarding completed');
      } catch (error) {
        hilog.error(DOMAIN, TAG, `Failed to save onboarding state: ${JSON.stringify(error)}`);
      }
    }
    
    // 记录埋点
    analytics.track('onboarding_completed');
  }
}

/**
 * 检查是否需要显示引导
 */
export async function shouldShowOnboarding(context: common.UIAbilityContext): Promise<boolean> {
  try {
    const prefs = await preferences.getPreferences(context, 'onboarding');
    const completed = await prefs.get('completed', false) as boolean;
    return !completed;
  } catch (error) {
    hilog.error(DOMAIN, TAG, `Failed to check onboarding state: ${JSON.stringify(error)}`);
    return true;
  }
}
