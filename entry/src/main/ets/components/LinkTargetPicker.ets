/**
 * LinkTargetPicker.ets — 双链目标选择浮层（NOTE-02，阶段2 P1）
 *
 * 交互流程（指令集规定）：长按圈选笔迹 → 弹出悬浮菜单 → 点击「链接到知识点」→ 本浮层
 *
 * 功能：
 *  1. 顶部展示 TF-IDF 智能推荐节点（按相关度排序，高亮命中关键词）
 *  2. 搜索框可手动搜索其他节点（跨画布搜索由上层注入）
 *  3. 点击目标节点 → 回调 onSelect 完成建链
 *  4. 连线默认半透明隐藏，选中节点时高亮显示（避免画布杂乱）
 */

import { RecommendItem } from '../engine/TfidfRecommender';
import { SearchHit } from '../engine/HandwritingIndex';
import { HCColor, HCRadius, HCSpace, HCFont } from '../common/theme/DesignTokens';
import { IconComponent } from '../common/components/IconComponent';
import { IconSymbols } from '../common/IconConstants';

/** v2.6.0：@Builder 按引用传参类型（ArkTS 禁止匿名对象字面量作类型） */
interface LinkTabBtnParam {
  label: string;
  index: number;
  count: number;
  active: boolean;
}

@Component
export struct LinkTargetPicker {
  /** 智能推荐列表（TF-IDF） */
  @Prop recommendations: RecommendItem[] = [];
  /** 搜索命中列表（手动搜索） */
  @Prop searchHits: SearchHit[] = [];
  /** 浮层开关 */
  @Prop open: boolean = false;
  /** 源节点摘要（展示用） */
  @Prop sourceSnippet: string = '';
  /** 是否正在搜索 */
  @Prop searching: boolean = false;

  /** 选中目标节点 */
  onSelect: (nodeId: string) => void = () => {};
  /** 搜索输入回调 */
  onSearch: (keyword: string) => void = () => {};
  /** 关闭浮层 */
  onClose: () => void = () => {};

  @State keyword: string = '';
  @State activeTab: number = 0; // 0=推荐, 1=搜索

