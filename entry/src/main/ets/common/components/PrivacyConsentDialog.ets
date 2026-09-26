/**
 * PrivacyConsentDialog.ets — 隐私政策同意弹窗（华为应用市场合规版 v2.4）
 *
 * 合规要求（华为应用市场审核规范 A2）：
 *  1. 仅在首次启动时弹出一次（不得重复弹出）
 *  2. 必须为逐条式机制：用户可查看完整隐私政策全文
 *  3. 用户点击"不同意"必须退出应用
 *  4. 不得与其他弹窗同时出现（本应用唯一的隐私弹窗）
 *  5. **v2.4 修订**：将完整《隐私政策》七章内容**直接内联**到本弹窗的滚动区内，
 *     删去"跳转 pages/PrivacyPage"的链接。
 *     修复审核驳回："应用出现两个隐私弹窗"（审核将本弹窗+跳转到的独立隐私页计为两个）；
 *     修复"删除空白的隐私声明页面"（避免反复打开独立页导致多次弹出通知）。
 *     同意前可读全文 = 在本弹窗内可读完，**不依赖任何页面跳转**。
 *
 * 使用方式：
 *  在页面中声明 CustomDialogController，aboutToAppear 时检查同意状态，
 *  未同意则 controller.open()，已同意则跳过。
 */
import { common } from '@kit.AbilityKit';
import { privacyConsentService } from '../services/PrivacyConsentService';
import { Logger } from '../Logger';
import { HCColor } from '../theme/DesignTokens';

@CustomDialog
export struct PrivacyConsentDialog {
  controller: CustomDialogController;
  onAccept: () => void = () => {};
  onDisagree: () => void = () => {};

  build() {
    Column() {
      // 标题
      Text('隐私政策与用户协议')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ top: 24, bottom: 12 })

      Text('更新日期：2026年8月6日')
        .fontSize(12)
        .fontColor(HCColor.TEXT_TERTIARY)
        .margin({ bottom: 8 })

      // 滚动内容区域 —— 直接呈现完整《隐私政策》七章全文
      //   v2.4 修复：不再 router.pushUrl 跳转到独立 PrivacyPage，
      //   彻底消除"弹窗 + 跳转页 = 两个隐私弹窗"的合规问题。
      Scroll() {
        Column() {
          // ── 逐条式信息收集说明（保留为最显眼的"采集清单"） ──
          this.buildInfoItem('设备信息', '用于适配不同设备屏幕尺寸，支持跨设备协同编辑');
          this.buildInfoItem('笔记内容', '仅存储在您的设备本地，用于提供白板笔记功能');
          this.buildInfoItem('使用数据', '用于改进产品体验和性能优化（需您授权）');
          this.buildInfoItem('网络权限', '用于云同步功能（可选功能，不使用则不会联网）');

          Divider().color('#EEEEEE').margin({ top: 12, bottom: 12 });

          // ── 完整《隐私政策》七章全文（同意前可在本弹窗内读完） ──
          this.buildSection('一、我们收集的信息',
            '1.1 设备信息：为优化显示效果，我们会获取设备型号、屏幕尺寸等基本信息，用于自适应布局。\n1.2 网络信息：为检测网络状态以提供离线提示，我们需要访问网络连接状态。\n1.3 白板数据：您创建的白板内容仅存储在本地设备，不会上传到云端服务器。');

          this.buildSection('二、信息使用目的',
            '2.1 提供白板协作核心功能\n2.2 优化协作体验和同步性能\n2.3 维护服务稳定性和安全性\n2.4 收集匿名使用数据用于产品优化');

          this.buildSection('三、数据存储与安全',
            '3.1 数据传输使用 TLS 1.3 加密\n3.2 白板数据仅存储于本地设备，采用原子写入和四级回退机制确保数据安全\n3.3 我们采用行业标准的安全措施保护您的数据\n3.4 数据保存期限：您删除应用后，所有数据将自动清除');

          this.buildSection('四、用户权利',
            '4.1 您有权随时查看、导出您的白板数据\n4.2 您可以随时删除个人数据\n4.3 您可以随时撤回授权\n4.4 所有数据仅存储在本地，删除应用即彻底清除');

          this.buildSection('五、第三方SDK',
            '我们使用以下系统服务：\n• @kit.ArkUI - UI组件渲染\n• @kit.AbilityKit - 应用能力管理\n• @kit.BasicServicesKit - 基础服务\n• @ohos.file.fs - 文件系统访问\n• @ohos.multimedia.image - 图像处理\n• @ohos.net.http - 网络通信（TLS 1.3加密）\n• @ohos.data.preferences - 本地数据存储\n\n所有系统服务均符合平台隐私规范，仅在用户授权后使用。');

          this.buildSection('六、功能说明',
            '6.1 导出功能：当前版本支持将白板内容导出为PNG图片、SVG矢量图及PDF文档。');

          this.buildSection('七、联系我们',
            '如有隐私相关问题，请联系：\n邮箱：privacy@harmonycanvas.dev\n我们将在15个工作日内回复您的请求。');

          Text('我们承诺：您的数据会被安全存储，不会泄露给第三方。您可以随时在设置中查看、导出或删除您的数据。')
            .fontSize(12)
            .fontColor(HCColor.TEXT_TERTIARY)
            .lineHeight(18)
            .width('100%')
            .margin({ top: 16 })
        }
        .padding({ left: 20, right: 20 })
        .alignItems(HorizontalAlign.Start)
      }
      .height('58%')
      .width('100%')
      .scrollBar(BarState.Auto)
      .edgeEffect(EdgeEffect.Spring)

