/**
 * ImageInsert.ets - 图片插入组件
 * 功能：本地图片导入、截图粘贴、缩放、旋转、裁剪
 *
 * v2.4 阶段一（T1-5）改造：
 *  - 原 saveToCanvas() 只打了一行日志就把 selectedImage 清空，图片**从未真正进入画布**，
 *    是「图片功能用不了」的直接原因。现改为通过 onInserted 回调把 uri + 显示尺寸交给白板页，
 *    由白板页写入图层并纳入 .hcnote 持久化（U-4：阶段一只存 uri，不内嵌二进制）；
 *  - 新增 onClose 回调与关闭按钮，避免浮层打开后无法关掉。
 */

import { Logger } from '../common/Logger';
import { ImageManager } from '../engine/ImageManager';
import picker from '@ohos.file.picker';
import pasteboard from '@ohos.pasteboard';
import { BusinessError } from '@ohos.base';
import { HCColor, HCBrand, HCAccent, HCOverlay } from '../common/theme/DesignTokens';

/** 插图基准显示边长（vp），实际尺寸 = BASE_SIZE * imageScale */
const BASE_IMAGE_SIZE: number = 300;

interface CropRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 插入回执：uri + 目标显示尺寸（白板页据此建 ImageRefData） */
export interface ImageInsertResult {
  uri: string;
  width: number;
  height: number;
  rotation: number;
  scale: number;
}

@Component
export struct ImageInsert {
  @State showImagePicker: boolean = false;
  @State selectedImage: string = '';
  @State imageScale: number = 1.0;
  @State imageRotation: number = 0;
  @State isDragging: boolean = false;
  @State dragStartX: number = 0;
  @State dragStartY: number = 0;
  @State imageX: number = 0;
  @State imageY: number = 0;
  @State cropMode: boolean = false;
  @State cropRect: CropRect = { x: 0, y: 0, width: 100, height: 100 };
  @State hintText: string = '';

  /** 「添加到画布」回调：白板页据此把图片挂到当前图层并触发保存 */
  onInserted: (result: ImageInsertResult) => void = (result: ImageInsertResult) => {};
  /** 关闭浮层 */
  onClose: () => void = () => {};

  private imageManager: ImageManager = ImageManager.getInstance();

  aboutToAppear(): void {
    // 初始化图片管理器
    this.imageManager.init();
  }

  // 选择本地图片
  async pickLocalImage(): Promise<void> {
    try {
      // 使用HarmonyOS图片选择器API
      const photoSelectOptions = new picker.PhotoSelectOptions();
      photoSelectOptions.MIMEType = picker.PhotoViewMIMETypes.IMAGE_TYPE;
      photoSelectOptions.maxSelectNumber = 1;
      
      const photoPicker = new picker.PhotoViewPicker();
      const result = await photoPicker.select(photoSelectOptions);
      
      if (result && result.photoUris && result.photoUris.length > 0) {
        this.selectedImage = result.photoUris[0];
        this.showImagePicker = false;
        this.resetImageTransform();
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error('ImageInsert', `pickLocalImage error: ${err.message}`);
    }
  }

  // 粘贴截图
  async pasteScreenshot(): Promise<void> {
    try {
      // 使用系统剪贴板API
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const data = await systemPasteboard.getPasteData();
      if (data && data.getRecordCount() > 0) {
        const record = data.getRecordAt(0);
        if (record && record.mimeType === pasteboard.MIMETYPE_PIXELMAP) {
          // 处理图片数据
          Logger.info('ImageInsert', 'Screenshot pasted successfully');
          this.resetImageTransform();
        }
      }
    } catch (error) {
      const err = error as BusinessError;
      Logger.error('ImageInsert', `pasteScreenshot error: ${err.message}`);
    }
  }

  // 重置图片变换
  resetImageTransform(): void {
    this.imageScale = 1.0;
    this.imageRotation = 0;
    this.imageX = 0;
    this.imageY = 0;
  }

  // 缩放图片
  scaleImage(factor: number): void {
    this.imageScale = Math.max(0.1, Math.min(this.imageScale * factor, 10.0));
  }

  // 旋转图片
  rotateImage(degrees: number): void {
    this.imageRotation = (this.imageRotation + degrees) % 360;
  }

  // 开始拖动
  startDrag(x: number, y: number): void {
    this.isDragging = true;
    this.dragStartX = x - this.imageX;
    this.dragStartY = y - this.imageY;
  }

  // 拖动图片
  dragImage(x: number, y: number): void {
    if (this.isDragging) {
      this.imageX = x - this.dragStartX;
      this.imageY = y - this.dragStartY;
    }
  }

  // 结束拖动
  endDrag(): void {
    this.isDragging = false;
  }

  // 开始裁剪
  startCrop(x: number, y: number): void {
    this.cropMode = true;
    this.cropRect = { x: x, y: y, width: 100, height: 100 };
  }

  // 调整裁剪区域
  resizeCrop(x: number, y: number, width: number, height: number): void {
    this.cropRect = { x: x, y: y, width: width, height: height };
  }

  // 应用裁剪
  async applyCrop(): Promise<void> {
    if (!this.selectedImage) {
      return;
    }

    try {
      const croppedImage = await this.imageManager.cropImage(
        this.selectedImage,
        this.cropRect.x,
        this.cropRect.y,
        this.cropRect.width,
        this.cropRect.height
      );
      this.selectedImage = croppedImage;
      this.cropMode = false;
      this.resetImageTransform();
    } catch (error) {
      const err = error as BusinessError;
      Logger.error('ImageInsert', `applyCrop error: ${err.message}`);
    }
  }

  // 保存图片到画布：真正把 uri 交给白板页（v2.4 修复）
  saveToCanvas(): void {
    if (this.selectedImage.length === 0) {
      this.hintText = '请先选择一张图片';
      return;
    }

    const size: number = BASE_IMAGE_SIZE * this.imageScale;
    const result: ImageInsertResult = {
      uri: this.selectedImage,
      width: size,
      height: size,
      rotation: this.imageRotation,
      scale: this.imageScale,
    };
    Logger.info('ImageInsert', `Image inserted to canvas: ${this.selectedImage}`);
    this.onInserted(result);
    this.selectedImage = '';
    this.hintText = '';
    this.resetImageTransform();
    this.onClose();
  }

  build() {
    Column() {
      // 标题栏（带关闭按钮）
      Row() {
        Text('插入图片')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(HCAccent.TEXT_STRONG)

        Blank()

        Text('×')
          .fontSize(15)
          .fontColor(HCColor.ICON_SECONDARY)
          .width(28)
          .height(28)
          .textAlign(TextAlign.Center)
          .onClick(() => this.onClose())
      }
      .width('100%')
      .margin({ bottom: 8 })

      // 图片操作工具栏（按钮较多，换行排布，避免窄屏被裁切）
      Flex({ wrap: FlexWrap.Wrap }) {
        Button('选择图片')
          .fontSize(12)
          .height(30)
          .backgroundColor(HCBrand.GREEN)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.pickLocalImage();
          })

        Button('粘贴截图')
          .fontSize(12)
          .height(30)
          .backgroundColor(HCBrand.BLUE)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.pasteScreenshot();
          })

