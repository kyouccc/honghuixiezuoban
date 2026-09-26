/**
 * 帮助提示服务
 * 提供上下文相关的帮助提示和工具提示
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { analytics } from './AnalyticsService';

const TAG = 'HelpTooltip';
const DOMAIN = 0x0000;

export interface HelpTip {
  id: string;
  title: string;
  content: string;
  icon?: string;
  action?: string; // 可选的操作按钮文本
}

const HELP_TIPS: Record<string, HelpTip> = {
  'pen_tool': {
    id: 'pen_tool',
    title: '画笔工具',
    content: '自由绘制笔触，支持压感和平滑处理',
    icon: 'edit'
  },
  'eraser_tool': {
    id: 'eraser_tool',
    title: '橡皮擦',
    content: '擦除笔触，橡皮大小为当前线宽的 4 倍',
    icon: 'eraser'
  },
  'shape_tool': {
    id: 'shape_tool',
    title: '形状工具',
    content: '绘制矩形、圆形、箭头或直线',
    icon: 'shape'
  },
  'color_picker': {
    id: 'color_picker',
    title: '颜色选择',
    content: '选择 16 种预设颜色',
    icon: 'palette'
  },
  'width_picker': {
    id: 'width_picker',
    title: '线宽选择',
    content: '选择 7 种预设线宽（1-20px）',
    icon: 'size'
  },
  'undo': {
    id: 'undo',
    title: '撤销',
    content: '撤销上一步操作',
    icon: 'undo'
  },
  'redo': {
    id: 'redo',
    title: '重做',
    content: '重做已撤销的操作',
    icon: 'redo'
  },
  'export': {
    id: 'export',
    title: '导出',
    content: '将白板内容导出为 PNG 图片',
    icon: 'export'
  },
  'clear': {
    id: 'clear',
    title: '清空画布',
    content: '清除所有笔触，此操作不可撤销',
    icon: 'delete'
  },
  'sketch_to_vector': {
    id: 'sketch_to_vector',
    title: '草图转矢量',
    content: '将手绘草图转换为规则形状',
    icon: 'paintbucket'
  },
  'layer': {
    id: 'layer',
    title: '图层管理',
    content: '管理多个图层，支持显示/隐藏、排序',
    icon: 'layers'
  },
  'collaboration': {
    id: 'collaboration',
    title: '多人协作',
    content: '邀请他人加入房间，实时协同绘制',
    icon: 'group'
  },
  'nfc_join': {
    id: 'nfc_join',
    title: '碰一碰加入',
    content: '手机碰一碰 NFC 标签即可快速加入房间',
    icon: 'phone'
  },
  'feedback': {
    id: 'feedback',
    title: '反馈与建议',
    content: '遇到问题或有建议？告诉我们',
    icon: 'feedback'
  }
};

export class HelpService {
  private static instance: HelpService;
  private shownTips: Set<string> = new Set();

  private constructor() {}

  static getInstance(): HelpService {
    if (!HelpService.instance) {
      HelpService.instance = new HelpService();
    }
    return HelpService.instance;
  }

  /**
   * 获取帮助提示
   */
  getHelpTip(tipId: string): HelpTip | null {
    return HELP_TIPS[tipId] || null;
  }

  /**
   * 显示工具提示
   */
  showTooltip(tipId: string): void {
    const tip = this.getHelpTip(tipId);
    if (!tip) return;
    
    const message = tip.title;
    
    promptAction.showToast({
      message: message,
      duration: 2000
    });
    
    // 记录埋点
    if (!this.shownTips.has(tipId)) {
      analytics.track('help_tooltip_shown', { tip_id: tipId });
      this.shownTips.add(tipId);
    }
  }

  /**
   * 显示详细帮助
   */
  showDetailedHelp(tipId: string): void {
    const tip = this.getHelpTip(tipId);
    if (!tip) return;
    
    // TODO: 显示帮助对话框
    hilog.info(DOMAIN, TAG, `Showing detailed help: ${tipId}`);
    
    analytics.track('help_detail_shown', { tip_id: tipId });
  }

  /**
   * 获取所有帮助提示
   */
  getAllHelpTips(): HelpTip[] {
    return Object.values(HELP_TIPS);
  }

  /**
   * 搜索帮助提示
   */
  searchHelpTips(query: string): HelpTip[] {
    const lowerQuery = query.toLowerCase();
    
    return Object.values(HELP_TIPS).filter(tip => 
      tip.title.toLowerCase().includes(lowerQuery) ||
      tip.content.toLowerCase().includes(lowerQuery)
    );
  }
}

// 导出单例
export const helpService = HelpService.getInstance();
