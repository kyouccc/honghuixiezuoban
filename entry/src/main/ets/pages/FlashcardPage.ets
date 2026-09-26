/**
 * FlashcardPage.ets — 闪卡复习页（v2.5 重做 UI）
 *
 * SM-2 复习流程：
 *  1. 到期队列 → 翻转卡片（问题 → 答案）
 *  2. 打分（记得/模糊/忘记）
 *  3. 新建/删除闪卡
 *
 * UI 特征：
 *  - 卡片式翻转交互，带 3D 翻转动画
 *  - 评分快捷按钮组
 *  - 卡片列表磁贴式设计
 */
import { router, promptAction } from '@kit.ArkUI';
import { HCFlashcard } from '../engine/types/NoteModel';
import { FlashcardStore } from '../engine/memory/FlashcardStore';
import { SM2Scheduler } from '../engine/memory/SM2Scheduler';
import { HCColor, HCBrand, HCOverlay } from '../common/theme/DesignTokens';
import { IconSymbols } from '../common/IconConstants';
import { Logger } from '../common/Logger';

const TAG_MODULE = 'FlashcardPage';

@Component
export struct FlashcardPage {
  // v3.1 修复：使用单例 store，让添加的闪卡跨页面/重启可见
  store: FlashcardStore = FlashcardStore.getInstance();
  @State private storeLoaded: boolean = false;
  @State private storeRevision: number = 0;
  /**
   * v2.6.0 审核修复（问题②-2 真因）：
   *   原来 build() 直接读 `this.store.count()` / `this.store.list()`，
   *   而 FlashcardStore 是普通单例（非 @Observed），`@State revision` 虽然到处 ++
   *   却**从未在 build() 中被读取** —— ArkUI 只在「build 中读取过的 @State」变化时
   *   才标脏重渲染，于是新增/删除闪卡后界面纹丝不动，
   *   必须退出重进页面才刷新（审核员实测即此）。
   *   修法：用 @State 数组做「本页渲染快照」，每次变更后显式同步，build 只读快照。
   */
  @State private cards: HCFlashcard[] = [];

  /**
   * 🔧 v2.7.0 审核修复（问题② 底部导航条适配）：
   *   读取 EntryAbility 写入 AppStorage 的真实底部避让高度，避免底部按钮被系统导航条盖住。
   */
  @StorageProp('hcSafeAreaBottom') safeBottom: number = 0;

  private bottomInset(): number {
    const v: number = this.safeBottom;
    return v !== undefined && v !== null && v > 0 ? v : 0;
  }
  @State reviewingId: string = '';
  @State showAnswer: boolean = false;
  @State newQuestion: string = '';
  @State newAnswer: string = '';
  @State showAdd: boolean = false;
  @State revision: number = 0;
  @State currentCard: HCFlashcard | null = null;
  /** 翻转动画状态 */
  @State flipped: boolean = false;

  onChanged: () => void = () => {};
  onClose: () => void = () => { router.back(); };

  aboutToAppear(): void {
    this.reviewingId = '';
    this.showAnswer = false;
    this.currentCard = null;
    this.flipped = false;
    this.syncCards();
    // v3.1 修复：从 Preferences 异步加载历史闪卡
    this.store.load().then((): void => {
      this.storeLoaded = true;
      // v2.6.0：加载完成后同步快照，驱动列表重渲染
      this.syncCards();
    }).catch((err: Error): void => {
      Logger.error(TAG_MODULE, 'load store failed: ' + err.message);
      this.storeLoaded = true;
      this.syncCards();
    });
  }

  /**
   * v2.6.0：把 store 内容同步到 @State 快照（build 只读快照 → 变更必刷新）。
   * 调用 `slice()` 产生新数组引用，确保 ArkUI 感知为「变化」。
   */
  private syncCards(): void {
    this.cards = this.store.list().slice();
    this.storeRevision++;
    this.revision++;
  }

