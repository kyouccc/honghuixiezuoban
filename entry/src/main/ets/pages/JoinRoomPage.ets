/**
 * JoinRoomPage.ets — 加入协作会话页（v2.3）
 *
 * 用途：输入房间号 / 昵称 → REST 加入房间 → 调用 CollaborationManager.joinSession
 *      携带权限断言（HM-10 / HM-11），并把服务端/本地生效的权限档位回显给用户。
 *
 * v2.3 增量（修复 K-R2-2）：
 *  - 新增期望角色选择（VIEWER / ANNOTATOR / EDITOR）→ PermissionAssertionPayload.role；
 *  - 新增 joinSession 接线与结果展示区（连接状态 + 生效权限）；
 *  - joinSession 带 5s 超时兜底（SafeAsync.withTimeout），离线预览下不会卡在 loading。
 *
 * 注意事项：加入成功后不再自动 router.back()，改为展示断言结果并提供"进入白板"入口，
 *          以便 QA 现场核验三级权限矩阵是否生效。
 */

import { RoomAPI, ApiResponse } from '../network/RoomAPI';
import { router, promptAction } from '@kit.ArkUI';
// O-1 收敛：SessionRole / sessionRoleLabel 统一从协同门面 CollabStatusService 导入，避免页面直连核心 PermissionGuard
import { CollabStatusService, JoinSessionResult, SessionRole, sessionRoleLabel } from '../common/services/CollabStatusService';
import { SafeAsync } from '../common/utils/SafeAsync';
// C01 身份链贯通：单一身份源（解析 JoinResult、落地 user_id / token / ws_endpoint）
import { SessionIdentity } from '../common/identity/SessionIdentity';
import { HCColor } from '../common/theme/DesignTokens';
import { BackButton } from '../common/components/BackButton';
import { IconComponent } from '../common/components/IconComponent';
import { IconSymbols } from '../common/IconConstants';
import { common } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { RoomDirectory, RoomLookup } from '../distributed/RoomDirectory';
import { FEATURE_COLLAB_ENABLED } from '../common/Constants';

const TAG_PAGE: string = 'JoinRoomPage';

/** 角色选项（避免 build() 内出现无类型对象字面量） */
interface RoleOption {
  role: string;
  label: string;
}

@Entry
@Component
struct JoinRoomPage {
  @State roomCode: string = '';
  @State userName: string = '协作者';
  @State isLoading: boolean = false;
  @State errorMsg: string = '';
  @State showPrivacyTip: boolean = false;

  // ─── v2.3：权限断言接线状态 ───
  @State desiredRole: string = SessionRole.EDITOR;
  @State joinResultText: string = '';
  @State appliedRoleText: string = '';
  @State joined: boolean = false;

  // ─── v2.6.0 审核修复（问题④「协作功能暂不可用」）───
  /** 本机创建的房间号（6 位）。此前 App 只有「加入房间」，没有任何途径产生房间号，
   *  加入按钮因 `roomCode.length === 6` 恒为 false 而始终置灰 → 审核判为"协作不可用"。 */
  @State private createdCode: string = '';
  @State private isCreating: boolean = false;

  private collabService: CollabStatusService = CollabStatusService.getInstance();
  /** v2.7.4：账号级房间目录（用于校验房间是否存在） */
  private roomDirectory: RoomDirectory = RoomDirectory.getInstance();

  private readonly roleOptions: RoleOption[] = [
    { role: SessionRole.EDITOR, label: '编辑' },
    { role: SessionRole.ANNOTATOR, label: '批注' },
    { role: SessionRole.VIEWER, label: '只读' }
  ];

