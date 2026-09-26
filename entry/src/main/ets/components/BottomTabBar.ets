/**
 * BottomTabBar.ets — 底部 Pill Tab 导航（U-01 落地 v4.1 导航修复版）
 *
 * v4.1 修复（P0-2 导航统一，2026-08-21）：
 *  - 「协作」Tab：去掉 placeholder toast，直跳 JoinRoomPage 真实页面；
 *  - 「我的」Tab：去掉 placeholder toast，直跳 Index 页（真实页面）；
 *  - 导航逻辑统一：Tab 所见即所得，不再用占位 toast 误导用户。
 *
 * v2.4 优化升级：从「顶部搜索+更多」的单页跳转改为「底部 Tab 骨架」全局导航。
 * 设计依据：T01 DesignTokens（HCColor 收敛 / HCSpace 间距 / HCRadius 圆角 / HCFont 字号）。
 * 风格参考：现代移动 App 标配（参考 Starnote 颜值 / 享做笔记 + HarmonyOS 蓝体系）。
 *
 * 约束：
 *  - 不依赖任何 Service（不引 NoteEngine/Repository/Analytics），纯展示组件；
 *  - 颜色全部走 HCColor.*（Resource 类型，自动暗色切换），禁止硬编码 hex。
 */

import { router, promptAction } from '@kit.ArkUI';
import { HCColor } from '../common/theme/DesignTokens';
import { FEATURE_COLLAB_ENABLED } from '../common/Constants';

/** Tab 标识常量：与 onActiveKey 严格匹配 */
export const TAB_KEY_NOTES: string = 'notes';
export const TAB_KEY_COLLAB: string = 'collab';
export const TAB_KEY_ME: string = 'me';

/** 单个 Tab 的描述 */
interface TabSpec {
  key: string;
  label: string;
  /** SVG 路径字符串，外框 24×24 viewBox */
  iconPath: string;
  /** 路由目标 */
  route: string;
}

@Component
export struct BottomTabBar {
  /** 当前激活的 Tab key */
  @Prop activeKey: string = TAB_KEY_NOTES;

  /**
   * 🔧 v2.7.0 审核修复（问题② 底部导航条适配）：
   *   原实现把「home indicator 高度」硬编码为 24vp，平板上系统导航条更高时，
   *   胶囊 Tab 会被导航条盖住（审核截图：底部「我的」被截断）。
   *   现读取 EntryAbility 写入 AppStorage 的真实底部避让高度（键 hcSafeAreaBottom），
   *   取 max(24, 真实值) 作为底部内边距，设备无关地避免重叠。
   */
  @StorageProp('hcSafeAreaBottom') safeBottom: number = 0;

  /** 底部内边距：至少 24vp（手机手势条），平板上按系统实际高度取大值 */
  private bottomInset(): number {
    const v: number = this.safeBottom;
    return v !== undefined && v !== null && v > 24 ? v : 24;
  }

