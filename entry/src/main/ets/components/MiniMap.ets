/**
 * MiniMap.ets — 缩略图导航浮层（NOTE-03，阶段2）
 *
 * 右下角浮层：点阵表示节点分布 + 书签锚点（三类色）+ 当前视口框。
 * 点击 minimap 任意位置 → 跳转该世界坐标到屏幕中心。
 */

import { CanvasNode, BookmarkData, BookmarkType, Rect } from '../engine/types/BoardModel';
import { MinimapProvider, MinimapPoint } from '../engine/MinimapProvider';
import { HCColor } from '../common/theme/DesignTokens';

@Component
export struct MiniMap {
  @Prop @Watch('requestRedraw') nodes: CanvasNode[] = [];
  @Prop @Watch('requestRedraw') bookmarks: BookmarkData[] = [];
  /** 视口信息 */
  @Prop @Watch('requestRedraw') viewportX: number = 0;
  @Prop @Watch('requestRedraw') viewportY: number = 0;
  @Prop @Watch('requestRedraw') viewportScale: number = 1;
  @Prop screenW: number = 360;
  @Prop screenH: number = 640;
  /** 浮层尺寸 */
  @Prop mapW: number = 160;
  @Prop mapH: number = 120;
  /** 跳转回调 */
  jumpToWorld: (wx: number, wy: number) => void = () => {};

  private miniCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D();
  private canvasReady: boolean = false;

  /** @Watch 回调：属性变化时触发重绘 */
  requestRedraw(): void {
    if (this.canvasReady) {
      this.draw();
    }
  }

  build(): void {
    Column() {
      Canvas(this.miniCtx)
        .width(this.mapW)
        .height(this.mapH)
        .borderRadius(8)
        .backgroundColor(HCColor.SURFACE)
        .border({ width: 1, color: HCColor.BORDER })
        .onReady(() => {
          this.canvasReady = true;
          this.draw();
        })
        .onTouch((e: TouchEvent) => {
          if (e.type === TouchType.Down && e.touches.length > 0) {
            const t = e.touches[0];
            const nx: number = t.x / this.mapW;
            const ny: number = t.y / this.mapH;
            const world: Rect = MinimapProvider.worldBounds(this.nodes);
            const wx: number = world.x + nx * world.w;
            const wy: number = world.y + ny * world.h;
            this.jumpToWorld(wx, wy);
          }
        })
    }
  }

  private draw(): void {
    const ctx: CanvasRenderingContext2D = this.miniCtx;
    if (ctx === undefined || ctx === null) {
      return;
    }
    ctx.clearRect(0, 0, this.mapW, this.mapH);
    const world: Rect = MinimapProvider.worldBounds(this.nodes);
    // 1. 节点点阵
    for (let i = 0; i < this.nodes.length; i++) {
      const n: CanvasNode = this.nodes[i];
      if (n.deleted) {
        continue;
      }
      const cx: number = n.x + n.w / 2;
      const cy: number = n.y + n.h / 2;
      const pt: MinimapPoint = { x: cx, y: cy };
      const norm = MinimapProvider.normalize(pt, world);
      const px: number = norm.nx * this.mapW;
      const py: number = norm.ny * this.mapH;
      ctx.fillStyle = 'rgba(120, 120, 120, 0.6)';
      ctx.fillRect(px - 1, py - 1, 2, 2);
    }
    // 2. 书签锚点（三类色）
    for (let i = 0; i < this.bookmarks.length; i++) {
      const bm: BookmarkData = this.bookmarks[i];
      const pt: MinimapPoint = { x: bm.x, y: bm.y };
      const norm = MinimapProvider.normalize(pt, world);
      const px: number = norm.nx * this.mapW;
      const py: number = norm.ny * this.mapH;
      ctx.fillStyle = bm.type === BookmarkType.MUST_RECITE ? '#E5484D'
        : bm.type === BookmarkType.EASY_WRONG ? '#F2A100' : '#2D7FF9';
      ctx.beginPath();
      ctx.arc(px, py, 3, 0, Math.PI * 2);
      ctx.fill();
    }
    // 3. 视口框
    const vpRect: Rect = MinimapProvider.viewportRect(world, this.viewportX, this.viewportY, this.viewportScale, this.screenW, this.screenH);
    const vx: number = ((vpRect.x - world.x) / (world.w > 0 ? world.w : 1)) * this.mapW;
    const vy: number = ((vpRect.y - world.y) / (world.h > 0 ? world.h : 1)) * this.mapH;
    const vw: number = (vpRect.w / (world.w > 0 ? world.w : 1)) * this.mapW;
    const vh: number = (vpRect.h / (world.h > 0 ? world.h : 1)) * this.mapH;
    ctx.strokeStyle = '#FF6B35';
    ctx.lineWidth = 1;
    ctx.strokeRect(vx, vy, vw, vh);
  }
}