  /** 到期张数（基于快照计算，保证与列表同步刷新） */
  private dueCount(): number {
    const now: number = Date.now();
    let n: number = 0;
    for (let i = 0; i < this.cards.length; i++) {
      const d: number = this.cards[i].dueAt;
      if (d > 0 && d <= now) {
        n++;
      }
    }
    return n;
  }

  aboutToDisappear(): void {
    // v3.1 修复：页面退出时立即同步落盘，避免 debounce 延迟导致的数据丢失
    this.store.saveNow();
  }

  private reviewingCard(): HCFlashcard | null {
    if (this.reviewingId.length === 0) { return null; }
    return this.store.find(this.reviewingId);
  }

  private startReview(): void {
    const due: HCFlashcard[] = this.store.dueCards(Date.now());
    if (due.length === 0) {
      this.reviewingId = '';
      this.currentCard = null;
      this.showAnswer = false;
      this.flipped = false;
      this.revision++;
      return;
    }
    this.reviewingId = due[0].id;
    this.currentCard = due[0];
    this.showAnswer = false;
    this.flipped = false;
    this.revision++;
  }

  private grade(quality: number): void {
    const card: HCFlashcard | null = this.reviewingCard();
    if (card === null) { return; }
    const outcome = SM2Scheduler.review(card.box, card.ease, card.interval, card.reps, card.lapses, quality);
    this.store.update(card.id, card.question, card.answer);
    const updated: HCFlashcard | null = this.store.find(card.id);
    if (updated !== null) {
      updated.box = outcome.box;
      updated.ease = outcome.ease;
      updated.interval = outcome.interval;
      updated.dueAt = outcome.dueAt;
      updated.reps = outcome.reps;
      updated.lapses = outcome.lapses;
    }
    this.onChanged();
    this.reviewingId = '';
    this.flipped = false;
    const due: HCFlashcard[] = this.store.dueCards(Date.now());
    if (due.length > 0) {
      this.reviewingId = due[0].id;
      this.currentCard = due[0];
      this.showAnswer = false;
      this.flipped = false;
    } else {
      this.reviewingId = '';
      this.currentCard = null;
      this.showAnswer = false;
      this.flipped = false;
    }
    // v2.6.0：评分会改动 box/dueAt，需同步快照让列表与到期数刷新
    this.syncCards();
    this.store.saveNow().catch((err: Error): void => {
      Logger.error(TAG_MODULE, 'grade saveNow failed: ' + err.message);
    });
  }

  private flipCard(): void {
    this.flipped = !this.flipped;
    this.showAnswer = true;
  }

  private commitAdd(): void {
    const q: string = this.newQuestion.trim();
    if (q.length === 0) {
      // v3.1 修复：空问题给出明确提示，而非静默忽略
      promptAction.showToast({ message: '请输入问题内容', duration: 1500 });
      return;
    }
    const newCard: HCFlashcard = this.store.add(q, this.newAnswer.trim());
    this.newQuestion = '';
    this.newAnswer = '';
    this.showAdd = false;
    this.onChanged();
    // v3.1 修复：添加后立即落盘 + Toast 反馈，避免用户认为"添加失败"
    this.store.saveNow().catch((err: Error): void => {
      Logger.error(TAG_MODULE, 'saveNow failed: ' + err.message);
    });
    // v2.6.0：同步 @State 快照 → 列表当场刷新（原实现只自增没人读的计数器 → 不刷新）
    this.syncCards();
    promptAction.showToast({ message: `已添加：${newCard.question.substring(0, 12)}`, duration: 1500 });
  }

  private deleteCard(cardId: string): void {
    this.store.remove(cardId);
    if (this.reviewingId === cardId) {
      this.reviewingId = '';
      this.showAnswer = false;
      this.currentCard = null;
      this.flipped = false;
    }
    this.onChanged();
    // v2.6.0：删除后同样立即同步快照 + 落盘
    this.syncCards();
    this.store.saveNow().catch((err: Error): void => {
      Logger.error(TAG_MODULE, 'delete saveNow failed: ' + err.message);
    });
  }

