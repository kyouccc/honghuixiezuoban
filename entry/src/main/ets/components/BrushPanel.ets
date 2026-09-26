/**
 * BrushPanel.ets — 笔刷面板（v2.4 阶段一 T1-5 新建）
 *
 * 职责：
 *  1. 展示 NoteEngine 注册表里的全部笔刷（钢笔 / 铅笔 / 马克笔 / 高亮笔 / 毛笔…），
 *     所见即所得地预览「颜色 + 粗细 + 透明度」三要素；
 *  2. 把选中的笔刷 tool 与线宽回调给白板页，由白板页写入笔画记录。
 *
 * 设计约束：
 *  - 本组件**不** import BrushRegistry 等引擎实现类，只消费页面友好类型 BrushOption（共识 F-1）；
 *  - 不使用 CustomDialog / bindSheet，由父页以 Stack 浮层 + 条件渲染方式挂载，
 *    规避不同 API 版本对话框行为差异；
 *  - 无内部业务状态，纯受控组件：选中态完全由父页的 currentTool / currentWidth 决定。
 */

import { BrushOption } from '../engine/types/NoteModel';
import { HCColor } from '../common/theme/DesignTokens';

/** 线宽档位（与白板页 widths 保持一致，避免两处出现不同粒度） */
const WIDTH_STEPS: number[] = [1, 2, 3, 5, 8, 12, 20];

/** 空笔刷占位（ArkTS 要求成员必须有初始值） */
function emptyBrush(): BrushOption {
  return {
    tool: 'pen',
    name: '钢笔',
    brushShape: 'round',
    opacity: 1,
    blendMode: 'normal',
    minWidth: 1,
    maxWidth: 20,
  };
}

/** v2.6.0：@Builder 按引用传参类型（ArkTS 禁止匿名对象字面量作类型） */
interface BrushRowParam {
  brush: BrushOption;
  selected: boolean;
  curWidth: number;
  curColor: string;
}

@Component
export struct BrushPanel {
  /** 全部可选笔刷（父页从 NoteEngine.getBrushOptions() 取得） */
  @Prop brushOptions: BrushOption[] = [];
  /** 当前笔刷 tool */
  @Prop currentTool: string = 'pen';
  /** 当前线宽 */
  @Prop currentWidth: number = 3;
  /** 当前颜色（用于预览条着色） */
  @Prop currentColor: string = '#000000';

  /** 选中某支笔 */
  onPickBrush: (tool: string) => void = (tool: string) => {};
  /** 调整线宽 */
  onPickWidth: (width: number) => void = (width: number) => {};
  /** 设 新增：调整颜色 */
  onPickColor: (color: string) => void = (color: string) => {};
  /** 关闭面板 */
  onClose: () => void = () => {};

  /** 取当前笔刷配置（找不到时回退第一支 / 空占位） */
  private activeBrush(): BrushOption {
    for (let i = 0; i < this.brushOptions.length; i++) {
      if (this.brushOptions[i].tool === this.currentTool) {
        return this.brushOptions[i];
      }
    }
    return this.brushOptions.length > 0 ? this.brushOptions[0] : emptyBrush();
  }

  /** 线宽档位是否落在当前笔刷允许区间内 */
  private widthAllowed(w: number): boolean {
    const brush: BrushOption = this.activeBrush();
    return w >= brush.minWidth && w <= brush.maxWidth;
  }

  /** 透明度徽标文案（高亮笔等半透明笔刷给出显式提示） */
  private opacityBadge(brush: BrushOption): string {
    if (brush.opacity >= 1) {
      return '';
    }
    return `${Math.round(brush.opacity * 100)}%`;
  }

