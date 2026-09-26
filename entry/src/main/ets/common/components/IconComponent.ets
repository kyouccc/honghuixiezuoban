/**
 * 统一图标组件 - 支持SymbolGlyph和Emoji双模式
 * 
 * 设计目标：
 * 1. 优先使用SymbolGlyph（HarmonyOS系统图标）
 * 2. 降级支持Emoji（兼容性保障）
 * 3. 统一图标样式和交互
 * 
 * @since 2026-08-08
 */

import { IconSize, IconColor, ToolIconConfig } from '../IconConstants';

/**
 * 图标组件属性
 */
export interface IconProps {
  symbol?: string;           // SymbolGlyph名称
  emoji?: string;            // Emoji字符（降级方案）
  size?: number;             // 图标大小（默认24）
  color?: string;            // 图标颜色
  isActive?: boolean;        // 是否激活态
  activeColor?: string;      // 激活态颜色
}

/**
 * 图标显示模式
 */
export enum IconMode {
  SYMBOL = 'symbol',         // SymbolGlyph模式（优先）
  EMOJI = 'emoji',           // Emoji模式（降级）
  AUTO = 'auto'              // 自动选择
}

/**
 * 图标组件 - 统一图标渲染组件
 */
@Component
export struct IconComponent {
  // SymbolGlyph名称
  @Prop symbol: string = '';
  
  // Emoji字符（降级方案）
  @Prop emoji: string = '';
  
  // 图标大小（重命名避免与基类size方法冲突）
  @Prop iconSize: number = IconSize.STANDARD;
  
  // 图标颜色
  @Prop color: ResourceColor = IconColor.SECONDARY;
  
  // 是否激活态
  @Prop isActive: boolean = false;
  
  // 激活态颜色
  @Prop activeColor: ResourceColor = IconColor.PRIMARY;
  
  // 显示模式
  @Prop mode: IconMode = IconMode.AUTO;
  
  build() {
    if (this.shouldUseSymbol()) {
      // 使用SymbolGlyph系统图标
      SymbolGlyph($r(`sys.symbol.${this.symbol}`))
        .fontSize(this.iconSize)
        .fontColor([this.getFinalColor()])
    } else {
      // 降级使用Emoji
      Text(this.emoji)
        .fontSize(this.iconSize)
        .fontColor(this.getFinalColor())
    }
  }
  
  /**
   * 判断是否使用SymbolGlyph
   */
  private shouldUseSymbol(): boolean {
    if (this.mode === IconMode.EMOJI) {
      return false;
    }
    if (this.mode === IconMode.SYMBOL) {
      return true;
    }
    // AUTO模式：优先使用SymbolGlyph
    return this.symbol.length > 0;
  }
  
  /**
   * 获取最终颜色
   */
  private getFinalColor(): ResourceColor {
    return this.isActive ? this.activeColor : this.color;
  }
}

/**
 * 图标组件构建器
 * 提供统一的图标渲染接口
 */
export class IconBuilder {
  private mode: IconMode = IconMode.AUTO;
  private symbolName: string = '';
  private emojiChar: string = '';
  private iconSize: number = IconSize.STANDARD;
  private iconColor: string = IconColor.SECONDARY;
  private isActiveState: boolean = false;
  private activeColorValue: string = IconColor.PRIMARY;
  
  /**
   * 设置图标模式
   */
  setMode(mode: IconMode): IconBuilder {
    this.mode = mode;
    return this;
  }
  
  /**
   * 设置SymbolGlyph名称
   */
  setSymbol(symbol: string): IconBuilder {
    this.symbolName = symbol;
    return this;
  }
  
  /**
   * 设置Emoji字符
   */
  setEmoji(emoji: string): IconBuilder {
    this.emojiChar = emoji;
    return this;
  }
  
  /**
   * 设置图标大小
   */
  setSize(size: number): IconBuilder {
    this.iconSize = size;
    return this;
  }
  
  /**
   * 设置图标颜色
   */
  setColor(color: string): IconBuilder {
    this.iconColor = color;
    return this;
  }
  
  /**
   * 设置激活态
   */
  setActive(isActive: boolean, activeColor?: string): IconBuilder {
    this.isActiveState = isActive;
    if (activeColor) {
      this.activeColorValue = activeColor;
    }
    return this;
  }
  
  /**
   * 从配置构建
   */
  fromConfig(config: ToolIconConfig): IconBuilder {
    this.symbolName = config.symbol;
    this.iconSize = config.size;
    this.iconColor = config.color;
    this.activeColorValue = config.activeColor;
    return this;
  }
  
  /**
   * 获取最终颜色
   */
  getFinalColor(): string {
    return this.isActiveState ? this.activeColorValue : this.iconColor;
  }
  
  /**
   * 判断是否使用SymbolGlyph
   */
  shouldUseSymbol(): boolean {
    if (this.mode === IconMode.EMOJI) {
      return false;
    }
    if (this.mode === IconMode.SYMBOL) {
      return true;
    }
    // AUTO模式：优先使用SymbolGlyph
    return this.symbolName.length > 0;
  }
}

/**
 * 图标工具函数
 */
export class IconUtils {
  /**
   * 创建标准工具图标
   */
  static createToolIcon(
    symbol: string,
    emoji: string,
    size: number = IconSize.STANDARD
  ): IconProps {
    return {
      symbol: symbol,
      emoji: emoji,
      size: size,
      color: IconColor.SECONDARY,
      activeColor: IconColor.PRIMARY
    };
  }
  
  /**
   * 创建导航图标
   */
  static createNavIcon(symbol: string, emoji: string): IconProps {
    return {
      symbol: symbol,
      emoji: emoji,
      size: IconSize.COMPACT,
      color: IconColor.SECONDARY
    };
  }
  
  /**
   * 创建状态图标
   */
  static createStatusIcon(
    symbol: string,
    type: 'success' | 'warning' | 'error' | 'info'
  ): IconProps {
    // ArkTS不支持对象字面量和索引访问，使用switch-case
    let color: string = IconColor.PRIMARY;
    switch (type) {
      case 'success':
        color = IconColor.SUCCESS;
        break;
      case 'warning':
        color = IconColor.WARNING;
        break;
      case 'error':
        color = IconColor.ERROR;
        break;
      case 'info':
        color = IconColor.PRIMARY;
        break;
    }
    
    return {
      symbol: symbol,
      size: IconSize.STANDARD,
      color: color
    };
  }
  
}

