/**
 * LayerPanel.ets - 图层管理面板组件
 *
 * 功能：新建图层、锁定、隐藏、上下层级、重命名、**透明度调节**。
 *
 * v2.4 阶段一（T1-5）改造：
 *  1. 数据源改为快照 @State layers，任何变更后 syncLayers() 刷新 —— 原实现直接在 ForEach 里
 *     调 layerManager.getLayers()，LayerManager 不是 @Observed，改完不重绘（"点了没反应"）；
 *  2. layerManager 由 @Prop 改为经 NoteEngine 门面取单例 —— @Prop 会深拷贝对象，
 *     拷贝后的 LayerManager 内部 Map 失效，是「图层功能全废」的根因之一；
 *  3. 新增**纸图层保护**：type==='paper' 的底纸层不可删除、不可上移越过绘制层；
 *  4. 新增**透明度滑块**，并在任何变更后回调 onChanged()，由白板页重绘历史层。
 */

import { NoteEngine } from '../engine/NoteEngine';
import { Layer, LayerManager } from '../engine/LayerManager';
import { HCColor, HCBrand, HCOverlay } from '../common/theme/DesignTokens';

/** 纸图层类型标识（与 LayerManager.createPaperLayer 一致） */
const LAYER_TYPE_PAPER: string = 'paper';

@Component
export struct LayerPanel {
  /** 图层快照：唯一渲染数据源，变更后由 syncLayers() 整体替换触发重绘 */
  @State layers: Layer[] = [];
  @State activeLayerId: string = '';
  @State showLayerDialog: boolean = false;
  @State newLayerName: string = '';

  /** 任意图层属性变化后回调（白板页据此重绘历史层） */
  onChanged: () => void = () => {};
  /** 关闭面板 */
  onClose: () => void = () => {};
  // ── S2-B / T2-3：图层高级操作（操作逻辑由白板页全权处理，含撤销快照与 strokes 归属）──
  /** 合并请求：返回新图层 id（null=失败） */
  onMergeRequest: (srcIds: string[]) => string | null = (srcIds: string[]) => null;
  /** 复制请求：返回新图层 id（null=失败） */
  onDuplicateRequest: (srcId: string) => string | null = (srcId: string) => null;
  /** 分组请求：返回分组图层 id（null=失败） */
  onGroupRequest: (ids: string[]) => string | null = (ids: string[]) => null;
  /** 单层导出请求 */
  onExportRequest: (layerId: string) => void = (layerId: string) => {};
  /** 撤销图层操作 */
  onLayerUndo: () => void = () => {};
  /** 是否存在可撤销的图层操作（父页 layerUndoStack 非空） */
  undoable: boolean = false;

  /** 引擎图层管理器（经门面获取，页面/组件不各自 new，铁律 2） */
  private layerManager: LayerManager = NoteEngine.getInstance().getLayerManager();

  aboutToAppear(): void {
    this.syncLayers();
    const active: Layer | undefined = this.layerManager.getActiveLayer();
    if (active !== undefined) {
      this.activeLayerId = active.id;
    } else if (this.layers.length > 0) {
      this.activeLayerId = this.layers[0].id;
    }
  }

  /** 从引擎拉取最新图层列表（整体替换引用，确保 ArkUI 侦测到变化） */
  private syncLayers(): void {
    this.layers = this.layerManager.getLayers().slice();
  }

  /** 变更后统一收口：刷新快照 + 通知父页重绘 */
  private commit(): void {
    this.syncLayers();
    this.onChanged();
  }

  /** 选中图层（纸图层不能作为绘制目标） */
  private selectLayer(layer: Layer): void {
    if (layer.type === LAYER_TYPE_PAPER) {
      return;
    }
    this.activeLayerId = layer.id;
    this.layerManager.setActiveLayer(layer.id);
  }

  /** 创建新图层 */
  private createNewLayer(): void {
    const trimmed: string = this.newLayerName.trim();
    const name: string = trimmed.length > 0 ? trimmed : `图层 ${this.layerManager.getLayerCount() + 1}`;
    const newLayer: Layer = this.layerManager.createLayer(name, 'draw');
    this.activeLayerId = newLayer.id;
    this.layerManager.setActiveLayer(newLayer.id);
    this.newLayerName = '';
    this.showLayerDialog = false;
    this.commit();
  }