        Button('缩放+')
          .fontSize(12)
          .height(30)
          .backgroundColor(HCBrand.ORANGE)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.scaleImage(1.2);
          })

        Button('缩放-')
          .fontSize(12)
          .height(30)
          .backgroundColor(HCBrand.ORANGE)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.scaleImage(0.8);
          })

        Button('旋转')
          .fontSize(12)
          .height(30)
          .backgroundColor(HCBrand.PURPLE)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            this.rotateImage(90);
          })

        Button(this.cropMode ? '完成裁剪' : '裁剪')
          .fontSize(12)
          .height(30)
          .backgroundColor(this.cropMode ? HCBrand.GREEN : HCBrand.RED)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .margin({ right: 8, bottom: 8 })
          .onClick(() => {
            if (this.cropMode) {
              this.applyCrop();
            } else {
              this.cropMode = true;
            }
          })

        Button('添加到画布')
          .fontSize(12)
          .height(30)
          .backgroundColor(HCBrand.INDIGO)
          .fontColor(HCColor.SURFACE)
          .borderRadius(6)
          .onClick(() => {
            this.saveToCanvas();
          })
      }
      .width('100%')
      .padding(12)
      .backgroundColor(HCColor.PAGE_BG)
      .borderRadius(8)
      .margin({ bottom: 12 })

      if (this.hintText.length > 0) {
        Text(this.hintText)
          .fontSize(12)
          .fontColor(HCColor.DANGER)
          .margin({ bottom: 8 })
      }

      // 图片预览区域
      if (this.selectedImage) {
        Stack() {
          // 图片显示
          Image(this.selectedImage)
            .width(300 * this.imageScale)
            .height(300 * this.imageScale)
            .rotate({ angle: this.imageRotation })
            .position({ x: this.imageX, y: this.imageY })
            .interpolation(ImageInterpolation.High)

          // 裁剪区域（裁剪模式下显示）
          if (this.cropMode) {
            Rect()
              .width(this.cropRect.width)
              .height(this.cropRect.height)
              .position({ x: this.cropRect.x, y: this.cropRect.y })
              .fill(Color.Transparent)
              .stroke(HCBrand.RED_PURE)
              .strokeWidth(2)
          }
        }
        .width('100%')
        .height(400)
        .backgroundColor(HCColor.SURFACE)
        .border({ width: 1, color: HCColor.BORDER, radius: 8 })
      } else {
        // 空状态提示
        Column() {
          Text('照')
            .fontSize(48)
            .margin({ bottom: 16 })

          Text('请选择图片或粘贴截图')
            .fontSize(14)
            .fontColor(HCColor.ICON_SECONDARY)
        }
        .width('100%')
        .height(400)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(HCColor.PAGE_BG)
        .border({ width: 1, color: HCColor.BORDER, radius: 8 })
      }

      // 图片信息
      if (this.selectedImage) {
        Column() {
          Text(`缩放: ${(this.imageScale * 100).toFixed(0)}%`)
            .fontSize(12)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ bottom: 4 })

          Text(`旋转: ${this.imageRotation}°`)
            .fontSize(12)
            .fontColor(HCColor.TEXT_TERTIARY)
            .margin({ bottom: 4 })

          Text(`位置: (${this.imageX.toFixed(0)}, ${this.imageY.toFixed(0)})`)
            .fontSize(12)
            .fontColor(HCColor.TEXT_TERTIARY)
        }
        .padding(8)
        .backgroundColor(HCColor.PAGE_BG)
        .borderRadius(8)
        .margin({ top: 12 })
      }
    }
    .width('100%')
    .height('100%')
    .padding(16)
    .backgroundColor(HCColor.SURFACE)
    .borderRadius(14)
    .shadow({ radius: 16, color: HCOverlay.SHADE_20, offsetX: 0, offsetY: 4 })
  }
}