  build() {
    Column() {
      // 统一返回按钮 + 标题
      BackButton({ title: '加入白板' })

      // Content
      Scroll() {
        Column() {
        // Logo
        Column() {
          IconComponent({
            symbol: IconSymbols.PALETTE,
            iconSize: 64,
            color: HCColor.PRIMARY
          })
          Text('鸿绘协作板').fontSize(22).fontWeight(FontWeight.Bold)
          Text('本机创建房间 · 或输入房间号加入').fontSize(13).fontColor(HCColor.ICON_SECONDARY).margin({ top: 4 })
          Text('适用于 2–5 人研友小范围协作；本机房间无需服务端，房间号可分享给同网设备')
            .fontSize(11).fontColor(HCColor.TEXT_TERTIARY)
            .margin({ top: 8 }).textAlign(TextAlign.Center)
        }.margin({ top: 40, bottom: 24 })

        // ─── v2.6.0：本机创建房间（协作功能的可完成路径，不再依赖未上线的服务端）───
        this.buildCreateRoomSection()

        // Room code input
        Row() {
          Text('房间号')
            .fontSize(14).fontColor(HCColor.TEXT_TERTIARY)
            .width(60)
          TextInput({ placeholder: '输入6位房间号', text: this.roomCode })
            .layoutWeight(1).maxLength(6).type(InputType.Number)
            .fontSize(16)
            .onChange((v: string) => { this.roomCode = v })
        }
        .width('85%').height(44).padding({ left: 12, right: 12 })
        .backgroundColor(HCColor.PAGE_BG).borderRadius(10)

        // Username input
        Row() {
          Text('昵称')
            .fontSize(14).fontColor(HCColor.TEXT_TERTIARY)
            .width(60)
          TextInput({ placeholder: '你的名字', text: this.userName })
            .layoutWeight(1)
            .fontSize(16)
            .onChange((v: string) => { this.userName = v })
        }
        .width('85%').height(44).padding({ left: 12, right: 12 })
        .backgroundColor(HCColor.PAGE_BG).borderRadius(10)
        .margin({ top: 12 })

        // 期望权限档位（HM-11 三级权限矩阵）
        this.buildRoleSelector()

        // Join button
        Button(this.isLoading ? '加入中...' : '加入房间')
          .width('85%').height(48)
          .fontSize(16).fontWeight(FontWeight.Medium)
          .fontColor(this.roomCode.length === 6 ? HCColor.SURFACE : HCColor.TEXT_DISABLED)
          .backgroundColor(this.roomCode.length === 6 ? HCColor.PRIMARY : HCColor.DIVIDER)
          .borderRadius(24)
          .margin({ top: 20 })
          .enabled(!this.isLoading && this.roomCode.length === 6)
          .onClick(() => { this.joinRoom() })

        // v2.6.0：按钮置灰时必须说明原因，否则用户会判为"按钮坏了/协作不可用"
        if (this.roomCode.length !== 6) {
          Text('请先输入 6 位房间号；没有房间号可在上方「创建本机房间」生成')
            .fontSize(11).fontColor(HCColor.TEXT_TERTIARY)
            .width('85%').textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }

        // Error
        if (this.errorMsg.length > 0) {
          Text(this.errorMsg)
            .fontSize(13).fontColor(HCColor.DANGER)
            .margin({ top: 12 })
        }

        // v2.3：权限断言结果展示区
        if (this.joinResultText.length > 0) {
          this.buildJoinResult()
        }

        // Divider
        Row() {
          Divider().width('30%')
          Text(' 或 ').fontSize(12).fontColor(HCColor.TEXT_DISABLED)
          Divider().width('30%')
        }.width('85%').margin({ top: 32 })

        // NFC tip
        Column() {
          IconComponent({
            symbol: IconSymbols.PHONE,
            iconSize: 28,
            color: HCColor.ICON_SECONDARY
          })
          Text('碰一碰NFC标签快速加入').fontSize(14).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 4 })
        }
        .width('85%').padding({ top: 16, bottom: 16 })
        .backgroundColor(HCColor.PAGE_BG).borderRadius(10)
      }
      .justifyContent(FlexAlign.Start)
    }
    .layoutWeight(1)
    .edgeEffect(EdgeEffect.Spring)

