/**
 * MindMapPage.ets — 思维导图编辑页（v2.5 UI 重做）
 *
 * 显示导图（Canvas 绘制节点 + 连线），支持：
 *  - 大纲导入：文本区编辑大纲 → buildFromOutline 生成导图；
 *  - 节点编辑：选中节点可改名 / 添加子节点 / 删除子树；
 *  - 手绘导入：接收 WhiteboardPage 选中的手绘笔迹 → MindMapBuilder.buildFromStrokes。
 *
 * UI 特征：
 *  - 现代化导航栏 + 工具条
 *  - 选中节点高亮动画
 *  - 大纲导入面板带动效
 */
import { router } from '@kit.ArkUI';
import { HCMindMap, HCMindNode } from '../engine/types/NoteModel';
import { MindMapModel } from '../engine/types/MindMapModel';
import { buildFromOutline, buildFromStrokes } from '../engine/MindMapBuilder';
import { StrokePoints } from '../engine/MindMapBuilder';
import { HCColor, HCPrimary, HCGray, HCOverlay } from '../common/theme/DesignTokens';
import { IconSymbols } from '../common/IconConstants';

const TAG_MODULE = 'MindMapPage';

/** v2.6.0：@Builder 按引用传参类型（ArkTS 禁止匿名对象字面量作类型） */
interface ToolChipParam {
  label: string;
  color: ResourceColor;
  enabled: boolean;
  action: () => void;
}

@Component
export struct MindMapPage {
  @State map: HCMindMap = MindMapModel.createEmpty('思维导图', '中心主题');
  @State selectedNodeId: string = '';
  @State showOutline: boolean = false;
  @State outlineText: string = '';
  @State editLabel: string = '';

  onChanged: (map: HCMindMap) => void = (map: HCMindMap) => {};
  onClose: () => void = () => { router.back(); };

  aboutToAppear(): void {
    this.selectedNodeId = '';
  }

  private notifyChanged(): void {
    this.onChanged(this.map);
  }

  private selectNode(nodeId: string): void {
    this.selectedNodeId = this.selectedNodeId === nodeId ? '' : nodeId;
    const node: HCMindNode | null = MindMapModel.findNode(this.map, nodeId);
    this.editLabel = node !== null ? node.label : '';
  }

  private addChild(): void {
    if (this.selectedNodeId.length === 0) { return; }
    const label: string = this.editLabel.trim().length > 0 ? this.editLabel.trim() : '分支';
    MindMapModel.addNode(this.map, this.selectedNodeId, label);
    this.editLabel = '';
    this.notifyChanged();
    this.drawMap();
  }

  private renameSelected(): void {
    if (this.selectedNodeId.length === 0) { return; }
    MindMapModel.updateLabel(this.map, this.selectedNodeId, this.editLabel);
    this.notifyChanged();
    this.drawMap();
  }

  private deleteSelected(): void {
    if (this.selectedNodeId.length === 0) { return; }
    MindMapModel.removeSubtree(this.map, this.selectedNodeId);
    this.selectedNodeId = '';
    this.notifyChanged();
    this.drawMap();
  }

  private applyOutline(): void {
    const title: string = this.map.title;
    this.map = buildFromOutline(title, this.outlineText);
    this.selectedNodeId = '';
    this.showOutline = false;
    this.notifyChanged();
    this.drawMap();
  }

  importStrokes(strokes: StrokePoints[]): void {
    if (strokes === undefined || strokes === null || strokes.length === 0) { return; }
    this.map = buildFromStrokes(this.map.title, this.map.rootLabel, strokes);
    this.selectedNodeId = '';
    this.notifyChanged();
    this.drawMap();
  }

  build() {
    Column() {
      // ── 导航栏 ──
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.BACK))
            .fontSize(18).fontColor([HCColor.TEXT_PRIMARY])
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(HCColor.PAGE_BG)
        .onClick(() => this.onClose())

        Blank()

        Column() {
          Text('思维导图').fontSize(18).fontWeight(FontWeight.Bold).fontColor(HCColor.TEXT_PRIMARY)
          Text(`${this.map.nodes.length} 个节点`).fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Center)

        Blank()

        // v2.7.6：平移过画布时提供"重置视图"，避免用户把导图拖到看不见的位置
        if (this.panX !== 0 || this.panY !== 0) {
          Button('重置视图')
            .fontSize(12).fontColor(HCColor.TEXT_SECONDARY)
            .height(30).padding({ left: 10, right: 10 }).borderRadius(15)
            .backgroundColor(HCColor.PAGE_BG)
            .margin({ right: 8 })
            .onClick(() => {
              this.panX = 0;
              this.panY = 0;
              this.drawMap();
            })
        }

