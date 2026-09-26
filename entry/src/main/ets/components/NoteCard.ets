/**
 * NoteCard.ets — 笔记列表卡片（v2.4 阶段一，T1-4）
 *
 * 展示单篇笔记：缩略图 / 标题 / 更新时间 / 笔画数，并提供打开与长按菜单。
 *
 * 关于缩略图：
 *  缩略图是 `thumbs/{id}.txt` 里的 PNG dataURL。
 *  读不到（新笔记、缩略图未生成、文件损坏）时**不留白**，
 *  改用「底纸色块 + 首字」占位——列表永远保持整齐，不会出现半张灰图（A1-6）。
 *
 * 输入：meta（笔记元信息）、thumb（dataURL，可为空串）
 * 输出：onOpen / onRename / onDelete 三个回调
 */

import { NoteMeta, createNoteMeta, formatNoteTime, HC_DEFAULT_PAPER } from '../engine/types/NoteModel';
import { HCColor } from '../common/theme/DesignTokens';

/** 底纸模板 → 占位色，弱化视觉但仍可区分类型 */
function paperTint(template: string): ResourceColor {
  if (template === 'grid') {
    return HCColor.PRIMARY_BG;
  }
  if (template === 'dot') {
    return '#F1F0FA';
  }
  if (template === 'lined') {
    return '#F3F7EE';
  }
  if (template === 'four_line') {
    return '#FDF3EC';
  }
  return HCColor.DIVIDER;
}

/** 标题首字（中文取首字，英文取首字母大写），空标题回退「新」 */
function titleInitial(title: string): string {
  const t: string = title !== undefined && title !== null ? title.trim() : '';
  if (t.length === 0) {
    return '新';
  }
  return t.substring(0, 1).toUpperCase();
}

@Component
export struct NoteCard {
  /** 笔记元信息（父组件必传；给默认值仅为满足 ArkTS 初始化检查） */
  @Prop meta: NoteMeta = createNoteMeta('', '未命名笔记', HC_DEFAULT_PAPER);
  /** 缩略图 dataURL；空串表示无缩略图，走占位分支 */
  @Prop thumb: string = '';
  /** 是否存在「校验通过且比正文新」的未提交草稿（T2-1b：列表徽标「草稿待恢复」） */
  @Prop hasPendingTmp: boolean = false;
  /** F-05：搜索关键词，非空时高亮标题与匹配预览中的命中片段 */
  @Prop searchKeyword: string = '';
  /** F-05：搜索命中的正文/闪卡预览片段（已截断），非空时在标题下方展示 */
  @Prop matchPreview: string = '';

  onOpen: (noteId: string) => void = (): void => {
  };
  onRename: (noteId: string) => void = (): void => {
  };
  onAnnotate: (noteId: string) => void = (): void => {
  };
  /** v2.7.2：可见「⋯」按钮 → 打开页内操作弹层（不依赖长按菜单） */
  onMore: (noteId: string) => void = (): void => {
  };
  onDelete: (noteId: string) => void = (): void => {
  };
  /** U-12：收藏/取消收藏切换 */
  onToggleFavorite: (noteId: string) => void = (): void => {
  };
  /** U-12：当前是否已收藏（决定菜单文案） */
  @Prop isFavorite: boolean = false;
  /** v2.5.4：Tab 筛选（收藏/最近/闪卡/导图）激活时卡片高亮，补足「筛选笔记高亮无响应」 */
  @Prop isFiltered: boolean = false;

  @Builder
  menuBuilder() {
    Menu() {
      MenuItem({ content: this.isFavorite ? '取消收藏' : '收藏' })
        .onClick((): void => {
          this.onToggleFavorite(this.meta.id);
        })
      MenuItem({ content: '重命名' })
        .onClick((): void => {
          this.onRename(this.meta.id);
        })
      MenuItem({ content: '批注' })
        .onClick((): void => {
          this.onAnnotate(this.meta.id);
        })
      MenuItem({ content: '删除' })
        .onClick((): void => {
          this.onDelete(this.meta.id);
        })
    }
  }

  // ── F-05 高亮取值助手 ──
  // 说明：@Builder 体内只允许 UI 语法，不能写 const 等裸语句，
  // 因此所有字符串切分计算都下沉到普通私有方法，Builder 只做取值渲染。

