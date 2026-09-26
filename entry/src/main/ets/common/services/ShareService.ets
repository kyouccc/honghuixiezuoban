/**
 * ShareService.ets — 系统分享能力（P1 增强 / v2.7.0 真实实现）
 *
 * ══════════════════════════════════════════════════════════════════════
 * v2.7.0 审核修复（问题③-4「扩展工具-导出-分享，提示导出准备中，没有导出成功」）
 *
 * 真因：本文件此前是**空壳** —— 5 个方法全部只写一行日志就返回，
 *   既没有调用系统分享，也没有落盘。页面侧的「导出 PDF / 导出图片」
 *   更是只 `setStatus('…导出准备中')` 便结束，从未调用真实的导出实现。
 *   于是无论点哪一项，用户都只看到"准备中"，永远不会有结果。
 *
 * 修法：
 *   ① 使用 HarmonyOS 系统分享（ShareKit）真实拉起分享面板；
 *   ② 分享失败时明确返回 false，由调用方回退到"系统文件选择器另存"，
 *      保证任何情况下用户都能拿到导出文件。
 * ══════════════════════════════════════════════════════════════════════
 */

import { common } from '@kit.AbilityKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import { fileUri } from '@kit.CoreFileKit';
import { Logger } from '../Logger';

const TAG = 'ShareService';

export class ShareService {
  private static instance: ShareService;

  static getInstance(): ShareService {
    if (!ShareService.instance) {
      ShareService.instance = new ShareService();
    }
    return ShareService.instance;
  }

  /**
   * 分享本地文件（图片 / PDF）。
   * @returns true=分享面板已被系统接管；false=分享不可用（调用方应回退到另存）
   */
  async shareFile(filePath: string, isImage: boolean, title: string, context: common.UIAbilityContext): Promise<boolean> {
    if (filePath === undefined || filePath === null || filePath.length === 0) {
      Logger.warn(TAG, 'shareFile: 文件路径为空');
      return false;
    }
    try {
      const uri: string = fileUri.getUriFromPath(filePath);
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: isImage ? utd.UniformDataType.IMAGE : utd.UniformDataType.PDF,
        uri: uri,
        title: title,
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      // 注：本 SDK 版本的 ShareController.show() 返回 Promise<void>，
      //   不提供 resultCode；只要未抛异常即视为分享面板已成功拉起。
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      });
      Logger.info(TAG, 'shareFile 完成：系统分享面板已拉起');
      return true;
    } catch (err) {
      Logger.error(TAG, `shareFile 失败: ${JSON.stringify(err)}`);
      return false;
    }
  }

  /** 分享图片文件 */
  async shareImage(filePath: string, context: common.UIAbilityContext): Promise<boolean> {
    return this.shareFile(filePath, true, '鸿绘协作板 · 画布', context);
  }

  /** 分享 PDF 文件 */
  async sharePdf(filePath: string, context: common.UIAbilityContext): Promise<boolean> {
    return this.shareFile(filePath, false, '鸿绘协作板 · 笔记', context);
  }

  /** 分享文本内容（走系统分享的纯文本类型） */
  async shareText(text: string, title: string, context: common.UIAbilityContext): Promise<boolean> {
    if (text === undefined || text === null || text.length === 0) {
      return false;
    }
    try {
      const shareData: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content: text,
        title: title,
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(shareData);
      await controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE,
        previewMode: systemShare.SharePreviewMode.DETAIL,
      });
      return true;
    } catch (err) {
      Logger.error(TAG, `shareText 失败: ${JSON.stringify(err)}`);
      return false;
    }
  }
}