      // 分隔线
      Divider().color('#EEEEEE')

      // 按钮组
      Row() {
        // 不同意按钮
        Button('不同意')
          .fontSize(16)
          .width('42%')
          .height(44)
          .backgroundColor(HCColor.SURFACE_ELEVATED)
          .fontColor(HCColor.TEXT_SECONDARY)
          .borderRadius(8)
          .onClick(() => {
            this.handleDisagree();
          })

        Blank().width('4%')

        // 同意并继续按钮
        Button('同意并继续')
          .fontSize(16)
          .width('42%')
          .height(44)
          .backgroundColor(HCColor.PRIMARY)
          .fontColor(HCColor.SURFACE)
          .borderRadius(8)
          .fontWeight(FontWeight.Medium)
          .onClick(async () => {
            await privacyConsentService.acceptConsent();
            this.controller.close();
            this.onAccept();
          })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 24, top: 16 })
    }
    .width('90%')
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(16)
  }

  /**
   * 构建单条信息收集项（逐条式展示）
   */
  @Builder buildInfoItem(title: string, desc: string) {
    Column() {
      Row() {
        Text('•')
          .fontSize(14)
          .fontColor(HCColor.PRIMARY)
          .fontWeight(FontWeight.Bold)
          .margin({ right: 8 })
        Text(title)
          .fontSize(14)
          .fontColor(HCColor.TEXT_PRIMARY)
          .fontWeight(FontWeight.Medium)
        Blank()
      }
      .width('100%')
      .margin({ bottom: 4 })

      Text(desc)
        .fontSize(13)
        .fontColor(HCColor.TEXT_SECONDARY)
        .lineHeight(18)
        .width('100%')
        .margin({ left: 16, bottom: 12 })
    }
    .width('100%')
  }

  /**
   * 构建完整政策章节
   */
  @Builder buildSection(title: string, content: string) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(HCColor.TEXT_PRIMARY)
        .margin({ top: 10, bottom: 6 })
      Text(content)
        .fontSize(13)
        .fontColor(HCColor.TEXT_TERTIARY)
        .lineHeight(20)
        .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 处理不同意 —— 必须退出应用（华为审核硬性要求）
   */
  private handleDisagree(): void {
    this.controller.close();
    if (this.onDisagree) {
      this.onDisagree();
    }
    // 延迟退出，让弹窗关闭动画完成
    setTimeout(() => {
      try {
        const ctx = getContext(this) as common.UIAbilityContext;
        ctx.terminateSelf();
      } catch (e) {
        Logger.error('PrivacyConsentDialog', 'Failed to terminate app: ' + JSON.stringify(e));
      }
    }, 300);
  }
}
