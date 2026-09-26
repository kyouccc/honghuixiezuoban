/**
 * 图标常量定义 - 使用HarmonyOS SymbolGlyph系统图标
 * 
 * 设计原则：
 * 1. 优先使用SymbolGlyph（系统图标，自动适配深色模式）
 * 2. 统一图标大小规范（24dp标准，20dp紧凑，16dp迷你）
 * 3. 语义化命名，提升代码可读性
 * 
 * @since 2026-08-08
 */

/**
 * SymbolGlyph图标名称映射
 * 对应HarmonyOS系统图标库
 */
export class IconSymbols {
  // 绘图工具
  static readonly PEN: string = 'edit';                    // 笔
  static readonly ERASER: string = 'eraser';               // 橡皮擦
  static readonly BRUSH: string = 'brush';                 // 笔刷
  static readonly SHAPE: string = 'shape';                 // 形状
  static readonly LINE: string = 'line';                   // 直线
  static readonly ARROW: string = 'arrowRight';            // 箭头
  static readonly PALETTE: string = 'palette';             // 调色板（新增）
  
  // 编辑操作
  static readonly UNDO: string = 'undo';                   // 撤销
  static readonly REDO: string = 'redo';                   // 重做
  static readonly CLEAR: string = 'delete';                // 清除
  static readonly COPY: string = 'copy';                   // 复制
  static readonly PASTE: string = 'paste';                 // 粘贴
  static readonly DELETE: string = 'delete';               // 删除
  
  // 内容类型
  static readonly IMAGE: string = 'image';                 // 图片
  static readonly TEXT: string = 'text';                   // 文本
  static readonly STICKER: string = 'emoji';               // 贴纸/表情
  static readonly LAYER: string = 'layers';                // 图层
  static readonly FOLDER: string = 'folder';               // 文件夹
  
  // 视图控制
  static readonly ZOOM_IN: string = 'zoomIn';              // 放大
  static readonly ZOOM_OUT: string = 'zoomOut';            // 缩小
  static readonly FIT: string = 'fitScreen';               // 适应屏幕
  static readonly FOCUS: string = 'fullscreen';            // 进入全屏书写
  static readonly FOCUS_EXIT: string = 'fullscreenExit';   // 退出全屏书写
  static readonly GRID: string = 'grid';                   // 网格
  static readonly RULER: string = 'ruler';                 // 尺子
  
  // 导航与操作
  static readonly SEARCH: string = 'search';               // 搜索
  static readonly LINK: string = 'link';                   // 双链（NOTE-02）
  static readonly BOOKMARK: string = 'bookmark';           // 书签（NOTE-03）
  static readonly SETTINGS: string = 'settings';           // 设置
  static readonly MENU: string = 'menu';                   // 菜单
  static readonly MORE: string = 'more';                   // 更多
  static readonly BACK: string = 'arrowLeft';              // 返回
  static readonly CLOSE: string = 'close';                 // 关闭
  
  // 文件操作
  static readonly SAVE: string = 'save';                   // 保存
  static readonly EXPORT: string = 'export';               // 导出
  static readonly IMPORT: string = 'import';               // 导入
  static readonly SHARE: string = 'share';                 // 分享
  
  // 协作功能
  static readonly COLLABORATE: string = 'group';           // 协作
  static readonly GROUP: string = 'group';                 // 群组（新增）
  static readonly DEVICE: string = 'device';               // 设备
  static readonly PHONE: string = 'phone';                 // 手机（新增）
  static readonly SYNC: string = 'sync';                   // 同步
  
  // 状态指示
  static readonly SUCCESS: string = 'checkCircle';         // 成功
  static readonly WARNING: string = 'warning';             // 警告
  static readonly ERROR: string = 'error';                 // 错误
  static readonly INFO: string = 'info';                   // 信息
  
  // 其他
  static readonly COLOR: string = 'colorPalette';          // 颜色
  static readonly SIZE: string = 'size';                   // 大小
  static readonly STYLE: string = 'style';                 // 样式
  static readonly HELP: string = 'help';                   // 帮助
  static readonly FEEDBACK: string = 'feedback';           // 反馈
  
  // 文档相关
  static readonly DOC_TEXT: string = 'document';           // 文档文本
  