  /** 当前生效的搜索关键词（已 trim）；无关键词时为空串 */
  private activeKeyword(): string {
    return this.searchKeyword.trim();
  }

  /** 卡片显示用标题；空标题回退为「未命名笔记」 */
  private displayTitle(): string {
    return this.meta.title.length > 0 ? this.meta.title : '未命名笔记';
  }

  /** U-03：人性化时间（"刚刚 / N 分钟前 / N 小时前 / 昨天 / N 天前 / 日期"） */
  private humanTime(): string {
    const now: number = Date.now();
    const diff: number = now - this.meta.updatedAt;
    if (diff < 0) {
      return formatNoteTime(this.meta.updatedAt);
    }
    const MIN: number = 60 * 1000;
    const HOUR: number = 60 * MIN;
    const DAY: number = 24 * HOUR;
    if (diff < MIN) {
      return '刚刚';
    }
    if (diff < HOUR) {
      return `${Math.floor(diff / MIN)} 分钟前`;
    }
    if (diff < DAY) {
      return `${Math.floor(diff / HOUR)} 小时前`;
    }
    if (diff < 2 * DAY) {
      return '昨天';
    }
    if (diff < 7 * DAY) {
      return `${Math.floor(diff / DAY)} 天前`;
    }
    return formatNoteTime(this.meta.updatedAt);
  }

  /** 标题中关键词命中的起始下标；无关键词或未命中返回 -1 */
  private titleHitIndex(): number {
    const kw: string = this.activeKeyword();
    if (kw.length === 0) {
      return -1;
    }
    return this.displayTitle().toLowerCase().indexOf(kw.toLowerCase());
  }

  /** 标题命中片段之前的部分 */
  private titlePre(): string {
    const idx: number = this.titleHitIndex();
    return idx < 0 ? '' : this.displayTitle().substring(0, idx);
  }

  /** 标题命中片段本身 */
  private titleHit(): string {
    const idx: number = this.titleHitIndex();
    return idx < 0 ? '' : this.displayTitle().substring(idx, idx + this.activeKeyword().length);
  }

  /** 标题命中片段之后的部分 */
  private titlePost(): string {
    const idx: number = this.titleHitIndex();
    return idx < 0 ? '' : this.displayTitle().substring(idx + this.activeKeyword().length);
  }

  /** 预览片段中关键词命中的起始下标；无关键词或未命中返回 -1 */
  private previewHitIndex(): number {
    const kw: string = this.activeKeyword();
    if (kw.length === 0) {
      return -1;
    }
    return this.matchPreview.toLowerCase().indexOf(kw.toLowerCase());
  }

  /** 预览命中片段之前的部分 */
  private previewPre(): string {
    const idx: number = this.previewHitIndex();
    return idx < 0 ? '' : this.matchPreview.substring(0, idx);
  }

  /** 预览命中片段本身 */
  private previewHit(): string {
    const idx: number = this.previewHitIndex();
    return idx < 0 ? '' : this.matchPreview.substring(idx, idx + this.activeKeyword().length);
  }

  /** 预览命中片段之后的部分 */
  private previewPost(): string {
    const idx: number = this.previewHitIndex();
    return idx < 0 ? '' : this.matchPreview.substring(idx + this.activeKeyword().length);
  }

