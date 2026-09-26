/**
 * PrivacyPage.ets — 隐私政策页（v1.1）
 *
 * 优化：
 *  - 使用统一 BackButton 组件
 *  - 增加页面转场动画
 *  - 段落间增加分割线，提升可读性
 */

import { router } from '@kit.ArkUI';
import { HCColor } from '../common/theme/DesignTokens';
import { BackButton } from '../common/components/BackButton';

@Entry
@Component
struct PrivacyPage {
  build() {
    Column() {
      BackButton({ title: '隐私政策' })

      Scroll() {
        Column() {
          Text('鸿绘协作板隐私政策').fontSize(20).fontWeight(FontWeight.Bold).margin({ top: 20, bottom: 8 })

          Text('更新日期：2026年8月6日').fontSize(12).fontColor(HCColor.ICON_SECONDARY).margin({ bottom: 20 })

          this.buildSection('一、我们收集的信息',
            '1.1 设备信息：为优化显示效果，我们会获取设备型号、屏幕尺寸等基本信息，用于自适应布局。\n1.2 网络信息：为检测网络状态以提供离线提示，我们需要访问网络连接状态。\n1.3 白板数据：您创建的白板内容仅存储在本地设备，不会上传到云端服务器。')

          this.buildDivider();

          this.buildSection('二、信息使用目的',
            '2.1 提供白板协作核心功能\n2.2 优化协作体验和同步性能\n2.3 维护服务稳定性和安全性\n2.4 收集匿名使用数据用于产品优化')

          this.buildDivider();

          this.buildSection('三、数据存储与安全',
            '3.1 数据传输使用 TLS 1.3 加密\n3.2 白板数据仅存储于本地设备，采用原子写入和四级回退机制确保数据安全\n3.3 我们采用行业标准的安全措施保护您的数据\n3.4 数据保存期限：您删除应用后，所有数据将自动清除')

          this.buildDivider();

          this.buildSection('四、用户权利',
            '4.1 您有权随时查看、导出您的白板数据\n4.2 您可以随时删除个人数据\n4.3 您可以随时撤回授权\n4.4 所有数据仅存储在本地，删除应用即彻底清除')

          this.buildDivider();

          this.buildSection('五、第三方SDK',
            '我们使用以下系统服务：\n• @kit.ArkUI - UI组件渲染\n• @kit.AbilityKit - 应用能力管理\n• @kit.BasicServicesKit - 基础服务\n• @ohos.file.fs - 文件系统访问\n• @ohos.multimedia.image - 图像处理\n• @ohos.net.http - 网络通信（TLS 1.3加密）\n• @ohos.data.preferences - 本地数据存储\n\n所有系统服务均符合平台隐私规范，仅在用户授权后使用。')

          this.buildDivider();

          this.buildSection('六、功能说明',
            '6.1 导出功能：当前版本支持将白板内容导出为PNG图片、SVG矢量图及PDF文档。')

          this.buildDivider();

          this.buildSection('七、联系我们',
            '如有隐私相关问题，请联系：\n邮箱：privacy@harmonycanvas.dev\n我们将在15个工作日内回复您的请求。')

          Blank().height(40)
        }
        .width('90%')
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      // v2.5.2 审核修复：滑动到边界需有反馈动效
      .edgeEffect(EdgeEffect.Spring)
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

  @Builder
  buildSection(title: string, content: string) {
    Column() {
      Text(title)
        .fontSize(16).fontWeight(FontWeight.Medium).margin({ top: 12, bottom: 6 })
      Text(content)
        .fontSize(13).lineHeight(22).fontColor(HCColor.TEXT_SECONDARY)
    }
  }

  @Builder
  buildDivider() {
    Divider()
      .height(1)
      .color(HCColor.DIVIDER)
      .margin({ top: 8, bottom: 4 })
  }
}
