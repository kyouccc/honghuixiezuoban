/**
 * ExtendedToolsPanel.ets — 扩展工具面板（v3.0 新功能汇总面板）
 *
 * v3.1 审核修复：仅保留已实现可用的工具项，移除未实现项（之前点击提示"开发中"
 *   不符合 AppGallery 上架要求）。保留项：文本工具、全屏阅读、分享、回收站、
 *   笔盒、版本历史。未实现的扩展项（文档扫描 / 网页剪藏 / 网页嵌入 / LaTeX /
 *   AI 类 / 评论 / 投票 / 分屏 / 水印 / 模板市场 / 数据统计 / 云同步）已全部移除。
 */
import { HCColor } from '../common/theme/DesignTokens';
import { IconSymbols } from '../common/IconConstants';

/** 扩展工具项 */
interface ToolItem {
  key: string;
  label: string;
  icon: string;
  symbol?: string;
  category: 'create' | 'manage' | 'export';
}

const EXTENDED_TOOLS: ToolItem[] = [
  // 创建类（已实现）
  { key: 'text_tool', label: '文本工具', icon: 'T', category: 'create' },
  // 🔧 v2.7.0 审核修复（问题①-4 / ①-5）：
  //   审核反馈「笔记-选择闪卡，提示在笔记内使用扩展工具添加闪卡，进入笔记点击扩展工具无添加闪卡功能」
  //   与「笔记内无思维导图创建入口」。排查确认：`showFlashcard` / `showMindMap` 两个面板
  //   在 WhiteboardPage 里**有完整渲染代码，却从未被任何地方置为 true** —— 入口完全是缺失的。
  //   现补齐这两个入口。
  { key: 'flashcard', label: '闪卡', icon: '', symbol: IconSymbols.DOC_TEXT, category: 'create' },
  { key: 'mindmap', label: '思维导图', icon: '', symbol: IconSymbols.BRUSH, category: 'create' },
  // 管理类（已实现）
  { key: 'recycle_bin', label: '回收站', icon: '', symbol: IconSymbols.DELETE, category: 'manage' },
  { key: 'version_history', label: '版本历史', icon: '', symbol: IconSymbols.REPLAY, category: 'manage' },
  { key: 'brush_box', label: '笔盒', icon: '', symbol: IconSymbols.BRUSH, category: 'manage' },
  // 导出类（已实现）
  { key: 'share', label: '分享', icon: '', symbol: IconSymbols.SHARE, category: 'export' },
  { key: 'fullscreen', label: '全屏阅读', icon: '', symbol: IconSymbols.FOCUS, category: 'export' },
];

@Component
export struct ExtendedToolsPanel {
  @Prop collapsed: boolean = true;

  /** 工具点击回调 */
  onToolSelect?: (key: string) => void;
  /** 关闭面板回调 */
  onClose?: () => void;

  build() {
    // collapsed=true 时不渲染内容，避免遮罩层拦截点击
    if (this.collapsed) {
      Column().width('100%').height(0)
    } else {
      // 标题栏由调用方（如 WhiteboardPage 的抽屉）统一提供，避免重复显示"扩展工具"
      Scroll() {
        Column() {
          // 按分类分组显示（v3.1：仅显示已实现的分类）
          this.toolCategory('创建', EXTENDED_TOOLS.filter(t => t.category === 'create'))
          this.toolCategory('管理', EXTENDED_TOOLS.filter(t => t.category === 'manage'))
          this.toolCategory('导出', EXTENDED_TOOLS.filter(t => t.category === 'export'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 12, right: 12, top: 4, bottom: 12 })
      }
      .height(392)
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(12)
      .width('100%')
      // v2.5.2 审核修复：滑动到边界需有反馈动效
      .edgeEffect(EdgeEffect.Spring)
      // v2.6.0：内容较多时给出滚动条，避免用户误以为"下面没有了"
      .scrollBar(BarState.Auto)
    }
  }

  /**
   * 分组标题 + 条目网格。
   *
   * 🔧 v2.6.0 审核修复（问题①-2 真因）：
   *   审核反馈「扩展工具：文本工具双击无响应，创建、管理、导出等工具点击均无响应」。
   *   实测录屏可见：分组标题「创建 / 管理 / 导出」被 Column 的默认 alignItems=Center
   *   渲染成了**居中的大号文字**，视觉上与可点击按钮无异，但它们是纯 Text、没有任何
   *   onClick —— 审核员自然会点它们并判定"点击无响应"；同时「导出」分组的两个条目
   *   被挤到面板底部、被一体化工具栏挡住不可触达。
   *   修法：①分组标题左对齐 + 前置蓝色竖条，明确是「分组标签」而非按钮；
   *        ②条目改为紧凑定宽网格，压缩垂直留白，保证三个分组全部可见可点。
   */
  @Builder toolCategory(title: string, tools: ToolItem[]) {
    if (tools.length > 0) {
      // 分组标签（明确非交互元素）
      Row() {
        Column()
          .width(3).height(13)
          .borderRadius(2)
          .backgroundColor(HCColor.PRIMARY)
          .margin({ right: 6 })
        Text(`${title} · ${tools.length}`)
          .fontSize(12)
          .fontWeight(FontWeight.Medium)
          .fontColor(HCColor.TEXT_SECONDARY)
      }
      .width('100%')
      .height(26)
      .margin({ top: 4, bottom: 2 })
      .alignItems(VerticalAlign.Center)
      .hitTestBehavior(HitTestMode.None)   // 分组标题不参与点击，避免误判为按钮

      // 🔧 修复：Row→Flex+wrap 避免工具项水平溢出导致无法点击
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(tools, (item: ToolItem) => {
          Column() {
            if (item.symbol) {
              SymbolGlyph($r('sys.symbol.' + item.symbol))
                .fontSize(20).fontColor([HCColor.TEXT_PRIMARY])
            } else {
              Text(item.icon).fontSize(20).lineHeight(26)
            }
            Text(item.label).fontSize(10).margin({ top: 2 })
              .fontColor(HCColor.TEXT_SECONDARY).maxLines(1)
          }
          .width(72).height(60)
          .backgroundColor(HCColor.SURFACE_ELEVATED)
          .borderRadius(10)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .margin({ right: 8, bottom: 6 })
          .shadow({ radius: 2, color: 'rgba(0,0,0,0.06)', offsetX: 0, offsetY: 1 })
          .onClick(() => { this.onToolSelect?.(item.key); })
        })
      }
      .width('100%')
      .padding({ bottom: 2 })
    }
  }
}
