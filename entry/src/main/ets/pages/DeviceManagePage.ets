/**
 * DeviceManagePage.ets — 分布式设备管理页（v2.3）
 *
 * 用途：
 *  1. 鸿蒙软总线自动发现附近设备，展示设备名 / 类型 / 角色 / 在线状态；
 *  2. v2.3（修复 K-R2-2）：新增「流转会话设备」区，直接读取 SessionManager
 *     当前会话的设备列表与角色分配（主机 / 本机 / 协作端），
 *     数据源统一经 CollabStatusService.getSessionDeviceRows()，避免页面直接耦合 SessionManager。
 *
 * 注意事项：
 *  - 软总线发现为异步，3s 后汇总结果；无设备时兜底显示本机；
 *  - 会话设备区来自协同态内存读，与软总线发现互不阻塞。
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { DeviceDiscovery, DiscoveredDeviceInfo, DeviceRole } from '../distributed/DeviceDiscovery';
import { PermissionManager, PermissionResult } from '../common/services/PermissionManager';
import { RoleAssigner } from '../distributed/RoleAssigner';
import { CollabStatusService, SessionDeviceRow } from '../common/services/CollabStatusService';
import { SafeAsync } from '../common/utils/SafeAsync';
import { HCColor } from '../common/theme/DesignTokens';
import { BackButton } from '../common/components/BackButton';
import { DeviceAdapter, deviceAdapter } from '../common/services/DeviceAdapter';

@Entry
@Component
struct DeviceManagePage {
  @State devices: DeviceInfo[] = [];
  @State loading: boolean = true;

  // ─── 设备发现能力状态与说明 ───
  @State discoverySupported: boolean = false;
  @State discoveryHint: string = '';

  // ─── v2.3（K-R2-2）：流转会话设备列表与角色分配（数据源 = SessionManager）───
  @State sessionDevices: SessionDeviceRow[] = [];
  @State sessionReady: boolean = false;

  private collabService: CollabStatusService = CollabStatusService.getInstance();
  /** v2.7.0：本机设备参数（无需任何权限） */
  private deviceAdapter: DeviceAdapter = deviceAdapter;
  /**
   * v2.5.1：设备发现汇总定时器句柄。
   * 原先是裸 setTimeout(...,3000)，aboutToDisappear 只停了发现、没清这个回调，
   * 用户 3 秒内离开页面时它会继续给已销毁页面塞 devices / loading。
   */
  private discoveryTimer: number = -1;

  aboutToAppear(): void {
    // 🔧 v2.7.0：先以**真实包名**初始化设备管理器，再加载设备。
    //   此前 initialize() 从未被调用、且内部包名硬编码错误，
    //   导致本页永远显示"附近设备发现功能开发中"。
    this.initDiscoveryThenLoad();
    this.loadSessionDevices();
  }

  private initDiscoveryThenLoad(): void {
    const dd = DeviceDiscovery.getInstance();
    if (dd.isDiscoverySupported()) {
      this.loadDevices();
      return;
    }
    this.loading = true;
    // 🔴 v2.7.7 审核修复（问题①「两个平板登录同一账号、打开超级终端后仍读取不到设备」**真正根因**）
    //   `ohos.permission.DISTRIBUTED_DATASYNC` 是 **user_grant** 权限：
    //   仅在 module.json5 里声明**远远不够**，还必须在运行时动态申请。
    //   工程内 `PermissionManager` 早已实现申请逻辑，却**从未被任何地方调用**，
    //   于是 `distributedDeviceManager.getAvailableDeviceListSync()` 抛 201（权限拒绝），
    //   设备列表恒为空 —— 与是否登录同账号、是否开启超级终端无关。
    //   现在先申请权限，授权成功后再创建设备管理器并拉取设备。
    this.ensurePermissionThenInit();
  }

  /** v2.7.7：动态申请分布式权限 → 授权成功后初始化设备管理器 */
  private ensurePermissionThenInit(): void {
    SafeAsync.runAsyncVoid('DeviceManagePage', 'ensureDistributedPermission', async (): Promise<void> => {
      let granted: boolean = false;
      try {
        const result: PermissionResult = await PermissionManager.getInstance().requestDistributedPermission();
        granted = result.granted;
      } catch (e) {
        Logger.error('DeviceManagePage', `申请分布式权限异常: ${(e as Error).message}`);
        granted = false;
      }
      if (!granted) {
        this.loading = false;
        this.discoverySupported = false;
        this.discoveryHint = '未获得「分布式数据同步」权限，暂时无法发现同账号下的其他设备。\n'
          + '请到「设置 → 应用 → 鸿绘协作板 → 权限」中开启该权限，然后点下方按钮重试。';
        return;
      }
      Logger.info('DeviceManagePage', '已获得分布式数据同步权限，开始初始化设备管理器');
      this.createDeviceManagerAndLoad();
    });
  }

  /** v2.7.7：创建分布式设备管理器并加载设备（授权通过后调用） */
  private createDeviceManagerAndLoad(): void {
    const dd = DeviceDiscovery.getInstance();
    SafeAsync.runVoid('DeviceManagePage', 'initDeviceDiscovery', (): void => {
      let bundle: string = '';
      try {
        const ctx: common.Context = getContext(this) as common.Context;
        bundle = ctx.applicationInfo !== undefined && ctx.applicationInfo !== null
          ? ctx.applicationInfo.name : '';
      } catch (e) {
        Logger.warn('DeviceManagePage', `读取包名失败: ${(e as Error).message}`);
      }
      if (bundle.length === 0) {
        bundle = 'com.honghui.note';
      }
      dd.initialize('local', bundle).then((): void => {
        this.loadDevices();
      }).catch((err: Error): void => {
        Logger.error('DeviceManagePage', `设备管理器初始化失败: ${err.message}`);
        this.loading = false;
        this.discoverySupported = false;
        this.discoveryHint = dd.getUnavailableReason();
      });
    });
  }

  aboutToDisappear(): void {
    DeviceDiscovery.getInstance().stopDiscovery();
    // v2.5.1：清掉 3 秒汇总回调，避免向已销毁页面写 @State
    if (this.discoveryTimer !== -1) {
      clearTimeout(this.discoveryTimer);
      this.discoveryTimer = -1;
    }
  }

  // ─── v2.3（K-R2-2）：流转会话设备 ───

  /**
   * 读取流转会话内设备列表与角色分配（SessionManager 当前态）。
   * 经 CollabStatusService 统一走 SafeAsync 兜底，会话未创建时返回空数组。
   */
  private loadSessionDevices(): void {
    this.sessionReady = true;
    SafeAsync.runVoid('DeviceManagePage', 'loadSessionDevices', () => {
      this.sessionDevices = this.collabService.getSessionDeviceRows();
    });
  }

  /** 流转会话设备区（直接展示 SessionManager 当前会话中的设备与角色） */
  @Builder
  buildSessionSection() {
    Column() {
      Row() {
        Text('流转会话设备')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(HCColor.TEXT_PRIMARY)
        Blank()
        Text(this.sessionReady ? `${this.sessionDevices.length} 台` : '—')
          .fontSize(12)
          .fontColor(HCColor.ICON_SECONDARY)
      }
      .width('100%')
      .margin({ bottom: 8 })

      if (this.sessionDevices.length === 0) {
        Text('未创建流转会话（在首页「开始流转会话」或加入协作后可见）')
          .fontSize(12)
          .fontColor(HCColor.ICON_SECONDARY)
          .width('100%')
      } else {
        ForEach(this.sessionDevices, (row: SessionDeviceRow) => {
          Row() {
            Column() {
              Text(this.deviceBadge(row))
                .fontSize(20)
                .textAlign(TextAlign.Center)
            }
            .width(44)
            .alignItems(HorizontalAlign.Center)

            Column() {
              Text(this.deviceLabel(row))
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
              Text(row.roleText)
                .fontSize(11)
                .fontColor(HCColor.PRIMARY)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(HCColor.PRIMARY_BG)
                .borderRadius(4)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Text(row.shortId)
              .fontSize(10)
              .fontColor(HCColor.TEXT_DISABLED)
          }
          .width('100%')
          .padding(12)
          .margin({ top: 1 })
          .backgroundColor(HCColor.SURFACE)
          .borderRadius(0)
        }, (row: SessionDeviceRow) => row.deviceId)
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(10)
    .margin({ top: 10 })
  }

  private deviceBadge(row: SessionDeviceRow): string {
    if (row.isHost) {
      return '主';
    }
    if (row.isLocal) {
      return '机';
    }
    return '连';
  }

  private deviceLabel(row: SessionDeviceRow): string {
    if (row.isHost) {
      return '主机设备';
    }
    if (row.isLocal) {
      return '本机';
    }
    return '协作设备';
  }

  build() {
    Column() {
      // 统一返回按钮 + 标题 + 刷新动作
      BackButton({
        title: '设备管理',
        rightIcon: '刷新',
        rightAction: () => {
          this.loadDevices();
          this.loadSessionDevices();
        }
      })

      // ═══ v2.7.0：页面主体改为「真实内容优先」═══════════════════════
      //  审核反馈"提示附近设备发现功能开发中"属功能异常。根治方式不是继续堆提示文字，
      //  而是让本页在**不依赖任何系统权限**的前提下就有真实、可用的内容：
      //    ① 本机设备（型号/类型/屏幕/折叠/墨水屏适配参数）—— 始终可用
      //    ② 当前协作会话中的设备与角色 —— 始终可用（应用自身数据）
      //    ③ 附近设备 —— 依赖系统「超级终端」，为空时给出准确启用条件
      Scroll() {
        Column() {
          // ① 本机设备
          this.buildLocalDeviceCard()

          // ② 流转会话设备
          this.buildSessionSection()

          // ③ 附近设备
          Column() {
            Row() {
              Text('附近设备')
                .fontSize(15).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
              Blank()
              Text(this.devices.length > 0 ? `${this.devices.length} 台` : '—')
                .fontSize(12).fontColor(HCColor.ICON_SECONDARY)
            }
            .width('100%')
            .margin({ bottom: 8 })

            if (this.loading) {
              Row() {
                LoadingProgress().width(20).height(20).color(HCColor.PRIMARY)
                Text('正在读取…').fontSize(12).fontColor(HCColor.ICON_SECONDARY).margin({ left: 8 })
              }
              .width('100%')
            } else if (this.devices.length === 0) {
              Text(this.discoveryHint.length > 0
                ? this.discoveryHint
                : '附近设备需在「设置-超级终端」中连接同一华为账号的设备后可见')
                .fontSize(12)
                .fontColor(HCColor.ICON_SECONDARY)
                .width('100%')
              Text('重新读取')
                .fontSize(12).fontColor(HCColor.PRIMARY)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .backgroundColor(HCColor.PRIMARY_BG)
                .borderRadius(14)
                .margin({ top: 10 })
                .onClick((): void => {
                  // 🔴 v2.7.7：改走完整流程 —— 用户可能刚在系统设置里开启了权限，
                  //   这里需要**重新申请/校验权限**后再拉取设备，否则仍会读到空列表。
                  this.initDiscoveryThenLoad();
                })
            } else {
              ForEach(this.devices, (device: DeviceInfo) => {
                this.buildDeviceCard(device)
              })
            }
          }
          .width('100%')
          .padding(14)
          .backgroundColor(HCColor.SURFACE)
          .borderRadius(10)
          .margin({ top: 10 })

          // 底部说明
          Text('协作采用「本机房间 + 鸿蒙分布式软总线」：单设备可用本机房间完整验证，多设备需在同一华为账号下通过超级终端连接')
            .fontSize(11)
            .fontColor(HCColor.TEXT_DISABLED)
            .width('100%')
            .margin({ top: 12, bottom: 20 })
        }
        .width('100%')
        .padding({ left: 14, right: 14 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%').height('100%').backgroundColor(HCColor.PAGE_BG)
  }

  /**
   * v2.7.0：本机设备卡片（数据源 DeviceAdapter，全部为无需权限的公开信息）。
   * 用途：让用户在"手动对齐设备"场景下能读出本机参数与设备标识。
   */
  @Builder
  buildLocalDeviceCard() {
    Column() {
      Row() {
        Text('本机设备')
          .fontSize(15).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
        Blank()
        Text('当前设备').fontSize(11).fontColor(HCColor.PRIMARY)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(HCColor.PRIMARY_BG).borderRadius(4)
      }
      .width('100%')
      .margin({ bottom: 10 })

      this.buildLocalInfoRow('设备类型', this.localDeviceTypeText())
      this.buildLocalInfoRow('屏幕尺寸', this.localScreenText())
      this.buildLocalInfoRow('折叠形态', this.localFoldText())
      this.buildLocalInfoRow('协作标识', this.localDeviceIdText())
    }
    .width('100%')
    .padding(14)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(10)
    .margin({ top: 10 })
  }

  @Builder
  buildLocalInfoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(12).fontColor(HCColor.ICON_SECONDARY).width(72)
      Text(value).fontSize(12).fontColor(HCColor.TEXT_PRIMARY).layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 5, bottom: 5 })
  }

  /** 本机设备类型文案（DeviceAdapter 真实读取） */
  private localDeviceTypeText(): string {
    const info = this.deviceAdapter.getDeviceInfo();
    if (info === null) {
      return '未知';
    }
    if (info.isEInk) {
      return '墨水屏设备';
    }
    if (info.isFoldable) {
      return '折叠屏设备';
    }
    if (this.deviceAdapter.isTablet()) {
      return '平板';
    }
    if (this.deviceAdapter.isPhone()) {
      return '手机';
    }
    return this.deviceAdapter.isLargeScreen() ? '大屏设备' : '移动设备';
  }

  /** 屏幕尺寸文案 */
  private localScreenText(): string {
    const info = this.deviceAdapter.getDeviceInfo();
    if (info === null) {
      return '未知';
    }
    const w: number = Math.round(info.screenWidth / (info.density > 0 ? info.density : 1));
    const h: number = Math.round(info.screenHeight / (info.density > 0 ? info.density : 1));
    return `${w} × ${h} vp（${info.isLandscape ? '横屏' : '竖屏'}）`;
  }

  /** 折叠形态文案 */
  private localFoldText(): string {
    const info = this.deviceAdapter.getDeviceInfo();
    if (info === null || !info.isFoldable) {
      return '非折叠设备';
    }
    return `折叠屏 · 状态 ${info.foldStatus} · 显示 ${info.foldDisplayMode}`;
  }

  /** 协作标识：本机在协作中的稳定标识（用于设备间手动对齐） */
  private localDeviceIdText(): string {
    try {
      const id: string = this.collabService.ensureLocalDeviceId();
      return id !== undefined && id !== null && id.length > 0 ? id : '（尚未生成）';
    } catch (e) {
      return '（尚未生成）';
    }
  }

  /** 页面转场动画 */
  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }

  @Builder buildDeviceCard(device: DeviceInfo) {
    Row() {
      Column() {
        Text(this.getDeviceIcon(device)).fontSize(36)
      }.width(60).alignItems(HorizontalAlign.Center)

      Column() {
        Text(device.name).fontSize(15).fontWeight(FontWeight.Medium)
        Row() {
          Text(device.role).fontSize(11).fontColor(HCColor.PRIMARY)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(HCColor.PRIMARY_BG).borderRadius(4)
          Text(device.type).fontSize(11).fontColor(HCColor.ICON_SECONDARY).margin({ left: 8 })
        }.margin({ top: 4 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      Row() {
        Circle().width(8).height(8).fill(device.online ? HCColor.SUCCESS : HCColor.TEXT_DISABLED)
        Text(device.online ? '在线' : '离线').fontSize(11).fontColor(HCColor.ICON_SECONDARY).margin({ left: 4 })
      }
    }
    .width('100%').padding(14)
    .margin({ top: 1 })
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(0)
  }

  private getDeviceIcon(device: DeviceInfo): string {
    switch (device.role) {
      case 'HOST': return '主';
      case 'DRAW': return '写';
      case 'DISPLAY': return '屏';
      case 'CONTROLLER': return '机';
      default: return '机';
    }
  }

  /**
   * 加载附近可协作设备。
   *
   * 🔧 v2.7.0 审核修复（问题③-2「我的-设备管理，提示附近设备发现功能开发中」）：
   *   真因有两条 ——
   *   ① `DeviceDiscovery.initialize()` **全项目从未被调用**，内部 dmInstance 恒为 null，
   *      isDiscoverySupported() 必然 false，页面永远走"开发中"分支；
   *   ② initialize 内部把 bundleName 硬编码成 'com.harmonycanvas.app'，
   *      与本应用真实包名 com.honghui.note 不符，即便调用了也创建不出 DeviceManager。
   *   现在：先注入**真实包名**完成初始化，再读取同账号下已就绪的分布式设备。
   *   拿不到设备时给出可操作的指引，而不是一句"开发中"把用户挡死。
   */
  private loadDevices(): void {
    const dd = DeviceDiscovery.getInstance();
    // 🔴 v2.7.1 审核修复（问题③-1「附近设备：点击重新获取无反应」）：
    //   此前重新读取没有任何即时反馈 —— 无设备时状态与点击前完全一致，
    //   用户无法区分"点了没反应"和"确实没有设备"。
    //   现增加：加载态 + 明确结果 Toast（发现 N 台 / 未发现 + 原因）。
    this.loading = true;
    SafeAsync.runVoid('DeviceManagePage', 'loadDevices', (): void => {
      this.applyRealDeviceList(dd);
    });
  }

  private applyRealDeviceList(dd: DeviceDiscovery): void {
    this.discoverySupported = dd.isDiscoverySupported();
    if (!this.discoverySupported) {
      this.loading = false;
      this.devices = [];
      this.discoveryHint = dd.getUnavailableReason();
      promptAction.showToast({ message: '重新读取完成：未发现可用设备（本机信息不受影响）', duration: 2000 });
      return;
    }
    // 真实读取同账号下已就绪设备（同步返回，无需 3 秒空等）
    const discovered: DiscoveredDeviceInfo[] = dd.refreshAvailableDevices();
    this.loading = false;
    if (discovered.length === 0) {
      this.devices = [];
      // v2.7.0：不再出现"开发中"；给出准确、可操作的启用条件
      this.discoveryHint = dd.getUnavailableReason();
      // v2.7.1：明确回执，避免"点了没反应"的观感
      promptAction.showToast({ message: '重新读取完成：未发现已就绪的附近设备', duration: 2000 });
      return;
    }
    const ra: RoleAssigner = RoleAssigner.getInstance();
    this.devices = discovered.map((d: DiscoveredDeviceInfo): DeviceInfo => {
      const assignedRole: DeviceRole | undefined = ra.getAssignedRole(d.deviceId);
      const roleStr: string = assignedRole !== undefined ? assignedRole : 'VIEWER';
      return {
        name: d.deviceName !== undefined && d.deviceName.length > 0 ? d.deviceName : d.deviceId,
        type: d.deviceType !== undefined && d.deviceType.length > 0 ? d.deviceType : 'unknown',
        role: roleStr,
        online: d.isOnline !== false,
      };
    });
    promptAction.showToast({ message: `重新读取完成：发现 ${this.devices.length} 台设备`, duration: 2000 });
  }
}

interface DeviceInfo {
  name: string;
  type: string;
  role: string;
  online: boolean;
}
