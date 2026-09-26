/**
 * TextEditPanel.ets — 文本编辑面板（P0 缺失功能 UI 组件）
 *
 * 提供：字体/字号/颜色/对齐/粗斜体/下划线 的完整编辑控件
 */
import { TextToolService, TextStyleConfig } from '../engine/TextToolService';
import { TextAlign as ToolTextAlign } from '../engine/TextBlockTool';
import { HCColor } from '../common/theme/DesignTokens';

const TAG = 'TextEditPanel';

/** v2.6.0：@Builder 按引用传参类型（ArkTS 禁止匿名对象字面量作类型） */
interface StyleToggleParam {
  label: string;
  active: boolean;
  onTap: () => void;
}

@Component
export struct TextEditPanel {
  private textToolService: TextToolService = TextToolService.getInstance();
  @State currentStyle: TextStyleConfig = this.textToolService.getDefaultStyle();
  @State content: string = '';

  /** v2.7.0：由父页传入的待编辑文本（双击文本框时预填） */
  @Prop initialContent: string = '';
  /** v2.7.0：面板标题（编辑既有文本框 / 新建文本） */
  @Prop panelTitle: string = '编辑文本';

  /** 样式变更回调 */
  onStyleChange?: (style: TextStyleConfig) => void;
  /** 内容变更回调 */
  onContentChange?: (content: string) => void;
  /** 确认编辑 */
  onConfirm?: (content: string, style: TextStyleConfig) => void;
  /** 取消编辑 */
  onCancel?: () => void;

  aboutToAppear(): void {
    // v2.7.0：进入面板时预填内容，避免双击编辑框后是空白
    this.content = this.initialContent;
  }

