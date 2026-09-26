/**
 * DesignTokens.ets — 鸿绘 设计令牌（T01 / v4.1 暗色模式修复版）
 *
 * 层级：Primitive（原始十六进制字符串，Canvas/string 场景可用）
 *       → Semantic（HCColor 语义别名，Resource 类型，系统自动暗色切换）
 *       → Component（HCMetric，尺寸/字号/间距，仍为 number）。
 *
 * 暗色模式接线（2026-08-21 P0 修复）：
 *  - HCColor 所有字段从 string hex 改为 $r('app.color.hc_xxx') Resource 引用；
 *  - ArkUI 在系统深色模式下自动将 base/ 资源替换为 dark/ 同名资源；
 *  - 全代码 600+ 处 HCColor.* 调用点零改动，自动获得深色值；
 *  - 如需 Canvas 绘图的十六进制字符串，直接用 HCPrimary / HCGray / HCSemantic 原语类。
 *
 * ArkTS 严格模式：class + static readonly 显式类型。
 */

// ═══════════════════ Primitive · 品牌主色（HarmonyOS 蓝体系 #007DFF）═══════════════════
export class HCPrimary {
  static readonly BLUE: string        = '#007DFF';  // 标准主蓝（全项目唯一基准）
  static readonly PRESSED: string     = '#0060D1';  // 按下态（深一档）
  static readonly DISABLED: string    = '#99C7FF';  // 禁用态（浅蓝）
  static readonly BG: string          = '#E8F4FD';  // 主色浅背景（胶囊/标签）
  static readonly BORDER: string      = '#B3D9FF';  // 主色描边
}

// ═══════════════════ Primitive · 9 级中性灰（GRAY_1 最浅 → GRAY_9 最深）═══════════════════
// v2.5.2 审核可达性修复：GRAY_5/6/7 用于占位文字/次要图标/三级文字，
//   原值对 #F7F8FA 背景对比度不足（1.6~4.5:1），加深至 ≥3:1（图标）/~4.6:1（三级文字）。
export class HCGray {
  static readonly GRAY_1: string = '#FFFFFF';  // 表面/卡片
  static readonly GRAY_2: string = '#F7F8FA';  // 页面背景（统一收敛值）
  static readonly GRAY_3: string = '#EEF1F5';  // 分割线/浅填充
  static readonly GRAY_4: string = '#E0E3E8';  // 描边
  static readonly GRAY_5: string = '#7A828C';  // 禁用文字/占位（原 #C4C8CE 对比 1.6:1 不达标）
  static readonly GRAY_6: string = '#5F6368';  // 次要图标（原 #9AA0A6 对比 2.5:1 不达标）
  static readonly GRAY_7: string = '#5B626D';  // 三级文字（原 #6B7280 贴线 4.55:1，加深留余量）
  static readonly GRAY_8: string = '#3C4043';  // 二级文字
  static readonly GRAY_9: string = '#1A1A1A';  // 一级文字
}

// ═══════════════════ Primitive · 语义色（成功/警告/危险/信息）═══════════════════
// v2.5.2 审核可达性修复：SUCCESS/WARNING/INFO 作为文字使用时原值 <4.5:1，加深达标。
export class HCSemantic {
  static readonly SUCCESS: string    = '#1E7E3C';   // 原 #2E9E4F（3.4:1）
  static readonly SUCCESS_BG: string = '#E7F6EC';
  static readonly WARNING: string    = '#8A5A08';   // 原 #B0740A（4.49:1 贴线）
  static readonly WARNING_BG: string = '#FFF6E5';
  static readonly DANGER: string     = '#C0392B';
  static readonly DANGER_BG: string  = '#FDEDEC';
  static readonly INFO: string       = '#0063CC';   // 原 #007DFF 作正文时 3.9:1
  static readonly INFO_BG: string    = '#E8F4FD';
}

// ═══════════════════ Semantic · 语义颜色别名（Resource 类型，自动暗色切换）═══════════════════
export class HCColor {
  // 主色
  static readonly PRIMARY: Resource         = $r('app.color.hc_primary');
  static readonly PRIMARY_PRESSED: Resource = $r('app.color.hc_primary_pressed');
  static readonly PRIMARY_DISABLED: Resource= $r('app.color.hc_primary_disabled');
  static readonly PRIMARY_BG: Resource      = $r('app.color.hc_primary_bg');
  static readonly PRIMARY_BORDER: Resource  = $r('app.color.hc_primary_border');