  private buildTabs(): TabSpec[] {
    // 🔴 v2.7.5：协作功能暂时下线（见 Constants.FEATURE_COLLAB_ENABLED 注释）。
    //   开关关闭时不渲染「协作」Tab，避免审核测到尚未验证完成的跨设备共享能力。
    //   实现保留在 pages/JoinRoomPage，下一版本把开关置 true 即恢复。
    if (!FEATURE_COLLAB_ENABLED) {
      return [
        {
          key: TAB_KEY_NOTES,
          label: '笔记',
          iconPath: 'M5 3H19C19.55 3 20 3.45 20 4V20C20 20.55 19.55 21 19 21H5C4.45 21 4 20.55 4 20V4C4 3.45 4.45 3 5 3Z M8 7H16 M8 11H16 M8 15H13',
          route: 'pages/NotePage',
        },
        {
          key: TAB_KEY_ME,
          label: '我的',
          iconPath: 'M12 12C14.21 12 16 10.21 16 8C16 5.79 14.21 4 12 4C9.79 4 8 5.79 8 8C8 10.21 9.79 12 12 12Z M12 14C9.33 14 4 15.34 4 18V20H20V18C20 15.34 14.67 14 12 14Z',
          route: 'pages/Index',
        },
      ];
    }
    return [
      {
        key: TAB_KEY_NOTES,
        label: '笔记',
        iconPath: 'M5 3H19C19.55 3 20 3.45 20 4V20C20 20.55 19.55 21 19 21H5C4.45 21 4 20.55 4 20V4C4 3.45 4.45 3 5 3Z M8 7H16 M8 11H16 M8 15H13',
        route: 'pages/NotePage',
      },
      {
        key: TAB_KEY_COLLAB,
        label: '协作',
        iconPath: 'M9 8C10.66 8 12 6.66 12 5C12 3.34 10.66 2 9 2C7.34 2 6 3.34 6 5C6 6.66 7.34 8 9 8Z M17 8C18.1 8 19 7.1 19 6C19 4.9 18.1 4 17 4C15.9 4 15 4.9 15 6C15 7.1 15.9 8 17 8Z M3 19C3 15.67 6.34 13 9 13C11.66 13 15 15.67 15 19V20H3V19Z M15.83 11.61C16.93 12.43 17.5 13.62 17.5 15V20H21V18C21 15.79 18.74 13.95 15.83 13.4',
        route: 'pages/JoinRoomPage',
      },
      {
        key: TAB_KEY_ME,
        label: '我的',
        iconPath: 'M12 12C14.21 12 16 10.21 16 8C16 5.79 14.21 4 12 4C9.79 4 8 5.79 8 8C8 10.21 9.79 12 12 12Z M12 14C9.33 14 4 15.34 4 18V20H20V18C20 15.34 14.67 14 12 14Z',
        route: 'pages/Index',
      },
    ];
  }

  build() {
    Row() {
      ForEach(this.buildTabs(), (tab: TabSpec) => {
        this.tabItem(tab)
      }, (tab: TabSpec): string => tab.key)
    }
    .width('100%')
    // 64 胶囊 + 底部真实避让高度（v2.7.0：不再写死 24vp）
    .height(64 + this.bottomInset())
    .padding({ left: 24, right: 24, top: 12, bottom: this.bottomInset() })
    .backgroundColor(HCColor.PAGE_BG)
  }

  @Builder
  tabItem(tab: TabSpec) {
    Column() {
      Path({ width: 22, height: 22 })
        .commands(tab.iconPath)
        .fill(Color.Transparent)
        .stroke(this.isActive(tab) ? HCColor.SURFACE : HCColor.ICON_SECONDARY)
        .strokeWidth(1.8)
        .strokeLineJoin(LineJoinStyle.Round)
        .strokeLineCap(LineCapStyle.Round)

      Text(tab.label)
        .fontSize(10)
        .fontColor(this.isActive(tab) ? HCColor.SURFACE : HCColor.ICON_SECONDARY)
        .fontWeight(this.isActive(tab) ? FontWeight.Bold : FontWeight.Regular)
        .margin({ top: 3 })
        .letterSpacing(0.4)
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .borderRadius(26)
    .backgroundColor(this.isActive(tab) ? HCColor.PRIMARY : Color.Transparent)
    .onClick((): void => {
      this.handleTap(tab);
    })
  }

  private isActive(tab: TabSpec): boolean {
    return tab.key === this.activeKey;
  }

  private handleTap(tab: TabSpec): void {
    if (this.isActive(tab)) {
      return; // 已激活不重复跳
    }

    // 真实跳转
    router.pushUrl({ url: tab.route }).catch((err: Error): void => {
      this.showToast('页面跳转失败：' + err.message);
    });
  }

  private showToast(message: string): void {
    promptAction.showToast({ message: message, duration: 2000 });
  }
}