  build() {
    Column() {
      // ── 标题栏 ──
      Row() {
        Text('笔刷')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(HCColor.TEXT_PRIMARY)

        Blank()

        Text(this.activeBrush().name)
          .fontSize(12)
          .fontColor(HCColor.ICON_SECONDARY)
          .margin({ right: 10 })

        Text('×')
          .fontSize(15)
          .fontColor(HCColor.ICON_SECONDARY)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .onClick(() => this.onClose())
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 10, bottom: 6 })

      // ── 笔刷列表 ──
      Scroll() {
        Column() {
          ForEach(this.brushOptions, (brush: BrushOption) => {
            this.brushRow({
              brush: brush,
              selected: this.currentTool === brush.tool,
              curWidth: this.currentWidth,
              curColor: this.currentColor
            });
          }, (brush: BrushOption) => brush.tool)
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 240 })
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      // v2.5.2 审核修复：滑动到边界需有反馈动效
      .edgeEffect(EdgeEffect.Spring)

      Divider().color(HCColor.DIVIDER).margin({ top: 4, bottom: 8 })

      // ── 线宽档位 ──
      Row() {
        Text('粗细')
          .fontSize(12)
          .fontColor(HCColor.ICON_SECONDARY)
          .margin({ right: 8 })

        ForEach(WIDTH_STEPS, (w: number) => {
          Stack() {
            Circle()
              .width(Math.max(4, Math.min(w, 18)))
              .height(Math.max(4, Math.min(w, 18)))
              .fill(this.widthAllowed(w) ? this.currentColor : HCColor.BORDER)
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.currentWidth === w ? HCColor.PRIMARY_BG : HCColor.SURFACE)
          .border({
            width: this.currentWidth === w ? 2 : 1,
            color: this.currentWidth === w ? HCColor.PRIMARY : HCColor.DIVIDER,
          })
          .margin({ right: 4 })
          .onClick(() => {
            if (!this.widthAllowed(w)) {
              return;
            }
            this.onPickWidth(w);
          })
        }, (w: number) => `w_${w}`)
      }
      .width('100%')
      .padding({ left: 16, right: 12, bottom: 12 })

      Divider().color(HCColor.DIVIDER).margin({ top: 4, bottom: 8 })

      // ── 设 新增：颜色选择器 ──
      Row() {
        Text('颜色')
          .fontSize(12)
          .fontColor(HCColor.ICON_SECONDARY)
          .margin({ right: 8 })

        ForEach([
          '#000000', '#FF0000', HCColor.PRIMARY, '#00AA00', '#FFAA00', '#AA00FF', '#FF00AA', '#00AAAA'
        ], (color: string) => {
          Stack() {
            Circle()
              .width(24)
              .height(24)
              .fill(color)
          }
          .width(34)
          .height(34)
          .borderRadius(17)
          .backgroundColor(this.currentColor === color ? HCColor.PRIMARY_BG : HCColor.SURFACE)
          .border({
            width: this.currentColor === color ? 2 : 1,
            color: this.currentColor === color ? HCColor.PRIMARY : HCColor.DIVIDER,
          })
          .margin({ right: 4 })
          .onClick(() => {
            this.onPickColor(color);
          })
        }, (color: string) => `color_${color}`)
      }
      .width('100%')
      .padding({ left: 16, right: 12, bottom: 12 })
    }
    .width('100%')
    .backgroundColor(HCColor.SURFACE)
    .borderRadius({ topLeft: 18, topRight: 18 })
    .shadow({ radius: 18, color: '#22000000', offsetX: 0, offsetY: -4 })
  }

  /**
   * 单支笔刷行：名称 + 预览条（颜色/粗细/透明度所见即所得）。
   * v2.6.0：改为对象字面量传参（按引用）。原 `brushRow(brush)` 虽然传的是对象，
   *   但 brush 取自静态数组、内容永不变化，ArkUI 判为无变化 → 不重渲染，
   *   于是选笔刷后 ✓ 与高亮不动。现把「是否选中 / 当前线宽 / 当前颜色」一并放进参数对象。
   */
  @Builder
  brushRow($$: BrushRowParam) {
    Row() {
      Text($$.brush.name)
        .fontSize(13)
        .fontColor($$.selected ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY)
        .fontWeight($$.selected ? FontWeight.Bold : FontWeight.Normal)
        .width(64)

      // 预览条：宽度取当前线宽（clamp 到该笔刷区间），透明度取笔刷 opacity
      Row()
        .height(Math.max(2, Math.min($$.curWidth, $$.brush.maxWidth)))
        .layoutWeight(1)
        .backgroundColor($$.curColor)
        .opacity($$.brush.opacity)
        .borderRadius($$.brush.brushShape === 'flat' ? 1 : 10)
        .margin({ left: 4, right: 8 })

      if (this.opacityBadge($$.brush).length > 0) {
        Text(this.opacityBadge($$.brush))
          .fontSize(10)
          .fontColor('#FF9800')
          .backgroundColor(HCColor.WARNING_BG)
          .borderRadius(4)
          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
          .margin({ right: 6 })
      }

      Text($$.selected ? '✓' : '')
        .fontSize(13)
        .fontColor(HCColor.PRIMARY)
        .width(16)
    }
    .width('100%')
    .height(42)
    .padding({ left: 16, right: 12 })
    .backgroundColor($$.selected ? HCColor.PRIMARY_BG : HCColor.SURFACE)
    .onClick(() => this.onPickBrush($$.brush.tool))
  }
}