  /** F-05：标题视图；搜索关键词命中时对命中片段着色高亮 */
  @Builder
  titleView() {
    if (this.titleHitIndex() >= 0) {
      Text() {
        Span(this.titlePre())
        Span(this.titleHit())
          .fontColor(HCColor.PRIMARY)
          .fontWeight(FontWeight.Bold)
        Span(this.titlePost())
      }
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor(HCColor.TEXT_PRIMARY)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
    } else {
      Text(this.displayTitle())
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(HCColor.TEXT_PRIMARY)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
  }

  /** F-05：命中预览片段；关键词命中时着色高亮，最多两行截断 */
  @Builder
  previewView() {
    if (this.previewHitIndex() >= 0) {
      Text() {
        Span(this.previewPre())
        Span(this.previewHit())
          .fontColor(HCColor.PRIMARY)
        Span(this.previewPost())
      }
      .fontSize(12)
      .fontColor(HCColor.TEXT_TERTIARY)
      .maxLines(2)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .margin({ top: 4 })
    } else {
      Text(this.matchPreview)
        .fontSize(12)
        .fontColor(HCColor.TEXT_TERTIARY)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .margin({ top: 4 })
    }
  }

  build() {
    Column() {
      // ── 缩略图区 ──
      Stack() {
        if (this.thumb.length > 0) {
          Image(this.thumb)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .interpolation(ImageInterpolation.Medium)
        } else {
          Column() {
            Text(titleInitial(this.meta.title))
              .fontSize(30)
              .fontWeight(FontWeight.Medium)
              .fontColor(HCColor.TEXT_DISABLED)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(paperTint(this.meta.paperTemplate))
        }

        // T2-1b：草稿待恢复徽标（仅「校验通过且比正文新」的草稿槽亮，闸 B 已在仓储判定）
        if (this.hasPendingTmp) {
          Text('草稿待恢复')
            .fontSize(10)
            .fontColor(HCColor.WARNING)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .backgroundColor(HCColor.WARNING_BG)
            .borderRadius(4)
            .position({ x: 6, y: 6 })
        }

        // 🔴 v2.7.2 审核修复（问题②-1「重命名更新不及时」/ ②-4「批注点击无反应」）：
        //   这两个操作此前**只能**通过长按弹出的 bindContextMenu 菜单触发。
        //   现新增一个**始终可见的「⋯」按钮**，走页内弹层（与重命名/删除对话框同一套
        //   已被验证可用的机制），彻底摆脱对长按菜单的依赖。
        //   卡片本身仍保留长按菜单（已修正绑定写法），两条路径并存。
        Text('⋯')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(HCColor.TEXT_SECONDARY)
          .width(30)
          .height(30)
          .textAlign(TextAlign.Center)
          .backgroundColor(HCColor.SURFACE)
          .borderRadius(15)
          .shadow({ radius: 4, color: 'rgba(0,0,0,0.12)', offsetY: 1 })
          .position({ x: '100%', y: 0 })
          .translate({ x: -36, y: 6 })
          .onClick((): void => {
            // 阻止冒泡到卡片（避免同时触发 onOpen 打开笔记）
            this.onMore(this.meta.id);
          })
      }
      .width('100%')
      .height(130)
      .borderRadius({ topLeft: 12, topRight: 12 })
      .clip(true)
      .backgroundColor(paperTint(this.meta.paperTemplate))

      // ── 文本区 ──
      Column() {
        this.titleView()

        Row() {
          Text(this.humanTime())
            .fontSize(11)
            .fontColor(HCColor.TEXT_TERTIARY)

          Blank()

          Text(`${this.meta.strokeCount} 笔`)
            .fontSize(11)
            .fontColor(HCColor.TEXT_TERTIARY)
        }
        .width('100%')
        .margin({ top: 4 })

        if (this.matchPreview.length > 0) {
          this.previewView()
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 10, right: 10, top: 8, bottom: 10 })
    }
    .width('100%')
    // 🔧 v2.5.4：高亮条件并入 isFiltered（Tab 筛选激活），主题感知色替换硬编码色，
    //   同时修复深色模式下 '#F0F7FF' 浅蓝底配浅色字"看不清"的问题（审核项④）。
    .borderRadius(12)
    .border({
      width: this.titleHitIndex() >= 0 || this.matchPreview.length > 0 || this.isFiltered ? 2 : 1,
      color: this.titleHitIndex() >= 0 || this.matchPreview.length > 0 || this.isFiltered ? HCColor.PRIMARY : HCColor.DIVIDER
    })
    .backgroundColor(
      this.titleHitIndex() >= 0 || this.matchPreview.length > 0 || this.isFiltered ? HCColor.PRIMARY_BG : HCColor.SURFACE
    )
    .clip(true)
    .onClick((): void => {
      this.onOpen(this.meta.id);
    })
    // 🔴 v2.7.2：改为传递 **Builder 引用**（ArkUI 文档写法）。
    //   原写法 `this.menuBuilder()` 是**在 build 期间就调用**了 Builder，
    //   菜单虽然能弹出，但菜单项的点击回调在真机上不可靠（审核连续两轮反馈
    //   「批注点击无反应」「重命名更新不及时」，而这两个动作原本只在这个菜单里）。
    .bindContextMenu(this.menuBuilder, ResponseType.LongPress)
  }
}
