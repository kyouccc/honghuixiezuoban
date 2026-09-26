/**
 * SearchBar.ets — 端侧全文检索浮层（NOTE-04，阶段2）
 *
 * 顶部搜索框 + 命中结果列表。输入关键词 → 调 HandwritingIndex.search → 列出命中片段，
 * 点结果项跳转到对应节点。隐私不下云，纯本地索引。
 */

import { SearchHit } from '../engine/HandwritingIndex';
import { HCColor, HCRadius, HCSpace } from '../common/theme/DesignTokens';
import { IconComponent } from '../common/components/IconComponent';
import { IconSymbols } from '../common/IconConstants';

@Component
export struct SearchBar {
  @Prop hits: SearchHit[] = [];
  @Prop open: boolean = false;
  onSearch: (kw: string) => void = () => {};
  onJump: (hit: SearchHit) => void = () => {};
  onClose: () => void = () => {};

  @State keyword: string = '';

  build(): void {
    Column() {
      if (this.open) {
        Row() {
          TextInput({ placeholder: '搜索笔记内容…', text: this.keyword })
            .width('80%')
            .height(36)
            .backgroundColor(HCColor.SURFACE)
            .border({ width: 1, color: HCColor.BORDER })
            .borderRadius(HCRadius.SM)
            .onChange((v: string) => {
              this.keyword = v;
              this.onSearch(v);
            })
          IconComponent({ symbol: IconSymbols.CLOSE, iconSize: 20, color: HCColor.TEXT_SECONDARY })
            .width(36)
            .height(36)
            .onClick(() => { this.onClose(); })
        }
        .width('100%')
        .padding({ left: HCSpace.MD, right: HCSpace.MD, top: HCSpace.SM, bottom: HCSpace.SM })

        if (this.hits.length === 0 && this.keyword.length > 0) {
          Text('无匹配结果')
            .fontSize(12)
            .fontColor(HCColor.TEXT_TERTIARY)
            .padding(HCSpace.MD)
        } else {
          ForEach(this.hits, (hit: SearchHit) => {
            Row() {
              Text(hit.snippet)
                .fontSize(12)
                .fontColor(HCColor.TEXT_PRIMARY)
                .flexGrow(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: HCSpace.MD, right: HCSpace.MD, top: HCSpace.SM, bottom: HCSpace.SM })
            .onClick(() => { this.onJump(hit); })
          }, (hit: SearchHit) => hit.nodeId + hit.x + hit.y)
        }
      }
    }
    .width('100%')
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.BORDER })
    .borderRadius(HCRadius.MD)
  }
}