  // 表面 & 背景
  static readonly SURFACE: Resource         = $r('app.color.hc_surface');
  static readonly SURFACE_ELEVATED: Resource= $r('app.color.hc_surface');
  static readonly PAGE_BG: Resource         = $r('app.color.hc_page_bg');

  // 分割线 & 描边
  static readonly DIVIDER: Resource         = $r('app.color.hc_divider');
  static readonly BORDER: Resource          = $r('app.color.hc_border');

  // 文字
  static readonly TEXT_DISABLED: Resource   = $r('app.color.hc_text_disabled');
  static readonly ICON_SECONDARY: Resource  = $r('app.color.hc_icon_secondary');
  static readonly TEXT_TERTIARY: Resource   = $r('app.color.hc_text_tertiary');
  static readonly TEXT_SECONDARY: Resource  = $r('app.color.hc_text_secondary');
  static readonly TEXT_PRIMARY: Resource    = $r('app.color.hc_text_primary');

  // 语义色
  static readonly SUCCESS: Resource    = $r('app.color.hc_success');
  static readonly SUCCESS_BG: Resource = $r('app.color.hc_success_bg');
  static readonly WARNING: Resource    = $r('app.color.hc_warning');
  static readonly WARNING_BG: Resource = $r('app.color.hc_warning_bg');
  static readonly DANGER: Resource     = $r('app.color.hc_danger');
  static readonly DANGER_BG: Resource  = $r('app.color.hc_danger_bg');
  static readonly INFO: Resource       = $r('app.color.hc_info');
  static readonly INFO_BG: Resource    = $r('app.color.hc_info_bg');

  // 蒙层 & 透明
  static readonly MASK: Resource       = $r('app.color.hc_mask');
  static readonly TRANSPARENT: Resource= $r('app.color.hc_transparent');

  // 画布 & 折痕
  static readonly CANVAS_BG: Resource  = $r('app.color.hc_canvas_bg');
  static readonly CREASE_BG: Resource  = $r('app.color.hc_crease_bg');
}

// ═══════════════════ Component · 组件级度量（尺寸 / 圆角 / 间距 / 字号）═══════════════════

/**
 * HCRadius — 圆角令牌（全局统一）
 */
export class HCRadius {
  static readonly NONE: number   = 0;
  static readonly XS: number     = 4;
  static readonly SM: number     = 6;
  static readonly MD: number     = 8;
  static readonly LG: number     = 12;
  static readonly XL: number     = 16;
  static readonly XXL: number    = 20;
  static readonly PILL: number   = 32;
  static readonly CIRCLE: number = 999;  // 100% 圆角
}

/**
 * HCSpace — 间距令牌（4px 栅格）
 */
export class HCSpace {
  static readonly XS: number  = 4;
  static readonly SM: number  = 8;
  static readonly MD: number  = 12;
  static readonly LG: number  = 16;
  static readonly XL: number  = 24;
  static readonly XXL: number = 32;
}

/**
 * HCFont — 字号令牌
 */
export class HCFont {
  static readonly TINY: number   = 10;
  static readonly CAPTION: number= 11;
  static readonly BODY_SM: number= 12;
  static readonly BODY: number   = 14;
  static readonly BODY_LG: number= 15;
  static readonly SUBHEAD: number= 16;
  static readonly TITLE: number  = 18;
  static readonly TITLE_LG: number= 20;
  static readonly HEADING: number= 24;
  static readonly DISPLAY: number= 32;
}

/**
 * HCMetric — 综合度量（优先级高于单独 HCSpace/HCRadius/HCFont，避免逐层 import）
 */
export class HCMetric {
  // 组件高度
  static readonly TAB_BAR_HEIGHT: number  = 64;
  static readonly TOOLBAR_HEIGHT: number  = 48;
  static readonly INPUT_HEIGHT: number    = 40;
  static readonly BOTTOM_SHEET_H: number  = 320;

  // 组件宽度
  static readonly SIDEBAR_WIDTH: number   = 260;