        Button('大纲')
          .fontSize(12).fontColor(HCColor.PRIMARY)
          .height(30).padding({ left: 10, right: 10 }).borderRadius(15)
          .backgroundColor(HCColor.PRIMARY_BG)
          .onClick(() => { this.showOutline = !this.showOutline; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 48, bottom: 8 })

      // ── 大纲导入区 ──
      if (this.showOutline) {
        Column() {
          Text('从大纲生成导图').fontSize(15).fontWeight(FontWeight.Medium).margin({ bottom: 10 })
          TextArea({
            placeholder: '每行一个节点，行首2空格表示1级缩进',
            text: this.outlineText
          })
            .width('100%').height(110).fontSize(13).borderRadius(12)
            .backgroundColor(HCColor.PAGE_BG).padding(10)
            .onChange((v: string) => { this.outlineText = v; })
          Row() {
            Button('取消')
              .height(34).fontSize(13).borderRadius(17)
              .backgroundColor(HCColor.PAGE_BG).fontColor(HCColor.TEXT_SECONDARY)
              .onClick(() => { this.showOutline = false; })
            Blank().width(12)
            Button('生成导图')
              .height(34).fontSize(13).borderRadius(17)
              .backgroundColor(HCColor.PRIMARY).fontColor(Color.White)
              .onClick(() => this.applyOutline())
          }
          .width('100%').margin({ top: 10 })
        }
        .width('88%').padding(16)
        .backgroundColor(HCColor.SURFACE).borderRadius(16)
        .margin({ bottom: 10 })
        .shadow({ radius: 8, color: HCOverlay.SHADE_08 })
        .transition(TransitionEffect.opacity(0).animation({ duration: 200 }))
      }