  build() {
    Column() {
      // 标题栏
      Row() {
        Button('取消').onClick(() => { this.onCancel?.(); })
          .fontColor(HCColor.TEXT_SECONDARY).backgroundColor(Color.Transparent)
        Text(this.panelTitle).fontSize(16).fontWeight(FontWeight.Medium).layoutWeight(1).textAlign(TextAlign.Center)
        Button('确定').onClick(() => { this.onConfirm?.(this.content, this.currentStyle); })
          .fontColor(HCColor.PRIMARY).backgroundColor(Color.Transparent)
      }
      .width('100%').padding({ top: 12, bottom: 8, left: 16, right: 16 })

      // 文本内容输入
      TextArea({ placeholder: '输入文本内容...', text: this.content })
        .height(120)
        .fontSize(16)
        .onChange((v: string) => {
          this.content = v;
          this.onContentChange?.(v);
        })
        .padding(12)
        .backgroundColor('#F5F5F5')
        .borderRadius(8)
        .margin({ bottom: 12 })

      // 字号滑块 (8-120)
      Row() {
        Text('字号').fontSize(14).fontColor(HCColor.TEXT_SECONDARY).width(50)
        Slider({
          value: this.currentStyle.fontSize,
          min: 8, max: 120, step: 2
        })
          .width(150)
          .onChange((v: number) => {
            this.currentStyle.fontSize = v;
            this.onStyleChange?.(this.currentStyle);
          })
        Text(`${this.currentStyle.fontSize}px`).fontSize(12).width(50).textAlign(TextAlign.Center)
      }
      .padding({ bottom: 8 })

      // 字体选择
      Row() {
        Text('字体').fontSize(14).fontColor(HCColor.TEXT_SECONDARY).width(50)
        Row() {
          this.fontOption('sans-serif')
          this.fontOption('serif')
          this.fontOption('monospace')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.SpaceEvenly)
      }
      .padding({ bottom: 8 })

      // 颜色选择行
      Row() {
        Text('颜色').fontSize(14).fontColor(HCColor.TEXT_SECONDARY).width(50)
        Row() {
          this.colorSwatch('#000000')
          this.colorSwatch('#FF0000')
          this.colorSwatch('#0000FF')
          this.colorSwatch('#008000')
          this.colorSwatch('#FFA500')
          this.colorSwatch('#800080')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.SpaceEvenly)
      }
      .padding({ bottom: 8 })

      // 对齐方式
      Row() {
        Text('对齐').fontSize(14).fontColor(HCColor.TEXT_SECONDARY).width(50)
        this.alignButton('左', ToolTextAlign.LEFT)
        this.alignButton('中', ToolTextAlign.CENTER)
        this.alignButton('右', ToolTextAlign.RIGHT)
      }
      .padding({ bottom: 8 })

      // 粗斜体下划线
      Row() {
        this.styleToggleButton({ label: 'B', active: this.currentStyle.bold,
          onTap: () => { this.toggleStyleFlag('bold'); } })
        this.styleToggleButton({ label: 'I', active: this.currentStyle.italic,
          onTap: () => { this.toggleStyleFlag('italic'); } })
        this.styleToggleButton({ label: 'U', active: this.currentStyle.underline,
          onTap: () => { this.toggleStyleFlag('underline'); } })
      }
      .padding({ left: 50, bottom: 8 })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(12)
  }

  @Builder fontOption(name: string) {
    Button(name)
      .fontSize(12)
      .fontColor(this.currentStyle.fontFamily === name ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY)
      .backgroundColor(this.currentStyle.fontFamily === name ? '#E8E8FF' : '#F5F5F5')
      .borderRadius(6)
      .height(32)
      .onClick(() => {
        this.currentStyle.fontFamily = name;
        this.onStyleChange?.(this.currentStyle);
      })
  }

  @Builder colorSwatch(color: string) {
    Circle()
      .width(28).height(28)
      .fill(color)
      .stroke(this.currentStyle.color === color ? HCColor.PRIMARY : Color.Transparent)
      .strokeWidth(3)
      .onClick(() => {
        this.currentStyle.color = color;
        this.onStyleChange?.(this.currentStyle);
      })
  }

  @Builder alignButton(label: string, align: ToolTextAlign) {
    Button(label)
      .fontSize(13)
      .fontColor(this.currentStyle.align === align ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY)
      .backgroundColor(this.currentStyle.align === align ? '#E8E8FF' : '#F5F5F5')
      .borderRadius(6)
      .height(32)
      .width(48)
      .onClick(() => {
        this.currentStyle.align = align;
        this.onStyleChange?.(this.currentStyle);
      })
  }

  /**
   * v2.6.0：切换粗/斜/下划线。
   *   原实现直接改 `this.currentStyle.bold` —— @State 持有的是对象引用，
   *   **原地改嵌套字段不会触发 ArkUI 重渲染**，按钮高亮因此永远不变。
   *   现构造**新对象**整体赋值，@State 感知为变化 → 高亮即时刷新。
   */
  private toggleStyleFlag(field: string): void {
    const cur: TextStyleConfig = this.currentStyle;
    const next: TextStyleConfig = {
      fontSize: cur.fontSize,
      fontFamily: cur.fontFamily,
      align: cur.align,
      color: cur.color,
      bold: field === 'bold' ? !cur.bold : cur.bold,
      italic: field === 'italic' ? !cur.italic : cur.italic,
      underline: field === 'underline' ? !cur.underline : cur.underline,
    };
    this.currentStyle = next;
    this.onStyleChange?.(next);
  }

  /** v2.6.0：对象字面量传参（按引用）→ B/I/U 开关高亮随样式状态实时刷新 */
  @Builder styleToggleButton($$: StyleToggleParam) {
    Button($$.label)
      .fontSize(14)
      .fontWeight($$.active ? FontWeight.Bold : FontWeight.Normal)
      .fontColor($$.active ? HCColor.PRIMARY : HCColor.TEXT_PRIMARY)
      .backgroundColor($$.active ? '#E8E8FF' : '#F5F5F5')
      .borderRadius(6)
      .height(32)
      .width(40)
      .onClick($$.onTap)
  }
}