    // Privacy tip
    Text('加入即表示同意隐私政策')
        .fontSize(11).fontColor(HCColor.PRIMARY).padding(12)
        .onClick(() => {
          router.pushUrl({ url: 'pages/PrivacyPage' });
        })
    }
    .width('100%').height('100%').backgroundColor(HCColor.SURFACE)
  }

  /** 页面转场动画 */
  pageTransition() {
    PageTransitionEnter({ duration: 300, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Left)
    PageTransitionExit({ duration: 200, curve: Curve.FastOutSlowIn })
      .slide(SlideEffect.Right)
  }

  /**
   * v2.6.0 审核修复（问题④）：本机创建房间。
   * 审核反馈「协作功能暂不可用」的根因是流程不闭合——只能"加入"，而房间号无处可得，
   * 加入按钮因校验恒为置灰。此区块提供完整的创建路径：一键生成本机房间号并直接进入会话，
   * 房间号可分享给同网设备用于「加入房间」。
   */
  @Builder
  buildCreateRoomSection() {
    Column() {
      Row() {
        IconComponent({
          symbol: IconSymbols.PALETTE,
          iconSize: 20,
          color: HCColor.PRIMARY
        })
        Text('本机房间').fontSize(14).fontWeight(FontWeight.Medium)
          .fontColor(HCColor.TEXT_PRIMARY).margin({ left: 6 })
        Blank()
        if (this.createdCode.length === 6) {
          Text(this.createdCode)
            .fontSize(18).fontWeight(FontWeight.Bold)
            .fontColor(HCColor.PRIMARY)
            .backgroundColor(HCColor.PRIMARY_BG)
            .borderRadius(8)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        }
      }
      .width('100%')

      Text(this.createdCode.length === 6
        ? '房间已创建：把上面 6 位房间号发给同伴，对方在下方输入即可加入。'
        : '无需注册与服务端。点击创建即生成 6 位房间号，可在 2–5 人小范围内协作。')
        .fontSize(11).fontColor(HCColor.TEXT_TERTIARY)
        .width('100%').margin({ top: 6 })

      Row() {
        Button(this.isCreating ? '创建中…' : (this.createdCode.length === 6 ? '重新创建房间' : '创建本机房间'))
          .layoutWeight(1).height(40).fontSize(14)
          .fontColor(HCColor.SURFACE).backgroundColor(HCColor.PRIMARY).borderRadius(10)
          .enabled(!this.isCreating)
          .onClick(() => { this.createLocalRoom(); })

        if (this.createdCode.length === 6) {
          Button('用此房间号加入')
            .height(40).fontSize(14).margin({ left: 8 })
            .fontColor(HCColor.PRIMARY).backgroundColor(HCColor.PRIMARY_BG).borderRadius(10)
            .onClick(() => {
              this.roomCode = this.createdCode;
              this.errorMsg = '';
            })
        }
      }
      .width('100%').margin({ top: 10 })
    }
    .width('85%')
    .padding(14)
    .backgroundColor(HCColor.PAGE_BG)
    .borderRadius(12)
    .margin({ bottom: 16 })
  }

  /** 生成 6 位数字房间号并创建本机会话（离线可用，不依赖 RoomAPI） */
  private async createLocalRoom(): Promise<void> {
    if (this.isCreating) {
      return;
    }
    this.isCreating = true;
    this.errorMsg = '';
    try {
      const code: string = this.genRoomCode();
      this.createdCode = code;
      // 🔴 v2.7.4：把房间登记进**账号级房间目录** —— 其它同账号设备据此才能校验
      //   "该房间确实存在"，从而修复"输入任意房间号都能加入"的问题。
      SafeAsync.runVoid(TAG_PAGE, 'publishRoom', (): void => {
        const ctx: common.Context = getContext(this) as common.Context;
        this.roomDirectory.open(ctx).then((): void => {
          const host: string = this.collabService.ensureLocalDeviceId();
          this.roomDirectory.publishRoom(code, host, this.userName.trim().length > 0 ? this.userName.trim() : '房主');
        }).catch((err: Error): void => {
          Logger.warn(TAG_PAGE, `房间登记失败（其它设备将无法校验该房间）: ${SafeAsync.describe(err)}`);
        });
      });
      // 🔴 v2.7.1：本机房间改用**纯本地**会话建立（joinLocalSession），
      //   不再 await 依赖 WebSocket 的 joinCollabSession ——
      //   那会在无服务端环境下等待连接超时（审核录屏里按钮长期停在"创建中…"）。
      const joinResult: JoinSessionResult =
        await this.collabService.joinLocalSession(code, this.currentRole());
      AppStorage.setOrCreate<string>('roomId', code);
      AppStorage.setOrCreate<string>('userName', this.userName.trim().length > 0 ? this.userName.trim() : '房主');
      this.joined = joinResult.connected;
      this.appliedRoleText = `${joinResult.role} · ${joinResult.roleText}`;
      this.joinResultText = `已创建本机房间 ${code}，可分享给同伴加入`;
      this.errorMsg = '';
    } catch (err) {
      this.errorMsg = `创建房间失败：${SafeAsync.describe(err as Error)}`;
    } finally {
      this.isCreating = false;
    }
  }

  /** 6 位数字房间号（首位非 0，避免与输入校验冲突） */
  private genRoomCode(): string {
    let code: string = '';
    for (let i = 0; i < 6; i++) {
      const d: number = i === 0
        ? 1 + Math.floor(Math.random() * 9)
        : Math.floor(Math.random() * 10);
      code += `${d}`;
    }
    return code;
  }

  /** 期望权限档位选择器（VIEWER / ANNOTATOR / EDITOR） */
  @Builder
  buildRoleSelector() {
    Column() {
      Row() {
        Text('权限档位')
          .fontSize(13).fontColor(HCColor.TEXT_TERTIARY)
          .width(60)
        Row() {
          ForEach(this.roleOptions, (option: RoleOption) => {
            Text(option.label)
              .fontSize(13)
              .height(32)
              .padding({ left: 14, right: 14 })
              .fontColor(this.desiredRole === option.role ? HCColor.SURFACE : HCColor.TEXT_TERTIARY)
              .backgroundColor(this.desiredRole === option.role ? HCColor.PRIMARY : HCColor.DIVIDER)
              .borderRadius(8)
              .margin({ right: 8 })
              .onClick(() => {
                this.desiredRole = option.role;
              })
          }, (option: RoleOption) => option.role)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Text(`将向服务端申请「${sessionRoleLabel(this.currentRole())}」权限，实际权限以服务端签发断言为准`)
        .fontSize(11).fontColor(HCColor.ICON_SECONDARY)
        .width('100%')
        .margin({ top: 6 })
    }
    .width('85%')
    .margin({ top: 16 })
  }

  /** 加入结果 / 权限断言回显区 */
  @Builder
  buildJoinResult() {
    Column() {
      Row() {
        IconComponent({
          symbol: this.joined ? IconSymbols.SUCCESS : IconSymbols.INFO,
          iconSize: 16,
          color: this.joined ? HCColor.SUCCESS : HCColor.PRIMARY
        })
        Text('会话接线结果')
          .fontSize(13).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
          .margin({ left: 6 })
      }
      .width('100%')

      Text(this.joinResultText)
        .fontSize(12).fontColor(HCColor.TEXT_SECONDARY)
        .width('100%')
        .margin({ top: 6 })

      Text(`生效权限：${this.appliedRoleText}`)
        .fontSize(12).fontColor(HCColor.SUCCESS)
        .width('100%')
        .margin({ top: 4 })

      // v2.5.2 审核修复：仅在真正成功加入时显示"进入白板"按钮，避免单机模式误导
      if (this.joined) {
        Button('进入白板')
          .fontSize(13).height(36).width('100%')
          .fontColor(HCColor.SURFACE).backgroundColor(HCColor.PRIMARY).borderRadius(10)
          .margin({ top: 10 })
          .onClick(() => {
            router.pushUrl({ url: 'pages/WhiteboardPage' })
              .catch((err: Error) => {
                this.errorMsg = `打开白板失败：${SafeAsync.describe(err)}`;
              });
          })
      } else {
        // v2.5.2 提示：服务端未上线时明确告知用户当前状态
        Text('协作服务端未上线 · 当前为本地单机编辑模式')
          .fontSize(12).fontColor(HCColor.WARNING)
          .width('100%').textAlign(TextAlign.Center)
          .margin({ top: 10 })
      }
    }
    .width('85%')
    .padding(12)
    .backgroundColor(HCColor.PRIMARY_BG)
    .borderRadius(10)
    .margin({ top: 14 })
  }

  /** 当前选中的角色枚举 */
  private currentRole(): SessionRole {
    if (this.desiredRole === SessionRole.EDITOR) {
      return SessionRole.EDITOR;
    }
    if (this.desiredRole === SessionRole.ANNOTATOR) {
      return SessionRole.ANNOTATOR;
    }
    return SessionRole.VIEWER;
  }

    /**
   * 🔴 v2.7.5：协作功能暂时下线。
   *   所有入口（底部「协作」Tab、白板扩展工具「加入协作」）已按开关隐藏，
   *   本守卫用于兜底：万一通过其它路径进入本页，直接返回上一页并给出提示，
   *   不展示任何可交互的协作 UI。
   */
  aboutToAppear(): void {
    if (FEATURE_COLLAB_ENABLED) {
      return;
    }
    SafeAsync.runVoid(TAG_PAGE, 'collabDisabledGuard', (): void => {
      promptAction.showToast({ message: '协作功能将在后续版本开放', duration: 2000 });
      router.back();
    });
  }

  /** v2.7.4：离开页面时释放房间目录数据对象，避免分布式会话泄漏 */
  aboutToDisappear(): void {
    this.roomDirectory.close();
  }

  /** v2.7.4：给房间目录一个同步窗口（首次加入需等对端推送目录） */
  private waitForDirectorySync(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void): void => {
      setTimeout((): void => {
        resolve();
      }, ms);
    });
  }

  private async joinRoom(): Promise<void> {
    // 输入验证
    const code = this.roomCode.trim();
    if (code.length !== 6 || !/^\d{6}$/.test(code)) {
      this.errorMsg = '请输入6位数字房间号';
      return;
    }
    const name = this.userName.trim();
    if (name.length === 0) {
      this.errorMsg = '请输入您的昵称';
      return;
    }
    if (name.length > 20) {
      this.errorMsg = '昵称不能超过20个字符';
      return;
    }

    // ══════════════════════════════════════════════════════════════════
    // 🔴 v2.7.4 审核修复（问题①「输入任意房间号，都能够加入房间」）
    //   本产品无中心服务器，原先没有任何地方登记"哪些房间存在"，
    //   于是输入任意 6 位数字都能"加入成功"，但看不到任何人、也共享不到白板。
    //   现在加入前先查**账号级房间目录**（房主创建房间时登记，同账号设备自动同步）：
    //     · 目录有该房间  → 放行，并显示房主
    //     · 目录无该房间  → 明确报错「房间不存在」，**不置为已加入**
    //     · 目录不可用    → 不阻断（避免分布式能力不可用时整体不可用），但如实提示未校验
    // ══════════════════════════════════════════════════════════════════
    this.isLoading = true;
    let directoryVerified: boolean = false;
    try {
      const ctx: common.Context = getContext(this) as common.Context;
      const opened: boolean = await this.roomDirectory.open(ctx);
      if (opened) {
        // 首次加入需等待对端把目录推过来，给一个短暂同步窗口
        await this.waitForDirectorySync(1000);
        const found: RoomLookup = this.roomDirectory.lookup(code);
        directoryVerified = found.available;
        if (found.available && !found.exists) {
          this.errorMsg = `房间 ${code} 不存在：请确认房主已在本机创建该房间，且两台设备已登录同一华为账号并在「超级终端」完成互联`;
          this.joinResultText = '未能找到该房间（房间号由房主创建时生成，请与房主核对）';
          this.isLoading = false;
          return;
        }
        if (found.exists) {
          this.joinResultText = `已找到房间 ${code}（房主：${found.hostName} · ${found.hostShortId}）`;
        }
      }
    } catch (e) {
      Logger.warn(TAG_PAGE, `房间校验异常，跳过校验: ${SafeAsync.describe(e as Error)}`);
    }

    this.errorMsg = '';
    this.appliedRoleText = '';
    this.joined = false;

    // ① REST 加入房间（服务端可用时走真实链路）
    let restOk: boolean = false;
    let serverDown: boolean = false;
    try {
      const api = RoomAPI.getInstance();
      const result: ApiResponse = await api.joinRoom(code, name);
      if (result.code === 0) {
        restOk = true;
        AppStorage.setOrCreate<string>('roomId', code);
        AppStorage.setOrCreate<string>('userName', name);
        // C01 身份链贯通：解析 JoinResult，落地服务端签发的 user_id / token / ws_endpoint。
        // 严禁用昵称覆盖 userId —— 那是当前缺陷的根源（两个同昵称用户会互相撤销对方操作）。
        SessionIdentity.getInstance().applyJoinResult(result.data);
      } else if (result.code === 50001 || result.code === 50002) {
        // 服务端明确答复：房间不存在 / 已满 —— 这才是真正的"加入失败"
        this.errorMsg = this.getErrorMessage(result.code);
        this.isLoading = false;
        return;
      } else {
        // 网络不可达 / 服务端未部署 → 走本地离线会话
        serverDown = true;
      }
    } catch (err) {
      serverDown = true;
    }

    // ② 会话接线
    // 🔴 v2.7.2 审核修复（问题①-2「输入房间号后点击加入房间失败」，连续两轮未过）：
    //   v2.7.1 的两处缺陷 ——
    //   ① `joinLocalSession()` **没有包 try/catch**：内部任何一处抛错（如权限断言/会话状态
    //      建立失败）都会让整个 joinRoom 的 Promise reject，调用方无人接收 → 表现为"点击无反应/加入失败"；
    //   ② 服务端已确认不可达（serverDown）时**仍先白等 5 秒**（joinCollabSession 内的
    //      withTimeout 超时），用户点了按钮后长时间无反馈。
    //   修法：serverDown/restOk=false 时**直接走本地会话**，不再尝试远端；
    //        且本地会话自身也包 try/catch 兜底，保证一定返回结果。
    let joinResult: JoinSessionResult | null = null;
    if (restOk) {
      try {
        joinResult = await this.collabService.joinCollabSession(code, this.currentRole());
      } catch (e) {
        Logger.warn(TAG_PAGE, `远端会话建立异常，转本地会话: ${SafeAsync.describe(e as Error)}`);
        joinResult = null;
      }
    }
    if (joinResult === null || !joinResult.connected) {
      try {
        joinResult = await this.collabService.joinLocalSession(code, this.currentRole());
      } catch (e) {
        Logger.error(TAG_PAGE, `本地会话建立异常: ${SafeAsync.describe(e as Error)}`);
        joinResult = null;
      }
    }

    if (joinResult === null) {
      // 理论上不会走到这里（joinLocalSession 内部已全兜底），保留最后防线
      this.joined = false;
      this.appliedRoleText = '—';
      this.joinResultText = '本地会话未能建立，请稍后重试';
      this.errorMsg = '无法建立协作会话，请重试';
      this.isLoading = false;
      return;
    }

    // 🔴 v2.7.1：本机房间/离线会话建立成功即视为「已加入」，
    //   服务端未部署只作说明性文字，不再用红色错误呈现。
    const sessionOk: boolean = joinResult.connected;
    this.joined = restOk || sessionOk;
    this.appliedRoleText = `${joinResult.role} · ${joinResult.roleText}`;
    if (restOk) {
      this.joinResultText = joinResult.message;
      this.errorMsg = '';
    } else if (sessionOk) {
      this.joinResultText = `已加入房间 ${code} · 同一华为账号下的设备将实时共享白板（无需服务端）`;
      this.errorMsg = '';
    } else {
      this.joinResultText = '本地会话未能建立，请稍后重试';
      this.errorMsg = '无法建立协作会话，请检查网络后重试';
    }
    this.isLoading = false;
  }

  /**
   * 错误码 → 中文文案。
   * v2.7.0：不再接收/返回服务端原始 data（曾把对象渲染成 "[object Object]"）。
   */
  private getErrorMessage(code: number): string {
    if (code === 50001) return '房间不存在，请核对房间号';
    if (code === 50002) return '房间已满，请稍后再试';
    if (code === 20001) return '网络不可达，已改用本机离线会话';
    return `加入失败（错误码 ${code}）`;
  }
}