      // ── 编辑工具条 ──
      Row() {
        if (this.selectedNodeId.length > 0) {
          Text('已选中').fontSize(12).fontColor(HCColor.PRIMARY).margin({ right: 8 })
        } else {
          Text('点击节点选中').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ right: 8 })
        }

        TextInput({ placeholder: '节点文本', text: this.editLabel })
          .layoutWeight(1).height(32).fontSize(13)
          .borderRadius(16).backgroundColor(HCColor.PAGE_BG).padding({ left: 12 })
          .onChange((v: string) => { this.editLabel = v; })

        Blank().width(6)

        this.toolChip({ label: '改名', color: HCColor.PRIMARY, enabled: this.selectedNodeId.length > 0, action: () => this.renameSelected() })
        this.toolChip({ label: '+子', color: HCColor.PRIMARY, enabled: this.selectedNodeId.length > 0, action: () => this.addChild() })
        this.toolChip({ label: '删除', color: HCColor.DANGER, enabled: this.selectedNodeId.length > 0, action: () => this.deleteSelected() })
      }
      .width('100%').height(44)
      .padding({ left: 16, right: 16 })
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(12).margin({ left: 12, right: 12, bottom: 8 })
      .shadow({ radius: 4, color: HCOverlay.SHADE_04 })

      // ── 导图画布 ──
      Stack() {
        Canvas(this.mapCanvas)
          .width('100%').height('100%')
          .backgroundColor(HCColor.PAGE_BG)
          .onReady(() => { this.drawMap(); })
          .onTouch((e: TouchEvent) => {
            // v2.7.6：拖动过画布就不再把抬手当作"点选节点"
            if (e.type === TouchType.Up && !this.panMoved) {
              const touch = e.touches[0];
              this.hitTest(touch.x, touch.y);
            }
          })
          // 🔴 v2.7.6：单指拖动平移画布 —— 解决"节点超出屏幕后无法查看"
          .gesture(
            PanGesture({ fingers: 1 })
              .onActionStart(() => {
                this.panStartX = this.panX;
                this.panStartY = this.panY;
                this.panMoved = false;
              })
              .onActionUpdate((e: GestureEvent) => {
                const dx: number = e.offsetX;
                const dy: number = e.offsetY;
                // 超过阈值才算拖动，避免轻微抖动导致误判
                if (Math.abs(dx) > 4 || Math.abs(dy) > 4) {
                  this.panMoved = true;
                }
                this.panX = this.panStartX + dx;
                this.panY = this.panStartY + dy;
                this.drawMap();
              })
              .onActionEnd(() => {
                // 松手后恢复标记，交给 onTouch 的 Up 分支处理点选
              })
          )

        // 空态引导
        if (this.map.nodes.length === 1 && this.map.nodes[0].label === '中心主题') {
          Column() {
            Text('🧠').fontSize(40).margin({ bottom: 8 })
            Text('导入大纲或点击画布添加节点').fontSize(14).fontColor(HCColor.TEXT_TERTIARY)
            Text('点击右上角「大纲」从文本生成').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 4 })
          }
          .width('100%').height('100%')
          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%').height('100%')
    .backgroundColor(HCColor.PAGE_BG)
  }

  /** v2.6.0：对象字面量传参（按引用）→ 可用态随 selectedNodeId 实时刷新 */
  @Builder toolChip($$: ToolChipParam) {
    Text($$.label)
      .fontSize(12).fontColor($$.color)
      .opacity($$.enabled ? 1 : 0.4)
      .padding({ left: 10, right: 10, top: 6, bottom: 6 })
      .borderRadius(14)
      .backgroundColor($$.enabled ? HCColor.PAGE_BG : HCColor.DIVIDER)
      .onClick(() => {
        if ($$.enabled) { $$.action(); }
      })
  }

  private mapCanvas: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));

  // 🔧 v3.1 修复：画布中心偏移。MindMapModel 中根节点坐标固定为 (0,0)，
  //   子节点按 LEVEL_GAP/SIBLING_GAP 相对排布；此前直接以节点坐标绘制，
  //   导致"中心主题"画在画布左上角 (0,0)、被导航/工具条遮住（审核截图：
  //   我的-思维导图中心区域被截断）。现在统一以画布中心为原点绘制。
  private originX: number = 0;
  private originY: number = 0;
  // 🔴 v2.7.6 审核修复（问题②「插入节点超出屏幕后无法拖动查看」）
  //   原实现**没有任何平移/滚动能力**，节点一旦画到可视区外就再也看不到。
  //   现引入画布平移：所有绘制与命中测试统一叠加 (panX, panY)。
  @State private panX: number = 0;
  @State private panY: number = 0;
  private panStartX: number = 0;
  private panStartY: number = 0;
  /** 本次触摸是否发生了拖动（用于区分"拖动平移"与"点击选择节点"） */
  private panMoved: boolean = false;

  private hitTest(x: number, y: number): void {
    for (let i = 0; i < this.map.nodes.length; i++) {
      const n: HCMindNode = this.map.nodes[i];
      const nx: number = n.x + this.originX + this.panX;
      const ny: number = n.y + this.originY + this.panY;
      if (Math.abs(nx - x) < 30 && Math.abs(ny - y) < 20) {
        this.selectNode(n.id);
        this.drawMap();
        return;
      }
    }
  }

  private drawMap(): void {
    const ctx = this.mapCanvas;
    const w: number = this.mapCanvas.width;
    const h: number = this.mapCanvas.height;
    // 🔧 v3.1 修复：以画布中心为原点（首次绘制时计算一次；Canvas 尺寸单位为 px）
    if (w > 0 && this.originX === 0 && this.originY === 0) {
      this.originX = Math.round(w / 2);
      this.originY = Math.round(h / 3); // 偏上 1/3，视觉重心更稳
    }
    // v2.7.6：ctx.width 是 vp，单位阵下按 vp 清只清左上局部 → 改用物理缓冲区尺寸
    ctx.clearRect(0, 0, vp2px(w > 0 ? w : 400), vp2px(h > 0 ? h : 600));

    // 连线
    for (let i = 0; i < this.map.edges.length; i++) {
      const e = this.map.edges[i];
      const from: HCMindNode | null = MindMapModel.findNode(this.map, e.from);
      const to: HCMindNode | null = MindMapModel.findNode(this.map, e.to);
      if (from === null || to === null) { continue; }
      ctx.beginPath();
      ctx.strokeStyle = HCGray.GRAY_5;
      ctx.lineWidth = 1.5;
      ctx.moveTo(from.x + this.originX + this.panX + 40, from.y + this.originY + this.panY);
      ctx.lineTo(to.x + this.originX + this.panX, to.y + this.originY + this.panY);
      ctx.stroke();
    }

    // 节点
    for (let i = 0; i < this.map.nodes.length; i++) {
      const n: HCMindNode = this.map.nodes[i];
      const isRoot: boolean = n.parentId.length === 0;
      const isSel: boolean = n.id === this.selectedNodeId;
      ctx.beginPath();
      ctx.fillStyle = isSel ? HCPrimary.BG : (isRoot ? HCPrimary.BG : HCGray.GRAY_2);
      ctx.strokeStyle = isSel ? HCPrimary.BLUE : (isRoot ? HCPrimary.BLUE : HCGray.GRAY_4);
      ctx.lineWidth = isSel ? 2.5 : 1;
      const w2: number = Math.max(56, n.label.length * 14 + 20);
      ctx.roundRect(n.x + this.originX + this.panX, n.y + this.originY + this.panY - 16, w2, 32, 8);
      ctx.fill();
      ctx.stroke();
      ctx.fillStyle = HCGray.GRAY_9;
      ctx.font = '13px sans-serif';
      ctx.textBaseline = 'middle';
      ctx.textAlign = 'left';
      ctx.fillText(n.label, n.x + this.originX + this.panX + 8, n.y + this.originY + this.panY + 1);
    }
  }
}