  /** 删除图层（底纸层受保护；至少保留一个绘制层） */
  private deleteLayer(layer: Layer): void {
    if (layer.type === LAYER_TYPE_PAPER) {
      return;
    }
    if (this.drawLayerCount() <= 1) {
      return;
    }
    this.layerManager.deleteLayer(layer.id);
    if (this.activeLayerId === layer.id) {
      const remaining: Layer[] = this.layerManager.getLayers();
      for (let i = 0; i < remaining.length; i++) {
        if (remaining[i].type !== LAYER_TYPE_PAPER) {
          this.activeLayerId = remaining[i].id;
          this.layerManager.setActiveLayer(remaining[i].id);
          break;
        }
      }
    }
    this.commit();
  }

  /** 当前绘制层数量（用于「至少保留一个」判断，底纸层不计入） */
  private drawLayerCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].type !== LAYER_TYPE_PAPER) {
        count++;
      }
    }
    return count;
  }

  /** 全部非底纸绘制层 id（合并/分组候选，按层序） */
  private drawLayerIds(): string[] {
    const result: string[] = [];
    for (let i = 0; i < this.layers.length; i++) {
      if (this.layers[i].type !== LAYER_TYPE_PAPER && this.layers[i].type !== 'group') {
        result.push(this.layers[i].id);
      }
    }
    return result;
  }

  private toggleVisibility(layer: Layer): void {
    this.layerManager.toggleVisibility(layer.id);
    this.commit();
  }

  private toggleLock(layer: Layer): void {
    this.layerManager.toggleLock(layer.id);
    this.commit();
  }

  private changeOpacity(layer: Layer, percent: number): void {
    const opacity: number = Math.round(percent) / 100;
    this.layerManager.setOpacity(layer.id, opacity < 0 ? 0 : (opacity > 1 ? 1 : opacity));
    this.commit();
  }

  /** 上移（底纸层不得越过绘制层，恒定沉底） */
  private moveUp(layer: Layer): void {
    if (layer.type === LAYER_TYPE_PAPER) {
      return;
    }
    this.layerManager.moveUp(layer.id);
    this.commit();
  }

  /** 下移（不得沉到底纸层之下） */
  private moveDown(layer: Layer, index: number): void {
    if (layer.type === LAYER_TYPE_PAPER) {
      return;
    }
    if (index > 0 && this.layers[index - 1].type === LAYER_TYPE_PAPER) {
      return;
    }
    this.layerManager.moveDown(layer.id);
    this.commit();
  }

  build() {
    Column() {
      // ── 标题栏 ──
      Row() {
        Text('图层')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 12 })

        Text(`${this.layers.length}`)
          .fontSize(11)
          .fontColor(HCColor.ICON_SECONDARY)
          .margin({ left: 6 })

        Blank()

        Text('+')
          .fontSize(18)
          .fontColor(HCColor.SURFACE)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .backgroundColor(HCBrand.GREEN)
          .borderRadius(14)
          .onClick(() => {
            this.showLayerDialog = true;
          })

        Text('×')
          .fontSize(14)
          .fontColor(HCColor.ICON_SECONDARY)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .margin({ left: 4, right: 8 })
          .onClick(() => this.onClose())
      }
      .width('100%')
      .height(40)
      .backgroundColor(HCColor.PAGE_BG)
      .borderRadius({ topLeft: 8, topRight: 8 })

      // ── 图层列表 ──
      Scroll() {
        Column() {
          ForEach(this.layers, (layer: Layer, index: number) => {
            this.LayerItemBuilder(layer, index, this.layers.length);
          }, (layer: Layer) => layer.id)
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      // v2.5.2 审核修复：滑动到边界需有反馈动效
      .edgeEffect(EdgeEffect.Spring)

      // ── 图层高级操作（S2-B / T2-3：合并/复制/分组/单层导出/撤销）──
      Row() {
        Text('复制')
          .fontSize(11)
          .height(26)
          .padding({ left: 8, right: 8 })
          .backgroundColor(HCColor.PRIMARY_BG)
          .fontColor(HCColor.PRIMARY)
          .borderRadius(6)
          .margin({ left: 8 })
          .onClick(() => {
            if (this.activeLayerId.length === 0) {
              return;
            }
            const newId: string | null = this.onDuplicateRequest(this.activeLayerId);
            if (newId !== null) {
              this.activeLayerId = newId;
              this.layerManager.setActiveLayer(newId);
              this.commit();
            }
          })

        Text('合并')
          .fontSize(11)
          .height(26)
          .padding({ left: 8, right: 8 })
          .backgroundColor(HCColor.WARNING_BG)
          .fontColor(HCBrand.ORANGE)
          .borderRadius(6)
          .margin({ left: 6 })
          .onClick(() => {
            const srcIds: string[] = this.drawLayerIds();
            if (srcIds.length < 2) {
              return;
            }
            const newId: string | null = this.onMergeRequest(srcIds);
            if (newId !== null) {
              this.activeLayerId = newId;
              this.layerManager.setActiveLayer(newId);
              this.commit();
            }
          })

        Text('分组')
          .fontSize(11)
          .height(26)
          .padding({ left: 8, right: 8 })
          .backgroundColor(HCBrand.PURPLE_TINT)
          .fontColor(HCBrand.PURPLE_SOFT)
          .borderRadius(6)
          .margin({ left: 6 })
          .onClick(() => {
            const ids: string[] = this.drawLayerIds();
            if (ids.length < 2) {
              return;
            }
            const groupId: string | null = this.onGroupRequest(ids.slice(0, 2));
            if (groupId !== null) {
              this.activeLayerId = groupId;
              this.layerManager.setActiveLayer(groupId);
              this.commit();
            }
          })

        Text('单层导出')
          .fontSize(11)
          .height(26)
          .padding({ left: 8, right: 8 })
          .backgroundColor(HCBrand.BLUE_TINT)
          .fontColor(HCBrand.BLUE_DEEP)
          .borderRadius(6)
          .margin({ left: 6 })
          .onClick(() => {
            if (this.activeLayerId.length === 0) {
              return;
            }
            this.onExportRequest(this.activeLayerId);
          })

        Blank()

        Text(this.undoable ? '回 撤销图层' : '回')
          .fontSize(11)
          .height(26)
          .padding({ left: 8, right: 8 })
          .backgroundColor(this.undoable ? HCColor.DANGER_BG : HCColor.DIVIDER)
          .fontColor(this.undoable ? HCColor.DANGER : HCColor.TEXT_DISABLED)
          .borderRadius(6)
          .margin({ right: 8 })
          .onClick(() => {
            if (this.undoable) {
              this.onLayerUndo();
              this.commit();
            }
          })
      }
      .width('100%')
      .height(36)
      .backgroundColor(HCColor.PAGE_BG)

      // ── 新建图层对话框 ──
      if (this.showLayerDialog) {
        Column() {
          Text('新建图层')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .margin({ top: 12, bottom: 10 })

          TextInput({ placeholder: '图层名称', text: this.newLayerName })
            .width('84%')
            .height(38)
            .fontSize(13)
            .border({ width: 1, color: HCColor.BORDER })
            .borderRadius(4)
            .margin({ bottom: 12 })
            .onChange((value: string) => {
              this.newLayerName = value;
            })

          Row() {
            Button('取消')
              .fontSize(13)
              .width(80)
              .height(34)
              .backgroundColor(HCColor.PAGE_BG)
              .fontColor(HCColor.TEXT_TERTIARY)
              .borderRadius(4)
              .onClick(() => {
                this.showLayerDialog = false;
                this.newLayerName = '';
              })

            Blank()

            Button('确定')
              .fontSize(13)
              .width(80)
              .height(34)
              .backgroundColor(HCBrand.GREEN)
              .fontColor(HCColor.SURFACE)
              .borderRadius(4)
              .onClick(() => {
                this.createNewLayer();
              })
          }
          .width('84%')
          .margin({ bottom: 12 })
        }
        .width('100%')
        .backgroundColor(HCColor.SURFACE)
        .borderRadius({ bottomLeft: 8, bottomRight: 8 })
        .border({ width: { top: 1 }, color: HCColor.DIVIDER })
      }
    }
    .width(300)
    .height(340)
    .backgroundColor(HCColor.SURFACE)
    .border({ width: 1, color: HCColor.BORDER })
    .borderRadius(8)
    .shadow({ radius: 12, color: HCOverlay.SHADE_20, offsetX: 0, offsetY: 4 })
  }

  @Builder
  LayerItemBuilder(layer: Layer, index: number, total: number) {
    Column() {
      Row() {
        // 可见性
        Text(layer.visible ? '示' : '隐')
          .fontSize(13)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .onClick(() => this.toggleVisibility(layer))

        // 锁定
        Text(layer.locked ? '锁' : '开')
          .fontSize(13)
          .width(26)
          .height(26)
          .textAlign(TextAlign.Center)
          .onClick(() => this.toggleLock(layer))

        // 名称（底纸层带标签）
        Text(layer.name)
          .fontSize(13)
          .fontColor(this.activeLayerId === layer.id ? HCBrand.GREEN : HCColor.TEXT_PRIMARY)
          .fontWeight(this.activeLayerId === layer.id ? FontWeight.Bold : FontWeight.Normal)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: 4 })

        if (layer.type === LAYER_TYPE_PAPER) {
          Text('底纸')
            .fontSize(9)
            .fontColor(HCBrand.ORANGE)
            .backgroundColor(HCColor.WARNING_BG)
            .borderRadius(3)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ right: 4 })
        } else {
          // 上移
          if (index < total - 1) {
            Text('↑')
              .fontSize(12)
              .width(22)
              .height(22)
              .textAlign(TextAlign.Center)
              .backgroundColor(HCColor.PAGE_BG)
              .borderRadius(4)
              .margin({ left: 2 })
              .onClick(() => this.moveUp(layer))
          }
          // 下移
          if (index > 0 && this.layers[index - 1].type !== LAYER_TYPE_PAPER) {
            Text('↓')
              .fontSize(12)
              .width(22)
              .height(22)
              .textAlign(TextAlign.Center)
              .backgroundColor(HCColor.PAGE_BG)
              .borderRadius(4)
              .margin({ left: 2 })
              .onClick(() => this.moveDown(layer, index))
          }
          // 删除（至少保留一个绘制层）
          if (this.drawLayerCount() > 1) {
            Text('删')
              .fontSize(11)
              .width(22)
              .height(22)
              .textAlign(TextAlign.Center)
              .backgroundColor(HCColor.DANGER_BG)
              .borderRadius(4)
              .margin({ left: 2 })
              .onClick(() => this.deleteLayer(layer))
          }
        }
      }
      .width('100%')
      .height(34)

      // 透明度滑块
      Row() {
        Text('透明度')
          .fontSize(10)
          .fontColor(HCColor.ICON_SECONDARY)
          .width(40)

        Slider({
          value: Math.round(layer.opacity * 100),
          min: 0,
          max: 100,
          step: 5,
          style: SliderStyle.OutSet,
        })
          .layoutWeight(1)
          .trackColor(HCColor.DIVIDER)
          .selectedColor(HCBrand.GREEN)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.changeOpacity(layer, value);
            }
          })

        Text(`${Math.round(layer.opacity * 100)}%`)
          .fontSize(10)
          .fontColor(HCColor.ICON_SECONDARY)
          .width(34)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .height(24)
    }
    .width('100%')
    .padding({ left: 6, right: 6, top: 2, bottom: 4 })
    .backgroundColor(this.activeLayerId === layer.id ? HCBrand.GREEN_TINT : HCColor.SURFACE)
    .borderRadius(4)
    .margin({ bottom: 4 })
    .onClick(() => this.selectLayer(layer))
  }
}
