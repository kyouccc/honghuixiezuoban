/**
 * BookmarkBar.ets — 书签三类快捷栏（NOTE-03，阶段2）
 *
 * 顶部书签栏：三个类型按钮（必背/易错/真题），点击展开该类书签列表，点列表项跳转。
 * 颜色：必背=红、易错=橙、真题=蓝（设计令牌语义色）。
 */

import { BookmarkData, BookmarkType } from '../engine/types/BoardModel';
import { HCColor, HCRadius, HCSpace } from '../common/theme/DesignTokens';

/** v2.6.0：@Builder 按引用传参类型（ArkTS 禁止匿名对象字面量作类型） */
interface BookmarkTypeBtnParam {
  type: string;
  color: string;
  active: boolean;
}

@Component
export struct BookmarkBar {
  @Prop bookmarks: BookmarkData[] = [];
  @Prop currentNodeId: string = '';
  @Prop open: boolean = true;
  /** 选中某书签 → 跳转该节点 */
  onJump: (bm: BookmarkData) => void = () => {};
  /** 给当前节点加/取消书签 */
  onToggle: (type: string) => void = () => {};

  @State expandedType: string = '';

  build(): void {
    Column() {
      if (this.open) {
        Row() {
          this.typeBtn({ type: BookmarkType.MUST_RECITE, color: '#E5484D', active: this.expandedType === BookmarkType.MUST_RECITE })
          this.typeBtn({ type: BookmarkType.EASY_WRONG, color: '#F2A100', active: this.expandedType === BookmarkType.EASY_WRONG })
          this.typeBtn({ type: BookmarkType.REAL_QUESTION, color: '#2D7FF9', active: this.expandedType === BookmarkType.REAL_QUESTION })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: HCSpace.SM, bottom: HCSpace.SM })

        if (this.expandedType !== '') {
          this.bookmarkList(this.expandedType)
        }
      }
    }
    .width('100%')
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.BORDER })
    .borderRadius(HCRadius.MD)
  }

  /** v2.6.0：对象字面量传参（按引用）→ 选中高亮随 expandedType 实时刷新 */
  @Builder
  typeBtn($$: BookmarkTypeBtnParam) {
    Button($$.type)
      .fontSize(12)
      .height(32)
      .backgroundColor($$.active ? $$.color : HCColor.SURFACE)
      .fontColor($$.active ? '#FFFFFF' : HCColor.TEXT_PRIMARY)
      .border({ width: 1, color: $$.color })
      .borderRadius(HCRadius.SM)
      .margin({ left: HCSpace.SM, right: HCSpace.SM })
      .onClick(() => {
        this.expandedType = $$.active ? '' : $$.type;
      })
  }

  @Builder
  bookmarkList(type: string) {
    Column() {
      if (this.bookmarks.filter((b: BookmarkData) => b.type === type).length === 0) {
        Text('暂无' + type + '书签')
          .fontSize(11)
          .fontColor(HCColor.TEXT_TERTIARY)
          .padding(HCSpace.SM)
      } else {
        ForEach(this.bookmarks.filter((b: BookmarkData) => b.type === type), (bm: BookmarkData) => {
          Row() {
            Text(bm.label !== '' ? bm.label : '未命名节点')
              .fontSize(12)
              .fontColor(bm.nodeId === this.currentNodeId ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY)
              .flexGrow(1)
            Text('跳转')
              .fontSize(11)
              .fontColor(HCColor.PRIMARY)
              .onClick(() => { this.onJump(bm); })
          }
          .width('100%')
          .padding({ left: HCSpace.MD, right: HCSpace.MD, top: HCSpace.XS, bottom: HCSpace.XS })
          .onClick(() => { this.onJump(bm); })
        }, (bm: BookmarkData) => bm.id)
      }
    }
    .width('100%')
    .padding({ bottom: HCSpace.SM })
  }
}