  build(): void {
    if (this.open) {
      Stack({ alignContent: Alignment.Center }) {
        // 遮罩
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(HCColor.MASK)
          .onClick(() => this.onClose())

        // 浮层主体
        Column() {
          // 标题栏
          Row() {
            Text('链接到知识点')
              .fontSize(HCFont.TITLE)
              .fontWeight(FontWeight.Medium)
              .fontColor(HCColor.TEXT_PRIMARY)
              .layoutWeight(1)

            IconComponent({ symbol: IconSymbols.CLOSE, iconSize: 18, color: HCColor.TEXT_SECONDARY })
              .width(32)
              .height(32)
              .onClick(() => this.onClose())
          }
          .width('100%')
          .padding({ left: HCSpace.MD, right: HCSpace.SM, top: HCSpace.SM, bottom: HCSpace.XS })

          // 源节点摘要
          if (this.sourceSnippet.length > 0) {
            Text(`源：${this.sourceSnippet}`)
              .fontSize(HCFont.CAPTION)
              .fontColor(HCColor.TEXT_TERTIARY)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: HCSpace.MD, right: HCSpace.MD, bottom: HCSpace.XS })
          }

          // Tab 切换
          Row() {
            this.tabBtn({ label: '智能推荐', index: 0, count: this.recommendations.length, active: this.activeTab === 0 })
            this.tabBtn({ label: '搜索节点', index: 1, count: this.searchHits.length, active: this.activeTab === 1 })
          }
          .width('100%')
          .padding({ left: HCSpace.MD, right: HCSpace.MD, bottom: HCSpace.XS })

          // 搜索框（仅搜索 Tab 显示）
          if (this.activeTab === 1) {
            Row() {
              TextInput({ placeholder: '输入关键词搜索…', text: this.keyword })
                .width('100%')
                .height(36)
                .backgroundColor(HCColor.SURFACE)
                .border({ width: 1, color: HCColor.BORDER })
                .borderRadius(HCRadius.SM)
                .padding({ left: HCSpace.SM, right: HCSpace.SM })
                .fontSize(HCFont.BODY)
                .onChange((v: string) => {
                  this.keyword = v;
                  this.onSearch(v);
                })
            }
            .width('100%')
            .padding({ left: HCSpace.MD, right: HCSpace.MD, bottom: HCSpace.XS })
          }

          // 内容列表
          Scroll() {
            Column() {
              if (this.activeTab === 0) {
                if (this.recommendations.length === 0) {
                  this.emptyState('暂无推荐节点，可切换到搜索手动查找')
                } else {
                  ForEach(this.recommendations, (item: RecommendItem) => {
                    this.recommendCard(item)
                  }, (item: RecommendItem) => item.nodeId)
                }
              } else {
                if (this.searching) {
                  this.emptyState('搜索中…')
                } else if (this.searchHits.length === 0) {
                  this.emptyState(this.keyword.length > 0 ? '未找到匹配节点' : '输入关键词开始搜索')
                } else {
                  ForEach(this.searchHits, (hit: SearchHit) => {
                    this.searchHitCard(hit)
                  }, (hit: SearchHit) => hit.nodeId)
                }
              }
            }
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          // v2.5.2 审核修复：滑动到边界需有反馈动效
          .edgeEffect(EdgeEffect.Spring)
        }
        .width('85%')
        .height('60%')
        .backgroundColor(HCColor.SURFACE)
        .borderRadius(HCRadius.LG)
        .shadow({ radius: 24, color: 'rgba(0,0,0,0.2)', offsetX: 0, offsetY: 8 })
      }
      .width('100%')
      .height('100%')
    }
  }

  /**
   * v2.6.0：改为对象字面量传参（按引用传递）。
   * 原 tabBtn(label, index, count) 为带参 @Builder，体内读 this.activeTab 决定高亮，
   * 因 ArkUI「按值传递不刷新」导致点击后选中态不动。现把 active 显式放进参数对象。
   */
  @Builder
  tabBtn($$: LinkTabBtnParam): void {
    Text(`${$$.label}${$$.count > 0 ? `(${$$.count})` : ''}`)
      .fontSize(HCFont.CAPTION)
      .fontColor($$.active ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY)
      .fontWeight($$.active ? FontWeight.Medium : FontWeight.Normal)
      .padding({ top: HCSpace.XS, bottom: HCSpace.XS, left: HCSpace.MD, right: HCSpace.MD })
      .borderRadius(HCRadius.SM)
      .backgroundColor($$.active ? HCColor.PRIMARY_BG : HCColor.TRANSPARENT)
      .onClick(() => {
        this.activeTab = $$.index;
      })
      .margin({ right: HCSpace.XS })
  }

  @Builder
  recommendCard(item: RecommendItem): void {
    Row() {
      Column() {
        Text(item.snippet)
          .fontSize(HCFont.BODY)
          .fontColor(HCColor.TEXT_PRIMARY)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (item.keywords.length > 0) {
          Row() {
            ForEach(item.keywords.slice(0, 3), (kw: string) => {
              Text(kw)
                .fontSize(HCFont.TINY)
                .fontColor(HCColor.PRIMARY)
                .backgroundColor(HCColor.PRIMARY_BG)
                .borderRadius(HCRadius.XS)
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .margin({ right: 4 })
            }, (kw: string, index: number) => `${kw}_${index}`)
          }
          .width('100%')
          .margin({ top: 4 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(`${Math.round(item.score * 100)}%`)
        .fontSize(HCFont.CAPTION)
        .fontColor(HCColor.TEXT_TERTIARY)
        .width(36)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(HCSpace.SM)
    .margin({ bottom: HCSpace.XS })
    .borderRadius(HCRadius.SM)
    .backgroundColor(HCColor.PAGE_BG)
    .onClick(() => this.onSelect(item.nodeId))
  }

  @Builder
  searchHitCard(hit: SearchHit): void {
    Row() {
      Text(hit.snippet)
        .fontSize(HCFont.BODY)
        .fontColor(HCColor.TEXT_PRIMARY)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding(HCSpace.SM)
    .margin({ bottom: HCSpace.XS })
    .borderRadius(HCRadius.SM)
    .backgroundColor(HCColor.PAGE_BG)
    .onClick(() => this.onSelect(hit.nodeId))
  }

  @Builder
  emptyState(msg: string): void {
    Column() {
      Text(msg)
        .fontSize(HCFont.BODY_SM)
        .fontColor(HCColor.TEXT_TERTIARY)
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .padding(HCSpace.XL)
  }
}