  // ═══════════════════════════════════════════════════
  // Build
  // ═══════════════════════════════════════════════════

  build() {
    Column() {
      // ── 顶部导航栏 ──
      Row() {
        Button() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.BACK))
            .fontSize(18).fontColor([HCColor.TEXT_PRIMARY])
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(HCColor.PAGE_BG)
        .onClick(() => this.onClose())

        Blank()

        Column() {
          Text('闪卡复习').fontSize(18).fontWeight(FontWeight.Bold).fontColor(HCColor.TEXT_PRIMARY)
          Text(`${this.cards.length} 张 · ${this.dueCount()} 到期`)
            .fontSize(11).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Center)

        Blank()

        Button() {
          Text('+').fontSize(20).fontColor(Color.White)
        }
        .width(36).height(36).borderRadius(18)
        .backgroundColor(HCColor.PRIMARY)
        .onClick(() => { this.showAdd = !this.showAdd; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 48, bottom: 8 })

      // ── 新建闪卡面板 ──
      if (this.showAdd) {
        Column() {
          Text('新建闪卡').fontSize(16).fontWeight(FontWeight.Medium).margin({ bottom: 12 })
          TextInput({ placeholder: '输入问题...', text: this.newQuestion })
            .width('100%').height(40).fontSize(14)
            .borderRadius(10).backgroundColor(HCColor.PAGE_BG)
            .padding({ left: 12 })
            .onChange((v: string) => { this.newQuestion = v; })
          Blank().height(10)
          TextInput({ placeholder: '输入答案...', text: this.newAnswer })
            .width('100%').height(40).fontSize(14)
            .borderRadius(10).backgroundColor(HCColor.PAGE_BG)
            .padding({ left: 12 })
            .onChange((v: string) => { this.newAnswer = v; })
          Blank().height(14)
          Row() {
            Button('取消')
              .height(36).fontSize(13).borderRadius(18)
              .backgroundColor(HCColor.PAGE_BG).fontColor(HCColor.TEXT_SECONDARY)
              .onClick(() => { this.showAdd = false; })
            Blank().width(12)
            Button('添加')
              .height(36).fontSize(13).borderRadius(18)
              .backgroundColor(HCColor.PRIMARY).fontColor(Color.White)
              .onClick(() => this.commitAdd())
          }
        }
        .width('100%').padding(16)
        .backgroundColor(HCColor.SURFACE)
        .borderRadius(16).margin({ left: 16, right: 16, bottom: 12 })
        .shadow({ radius: 8, color: HCOverlay.SHADE_08 })
        .transition(TransitionEffect.opacity(0).animation({ duration: 200 }))
      }

      // ── 复习模式 ──
      if (this.reviewingId.length > 0 && this.currentCard !== null) {
        this.reviewCard(this.currentCard)
      } else {
        this.cardList()
      }
    }
    .width('100%').height('100%')
    .backgroundColor(HCColor.PAGE_BG)
  }

  // ═══════════════════════════════════════════════════
  // 复习卡片（翻转交互）
  // ═══════════════════════════════════════════════════

  @Builder
  reviewCard(card: HCFlashcard) {
    Column() {
      Blank().layoutWeight(1)

      // ── 翻转卡片 ──
      Column() {
        if (!this.flipped) {
          // 问题面
          Column() {
            Text(card.question)
              .fontSize(22).fontWeight(FontWeight.Bold)
              .fontColor(HCColor.TEXT_PRIMARY)
              .textAlign(TextAlign.Center)
              .maxLines(6).lineHeight(32)
          }
          .width('100%').height(240)
          .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

          Blank().height(20)

          Button() {
            Text('点击翻转').fontSize(14).fontColor(HCColor.PRIMARY)
          }
          .height(40).borderRadius(20)
          .backgroundColor(HCColor.PRIMARY_BG)
          .onClick(() => this.flipCard())
        } else {
          // 答案面
          Scroll() {
            Column() {
              Text('问题').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ bottom: 6 })
              Text(card.question)
                .fontSize(16).fontWeight(FontWeight.Medium)
                .fontColor(HCColor.TEXT_PRIMARY)
                .textAlign(TextAlign.Center)
                .width('100%')
              Divider().height(1).color(HCColor.DIVIDER).margin({ top: 16, bottom: 16 })
              Text('答案').fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ bottom: 6 })
              Text(card.answer.length > 0 ? card.answer : '(无答案)')
                .fontSize(16)
                .fontColor(card.answer.length > 0 ? HCColor.TEXT_PRIMARY : HCColor.TEXT_TERTIARY)
                .textAlign(TextAlign.Center)
                .width('100%')
            }
            .width('100%').padding(20)
          }
          .height(220).width('100%')
          // v2.5.2 审核修复：滑动到边界需有反馈动效
          .edgeEffect(EdgeEffect.Spring)

          Blank().height(20)

          // ── 评分按钮 ──
          Row() {
            // 忘记 (q=1)
            Button() {
              Column() {
                SymbolGlyph($r('sys.symbol.' + IconSymbols.CLOSE))
                  .fontSize(22)
                  .fontColor([HCBrand.RED_SOFT])
                Text('忘记').fontSize(12).fontColor(HCBrand.RED_SOFT).margin({ top: 4 })
              }
            }
            .width(72).height(72).borderRadius(36)
            .backgroundColor(HCBrand.RED_SOFT_BG)
            .onClick(() => this.grade(1))

            Blank().width(16)

            // 模糊 (q=2)
            Button() {
              Column() {
                SymbolGlyph($r('sys.symbol.' + IconSymbols.INFO))
                  .fontSize(22)
                  .fontColor([HCBrand.AMBER])
                Text('模糊').fontSize(12).fontColor(HCBrand.AMBER).margin({ top: 4 })
              }
            }
            .width(72).height(72).borderRadius(36)
            .backgroundColor(HCBrand.AMBER_BG)
            .onClick(() => this.grade(2))

            Blank().width(16)

            // 记得 (q=4)
            Button() {
              Column() {
                SymbolGlyph($r('sys.symbol.' + IconSymbols.SUCCESS))
                  .fontSize(22)
                  .fontColor([HCBrand.GREEN_SOFT])
                Text('记得').fontSize(12).fontColor(HCBrand.GREEN_SOFT).margin({ top: 4 })
              }
            }
            .width(72).height(72).borderRadius(36)
            .backgroundColor(HCBrand.GREEN_SOFT_BG)
            .onClick(() => this.grade(4))
          }
          .padding({ bottom: 8 })
        }
      }
      .width('88%')
      .padding(20)
      // 🔴 v2.7.2 审核修复（问题②-3「深色模式下闪卡内容看不清」）：
      //   卡片容器原硬编码 Color.White，而卡内文字用 HCColor.TEXT_PRIMARY
      //   （深色模式解析为浅色）→ 浅色文字压在白色卡片上，完全不可读。
      .backgroundColor(HCColor.SURFACE)
      .borderRadius(20)
      .shadow({ radius: 16, color: HCOverlay.SHADE_10 })
      .alignItems(HorizontalAlign.Center)

      Blank().layoutWeight(1)

      // ── 进度 ──
      Text(`剩余 ${this.dueCount()} 张`)
        .fontSize(12).fontColor(HCColor.TEXT_TERTIARY).margin({ bottom: 24 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  // ═══════════════════════════════════════════════════
  // 卡片列表模式
  // ═══════════════════════════════════════════════════

  @Builder
  cardList() {
    Column() {
      if (this.cards.length === 0) {
        // 空态
        Column() {
          SymbolGlyph($r('sys.symbol.' + IconSymbols.DOC_TEXT))
            .fontSize(48).fontColor([HCColor.TEXT_TERTIARY]).margin({ bottom: 12 })
          Text('还没有闪卡').fontSize(16).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
          Text('点击右上角 + 新建第一张闪卡').fontSize(13).fontColor(HCColor.TEXT_TERTIARY).margin({ top: 6 })
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        // 卡片列表
        Scroll() {
          Column() {
            // 统计行
            Row() {
              Text('全部闪卡').fontSize(16).fontWeight(FontWeight.Medium).fontColor(HCColor.TEXT_PRIMARY)
              Blank()
              Text(`${this.cards.length} 张`).fontSize(13).fontColor(HCColor.TEXT_TERTIARY)
            }
            .width('100%').padding({ left: 4, right: 4, bottom: 10 })

            ForEach(this.cards, (card: HCFlashcard) => {
              Row() {
                // 左侧类型指示
                Column() {
                  Text(card.box === 0 ? '新' : `${card.box}`)
                    .fontSize(11).fontWeight(FontWeight.Bold)
                    .fontColor(card.box === 0 ? HCColor.PRIMARY : HCColor.TEXT_SECONDARY)
                }
                .width(28).height(28).borderRadius(14)
                .backgroundColor(card.box === 0 ? HCColor.PRIMARY_BG : HCColor.PAGE_BG)
                .justifyContent(FlexAlign.Center).alignItems(HorizontalAlign.Center)

                Blank().width(12)

                // 内容
                Column() {
                  Text(card.question)
                    .fontSize(14).fontColor(HCColor.TEXT_PRIMARY)
                    .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                  if (card.answer.length > 0) {
                    Text(card.answer)
                      .fontSize(12).fontColor(HCColor.TEXT_TERTIARY)
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                      .width('100%').margin({ top: 2 })
                  }
                }
                .layoutWeight(1).alignItems(HorizontalAlign.Start)

                // 删除
                Button() {
                  Text('×').fontSize(14).fontColor(HCColor.TEXT_TERTIARY)
                }
                .width(28).height(28).borderRadius(14)
                .backgroundColor(HCColor.PAGE_BG)
                .onClick(() => this.deleteCard(card.id))
              }
              .width('100%').height(56).padding({ left: 12, right: 8 })
              // 🔴 v2.7.2 审核修复（问题②-3「深色模式下闪卡内容看不清」）：
              //   卡片容器原硬编码 Color.White，而卡内文字用 HCColor.TEXT_PRIMARY
              //   （深色模式解析为浅色）→ 浅色文字压在白色卡片上，完全不可读。
              .backgroundColor(HCColor.SURFACE)
              .borderRadius(12)
              .margin({ bottom: 8 })
              .shadow({ radius: 4, color: HCOverlay.SHADE_04 })
              .onClick(() => {
                this.currentCard = card;
                this.reviewingId = card.id;
                this.showAnswer = false;
                this.flipped = false;
                this.revision++;
              })
            }, (card: HCFlashcard) => card.id)
          }
          .width('100%').padding({ left: 16, right: 16, top: 4 })
        }
        .layoutWeight(1)
        // v2.5.2 审核修复：滑动到边界需有反馈动效
        .edgeEffect(EdgeEffect.Spring)
      }

      // ── 开始复习按钮 ──
      Button() {
        Row() {
          Text('▶').fontSize(16).fontColor(Color.White)
          Blank().width(8)
          Text('开始复习').fontSize(16).fontWeight(FontWeight.Medium).fontColor(Color.White)
        }
        .alignItems(VerticalAlign.Center).justifyContent(FlexAlign.Center)
      }
      .width('88%').height(48).borderRadius(24)
      .backgroundColor(this.dueCount() > 0 ? HCColor.PRIMARY : HCColor.DIVIDER)
      // 🔧 v2.7.0 审核修复（问题②「闪卡复习底部按钮与导航条重叠」）：
      //   原为写死 margin bottom 32vp，平板上系统导航条更高时按钮会被压住。
      //   现叠加真实底部避让高度（AppStorage hcSafeAreaBottom）。
      .margin({ bottom: 32 + this.bottomInset() })
      .onClick(() => this.startReview())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }
}