  // 图标尺寸
  static readonly ICON_TAB: number    = 22;
  static readonly ICON_SM: number     = 16;
  static readonly ICON_MD: number     = 20;
  static readonly ICON_LG: number     = 24;
  static readonly ICON_XL: number     = 32;
}

/**
 * HCElevation — 阴影 / 层级令牌
 */
export class HCElevation {
  static readonly NONE: number    = 0;
  static readonly LOW: number     = 2;
  static readonly MID: number     = 4;
  static readonly HIGH: number    = 8;
  static readonly MODAL: number   = 12;
}

// ═══════════════════ Primitive · 品牌/分类强调色（UI 装饰 · 图层类型 · 工具类型，字符串原语）═══════════════════
/**
 * HCBrand — 承载原散落在组件中的「分类强调色」（图层类型标签、图片工具图标、状态点）。
 * 作为 string 原语，与 HCPrimary/HCGray/HCSemantic 同级；仅用于 ArkUI 样式或 string 字段。
 * 值完全保留旧硬编码值，P0-3 合规且零观感变化。
 */
export class HCBrand {
  static readonly BLUE: string        = '#2196F3';
  static readonly INDIGO: string      = '#3F51B5';
  static readonly PURPLE: string      = '#9C27B0';
  static readonly PURPLE_SOFT: string = '#7C4DFF';
  static readonly GREEN: string       = '#4CAF50';
  static readonly GREEN_TINT: string  = '#E8F5E9';
  static readonly ORANGE: string      = '#FF9800';
  static readonly RED: string         = '#F44336';
  static readonly RED_PURE: string    = '#FF0000';
  static readonly RED_DEEP: string    = '#E53935';
  static readonly RED_TINT: string    = '#E5A8A2';
  static readonly BLUE_DEEP: string   = '#0288D1';
  static readonly BLUE_TINT: string   = '#E1F5FE';
  static readonly PURPLE_TINT: string = '#F3E8FF';
  static readonly AMBER_TINT: string  = '#FFE082';
  static readonly BTN_BLUE: string    = '#4A90E2';
  // 闪卡复习评分三色（v2.5.2 审核可达性修复：原浅色文字在浅底上对比 <3:1，加深达标）
  static readonly RED_SOFT: string    = '#C92A2A';   // 原 #FF6B6B（2.6:1）
  static readonly RED_SOFT_BG: string = '#1AFF6B6B';
  static readonly AMBER: string       = '#9A5200';   // 原 #FFA94D（1.9:1）
  static readonly AMBER_BG: string    = '#1AFFA94D';
  static readonly GREEN_SOFT: string  = '#237A32';   // 原 #51CF66（1.9:1）
  static readonly GREEN_SOFT_BG: string = '#1A51CF66';
}

// ═══════════════════ Primitive · 语义强调色（书签菜单 · 选中态 · 按钮文字，字符串原语）═══════════════════
export class HCAccent {
  static readonly BTN_ON_PRIMARY: string = '#DCEBFF';  // 主色按钮上的文字
  static readonly TEXT_STRONG: string    = '#1F2329';  // 强文本（近 GRAY_9）
}

// ═══════════════════ Primitive · 中性微调灰（与令牌近值但不完全相等，保留原观感）═══════════════════
export class HCNeutral {
  static readonly PAGE_TINT: string    = '#f5f5f5';
  static readonly DIVIDER_SOFT: string = '#e0e0e0';
  static readonly BORDER_SOFT: string  = '#E5E6EB';
  static readonly SURFACE_TINT: string = '#F7F8FA';
}

// ═══════════════════ Primitive · 透明遮罩 / 阴影（alpha 黑 / 白 / 品牌，字符串原语）═══════════════════
export class HCOverlay {
  static readonly SHADE_04: string  = '#0A000000';
  static readonly SHADE_05: string  = '#0D000000';
  static readonly SHADE_08: string  = '#15000000';
  static readonly SHADE_10: string  = '#18000000';
  static readonly SHADE_13: string  = '#22000000';
  static readonly SHADE_20: string  = '#33000000';
  static readonly MASK_40: string   = '#66000000';
  static readonly MASK_80: string   = '#CC000000';
  static readonly WHITE_80: string  = '#CCFFFFFF';
  static readonly WHITE_93: string  = '#EEFFFFFF';
  static readonly SHADE_BLUE: string = '#335BA8E5';
}