  // 方向指示
  static readonly CHEVRON_UP: string = 'arrowUp';          // 向上箭头
  static readonly CHEVRON_DOWN: string = 'arrowDown';      // 向下箭头

  // v2.5 新增工具图标
  static readonly LASSO: string = 'lasso';                 // 套索选择
  static readonly EYEDROPPER: string = 'eyedropper';       // 取色器
  static readonly FILL: string = 'paintbucket';            // 填充
  static readonly REPLAY: string = 'play';                 // 回放
  static readonly TEMPLATE: string = 'squareStack3D';      // 模板
  static readonly TAG: string = 'tag';                     // 标签
  static readonly PRESENT: string = 'playRectangle';       // 演示
  static readonly LOCK: string = 'lock';                   // 锁定
  static readonly UNLOCK: string = 'lockOpen';             // 解锁
  static readonly RECORD: string = 'mic';                  // 录音
  static readonly OUTLINE: string = 'listBullet';          // 大纲
  static readonly PAGE: string = 'book';                   // 页面
}

/**
 * 图标大小规范（单位：vp）
 */
export class IconSize {
  static readonly MINI: number = 16;        // 迷你图标（内联文本）
  static readonly COMPACT: number = 20;     // 紧凑图标（工具栏紧凑模式）
  static readonly STANDARD: number = 24;    // 标准图标（默认）
  static readonly LARGE: number = 32;       // 大图标（重要操作）
  static readonly EXTRA_LARGE: number = 48; // 超大图标（空状态）
}

/**
 * 图标颜色规范
 */
export class IconColor {
  static readonly PRIMARY: string = '#007DFF';        // 主色（品牌蓝）
  static readonly SECONDARY: string = '#666666';      // 次要色（中性灰）
  static readonly DISABLED: string = '#999999';       // 禁用色
  static readonly ACTIVE: string = '#007DFF';         // 激活态
  static readonly INACTIVE: string = '#CCCCCC';       // 非激活态
  static readonly WARNING: string = '#FA9A3E';        // 警告色
  static readonly ERROR: string = '#D92D20';          // 错误色
  static readonly SUCCESS: string = '#00B578';        // 成功色
}

/**
 * 工具栏图标配置
 */
export interface ToolIconConfig {
  id: string;              // 工具ID
  symbol: string;          // SymbolGlyph名称
  size: number;            // 图标大小
  color: string;           // 默认颜色
  activeColor: string;     // 激活态颜色
  tooltip: string;         // 提示文本
}

/**
 * 预定义的工具栏图标配置
 */
export class ToolbarIcons {
  static readonly PEN: ToolIconConfig = {
    id: 'pen',
    symbol: IconSymbols.PEN,
    size: IconSize.STANDARD,
    color: IconColor.SECONDARY,
    activeColor: IconColor.PRIMARY,
    tooltip: '画笔'
  };
  
  static readonly ERASER: ToolIconConfig = {
    id: 'eraser',
    symbol: IconSymbols.ERASER,
    size: IconSize.STANDARD,
    color: IconColor.SECONDARY,
    activeColor: IconColor.PRIMARY,
    tooltip: '橡皮擦'
  };
  
  static readonly SHAPE: ToolIconConfig = {
    id: 'shape',
    symbol: IconSymbols.SHAPE,
    size: IconSize.STANDARD,
    color: IconColor.SECONDARY,
    activeColor: IconColor.PRIMARY,
    tooltip: '形状'
  };
  
  static readonly IMAGE: ToolIconConfig = {
    id: 'image',
    symbol: IconSymbols.IMAGE,
    size: IconSize.STANDARD,
    color: IconColor.SECONDARY,
    activeColor: IconColor.PRIMARY,
    tooltip: '插入图片'
  };
  
  static readonly TEXT: ToolIconConfig = {
    id: 'text',
    symbol: IconSymbols.TEXT,
    size: IconSize.STANDARD,
    color: IconColor.SECONDARY,
    activeColor: IconColor.PRIMARY,
    tooltip: '文本'
  };
  
  static readonly STICKER: ToolIconConfig = {
    id: 'sticker',
    symbol: IconSymbols.STICKER,
    size: IconSize.STANDARD,
    color: IconColor.SECONDARY,
    activeColor: IconColor.PRIMARY,
    tooltip: '贴纸'
  };
}
