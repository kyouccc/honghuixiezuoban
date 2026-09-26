/**
 * LinkLayer.ets — 双链连线浮层（NOTE-02，阶段2）
 *
 * 在画布 Stack 内叠加，绘制节点间的双链连线。
 * 连线默认半透明；选中链高亮。坐标变换与便签叠加层一致（屏幕 = viewport + scale*逻辑）。
 */

import { CanvasNode, LinkData } from '../engine/types/BoardModel';
import { HCColor } from '../common/theme/DesignTokens';

@Component
export struct LinkLayer {
  /** 全部活跃链接（已过滤 deleted） */
  @Prop links: LinkData[] = [];
  /** 全部节点（查端点坐标） */
  @Prop nodes: CanvasNode[] = [];
  /** 视口变换 */
  @Prop viewportX: number = 0;
  @Prop viewportY: number = 0;
  @Prop viewportScale: number = 1;
  /** 当前选中链 id（高亮） */
  @Prop selectedLinkId: string = '';

  private nodeMap: Map<string, CanvasNode> = new Map<string, CanvasNode>();

  aboutToAppear(): void {
    this.rebuildMap();
  }

  aboutToUpdate(): void {
    this.rebuildMap();
  }

  private rebuildMap(): void {
    this.nodeMap.clear();
    for (let i = 0; i < this.nodes.length; i++) {
      this.nodeMap.set(this.nodes[i].id, this.nodes[i]);
    }
  }

  /** 逻辑坐标 → 屏幕逻辑坐标（vp） */
  private toScreen(lx: number, ly: number): ScreenPoint {
    const result: ScreenPoint = {
      x: this.viewportX + this.viewportScale * lx,
      y: this.viewportY + this.viewportScale * ly
    };
    return result;
  }

  build(): void {
    Canvas(this.linkContext)
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      .onReady(() => {
        this.drawLinks();
      })
  }

  private linkContext: CanvasRenderingContext2D = new CanvasRenderingContext2D();

  private drawLinks(): void {
    const ctx: CanvasRenderingContext2D = this.linkContext;
    if (ctx === undefined || ctx === null) {
      return;
    }
    // 🔴 v2.7.1：ctx.width/height 是 vp；单位阵下按 vp 清只能清左上 1/4（dpr=2），
    //   右下残留上一帧的连线 → 表现为「删除节点后仍有幽灵连线」。
    //   必须按物理缓冲区尺寸清理。
    ctx.clearRect(0, 0, vp2px(ctx.width), vp2px(ctx.height));
    for (let i = 0; i < this.links.length; i++) {
      const link: LinkData = this.links[i];
      if (link.deleted) {
        continue;
      }
      const from: CanvasNode | undefined = this.nodeMap.get(link.from);
      const to: CanvasNode | undefined = this.nodeMap.get(link.to);
      if (from === undefined || to === undefined) {
        continue; // 端点已删，不画幽灵连线
      }
      const a = this.toScreen(from.x + from.w / 2, from.y + from.h / 2);
      const b = this.toScreen(to.x + to.w / 2, to.y + to.h / 2);
      const selected: boolean = link.id === this.selectedLinkId;
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      // 二次曲线，控制点取中点上方偏移，呈现自然弧度
      const midX: number = (a.x + b.x) / 2;
      const midY: number = (a.y + b.y) / 2 - Math.abs(a.x - b.x) * 0.15;
      ctx.quadraticCurveTo(midX, midY, b.x, b.y);
      if (selected) {
        ctx.strokeStyle = '#FF6B35'; // 高亮橙（选中）
        ctx.lineWidth = 3;
      } else {
        ctx.strokeStyle = 'rgba(80, 120, 200, 0.45)'; // 半透明蓝
        ctx.lineWidth = 1.5;
      }
      ctx.stroke();
    }
  }
}

interface ScreenPoint {
  x: number;
  y: number;
}
