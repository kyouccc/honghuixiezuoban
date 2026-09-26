/**
 * PaperPicker.ets — 新建笔记面板：标题输入 + 底纸模板选择（v2.4 阶段一，T1-4）
 *
 * 用途：
 *  NotePage 点「+」后弹出的浮层内容。用户填标题、挑底纸，确认后回调给页面去建笔记。
 *
 * 设计取舍：
 *  - 不用 CustomDialog / bindSheet，改为「父页面 Stack 浮层 + 条件渲染」。
 *    原因：条件渲染天然让 @State 每次打开都复位，不需要手工 reset，
 *    也避免不同 SDK 版本对话框 API 行为差异带来的兼容风险。
 *  - 底纸缩略图直接调 NoteEngine.renderPaper 真绘制（而不是贴图），
 *    这样「选择器里看到的」和「画布上画出来的」永远是同一套渲染代码（A1-3）。
 *
 * 输入：paperOptions（底纸列表）、defaultTitle
 * 输出：onConfirm(title, template) / onCancel()
 */

import { NoteEngine } from '../engine/NoteEngine';
import { PaperOption } from '../engine/types/NoteModel';
import { HCColor } from '../common/theme/DesignTokens';
// HitTestMode 为 ArkUI 全局内置枚举，无需显式导入

/** 单个底纸缩略图：直接复用引擎渲染，所见即所得 */
@Component
struct PaperThumb {
  template: string = 'blank';
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  private ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);

  build() {
    Canvas(this.ctx)
      .width(56)
      .height(72)
      .backgroundColor(HCColor.SURFACE)
      .hitTestBehavior(HitTestMode.None)
      .onReady((): void => {
        NoteEngine.getInstance().renderPaper(this.ctx, this.template, 56, 72);
      })
  }
}

@Component
export struct PaperPicker {
  /** 底纸候选项（由 NotePage 经 NoteEngine.getPaperOptions() 传入） */
  paperOptions: PaperOption[] = [];
  /** 打开时预填的标题 */
  defaultTitle: string = '';
  /** 确认回调 */
  onConfirm: (title: string, template: string) => void = (): void => {
  };
  /** 取消回调 */
  onCancel: () => void = (): void => {
  };

  @State private localTitle: string = '';
  @State private localTemplate: string = 'blank';

  aboutToAppear(): void {
    this.localTitle = this.defaultTitle;
    this.localTemplate = this.paperOptions.length > 0 ? this.paperOptions[0].template : 'blank';
  }

  build() {
    Column() {
      // ── 抓手 ──
      Row()
        .width(36)
        .height(4)
        .borderRadius(2)
        .backgroundColor(HCColor.BORDER)
        .margin({ top: 10, bottom: 14 })

      Text('新建笔记')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .width('100%')
        .padding({ left: 20, right: 20 })

      // ── 标题 ──
      Text('标题')
        .fontSize(13)
        .fontColor(HCColor.ICON_SECONDARY)
        .width('100%')
        .padding({ left: 20, right: 20 })
        .margin({ top: 16, bottom: 6 })

      TextInput({ text: this.localTitle, placeholder: '未命名笔记' })
        .maxLength(60)
        .height(44)
        .fontSize(15)
        .backgroundColor(HCColor.DIVIDER)
        .borderRadius(10)
        .margin({ left: 20, right: 20 })
        .onChange((value: string): void => {
          this.localTitle = value;
        })

      // ── 底纸 ──
      Text('底纸')
        .fontSize(13)
        .fontColor(HCColor.ICON_SECONDARY)
        .width('100%')
        .padding({ left: 20, right: 20 })
        .margin({ top: 18, bottom: 8 })

      Scroll() {
        Row() {
          ForEach(this.paperOptions, (item: PaperOption): void => {
            Column() {
              Stack() {
                PaperThumb({ template: item.template })
              }
              .width(58)
              .height(74)
              .borderRadius(6)
              .clip(true)
              .border({
                width: this.localTemplate === item.template ? 2 : 1,
                color: this.localTemplate === item.template ? HCColor.PRIMARY : HCColor.BORDER
              })

              Text(item.name)
                .fontSize(12)
                .margin({ top: 6 })
                .fontColor(this.localTemplate === item.template ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY)
            }
            .margin({ right: 12 })
            .onClick((): void => {
              this.localTemplate = item.template;
            })
          }, (item: PaperOption): string => item.template)
        }
        .padding({ left: 20, right: 20 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(104)
      // v2.5.2 审核修复：滑动到边界需有反馈动效
      .edgeEffect(EdgeEffect.Spring)

      // ── 操作 ──
      Row() {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(HCColor.TEXT_SECONDARY)
          .backgroundColor(HCColor.DIVIDER)
          .onClick((): void => {
            this.onCancel();
          })

        Blank().width(12)

        Button('创建')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Color.White)
          .backgroundColor(HCColor.PRIMARY)
          .onClick((): void => {
            this.onConfirm(this.localTitle, this.localTemplate);
          })
      }
      .width('100%')
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
    .width('100%')
    .backgroundColor(Color.White)
    .borderRadius({ topLeft: 18, topRight: 18 })
  }
}
