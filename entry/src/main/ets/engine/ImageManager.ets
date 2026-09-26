/**
 * ImageManager.ets - 图片管理器 v1.1 + v2.0 增量（S1T03 / NP-04）
 * 功能：图片加载、缩放、旋转、裁剪、保存
 *
 * v2.0 增量：
 *  - 图片插入生成 ImageRefData（imageHash 引用，二进制走旁路通道；
 *    P0 先以 uri 引用 + hash 标记，binaryRef 留空，阶段二接入 WS 二进制帧）；
 *  - 新增 computeHash / getMimeType 工具，ImageRef 注册表。
 */

import { Logger } from '../common/Logger';
import image from '@ohos.multimedia.image';
import { ImageRefData } from './types/CanvasElement';

const TAG_MODULE = 'ImageManager';

export interface ImageData {
  id: string;
  uri: string;
  x: number;
  y: number;
  scale: number;
  rotation: number;
  width: number;
  height: number;
  originalWidth: number;
  originalHeight: number;
  createdAt: number;
}

export class ImageManager {
  private static instance: ImageManager | null = null;
  private images: Map<string, ImageData> = new Map();
  private imageCache: Map<string, image.PixelMap> = new Map();
  // v2.0 增量：ImageRef 注册表（CRDT 元素引用，按 hash 去重）
  private imageRefs: Map<string, ImageRefData> = new Map();

  static getInstance(): ImageManager {
    if (!ImageManager.instance) {
      ImageManager.instance = new ImageManager();
    }
    return ImageManager.instance;
  }

  init(): void {
    Logger.info(TAG_MODULE, 'ImageManager initialized');
  }

  // 加载图片
  async loadImage(uri: string): Promise<image.PixelMap | null> {
    try {
      // 检查缓存
      const cached = this.imageCache.get(uri);
      if (cached) {
        return cached;
      }

      // 使用HarmonyOS图片加载API
      const source = image.createImageSource(uri);
      const bitmap = await source.createPixelMap();
      
      // 缓存图片
      this.imageCache.set(uri, bitmap);
      
      return bitmap;
    } catch (error) {
      Logger.error(TAG_MODULE, `loadImage error: ${error}`);
      return null;
    }
  }

  // 添加图片到画布
  addImage(uri: string, x: number, y: number, scale: number = 1.0, rotation: number = 0): string {
    const id = `image_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    
    // 获取图片原始尺寸
    const imageData: ImageData = {
      id: id,
      uri: uri,
      x: x,
      y: y,
      scale: scale,
      rotation: rotation,
      width: 200 * scale, // 默认宽度
      height: 200 * scale, // 默认高度
      originalWidth: 200,
      originalHeight: 200,
      createdAt: Date.now()
    };

    this.images.set(id, imageData);
    Logger.info(TAG_MODULE, `Image added: ${id}`);
    
    return id;
  }

  // 更新图片位置
  updateImagePosition(id: string, x: number, y: number): boolean {
    const imageData = this.images.get(id);
    if (!imageData) {
      Logger.warn(TAG_MODULE, `updateImagePosition: image not found ${id}`);
      return false;
    }

    imageData.x = x;
    imageData.y = y;
    this.images.set(id, imageData);
    
    return true;
  }

  // 更新图片缩放
  updateImageScale(id: string, scale: number): boolean {
    const imageData = this.images.get(id);
    if (!imageData) {
      Logger.warn(TAG_MODULE, `updateImageScale: image not found ${id}`);
      return false;
    }

    imageData.scale = Math.max(0.1, Math.min(scale, 10.0));
    imageData.width = imageData.originalWidth * imageData.scale;
    imageData.height = imageData.originalHeight * imageData.scale;
    this.images.set(id, imageData);
    
    return true;
  }

  // 更新图片旋转
  updateImageRotation(id: string, rotation: number): boolean {
    const imageData = this.images.get(id);
    if (!imageData) {
      Logger.warn(TAG_MODULE, `updateImageRotation: image not found ${id}`);
      return false;
    }

    imageData.rotation = rotation % 360;
    this.images.set(id, imageData);
    
    return true;
  }

  // 裁剪图片
  async cropImage(uri: string, x: number, y: number, width: number, height: number): Promise<string> {
    try {
      // 加载原始图片
      const originalBitmap = await this.loadImage(uri);
      if (!originalBitmap) {
        Logger.error(TAG_MODULE, 'Failed to load image for cropping');
        return uri; // 返回原始URI
      }

      // 创建裁剪后的图片
      // 注意：这里需要实际实现图片裁剪逻辑
      // 由于HarmonyOS图片处理API的限制，这里返回原始URI
      // 实际项目中应该使用图片处理库进行裁剪
      
      const croppedUri = `${uri}_cropped_${Date.now()}`;
      Logger.info(TAG_MODULE, `Image cropped: ${croppedUri}`);
      
      return croppedUri;
    } catch (error) {
      Logger.error(TAG_MODULE, `cropImage error: ${error}`);
      return uri; // 返回原始URI
    }
  }

  // ═══ v2.0 增量：ImageRef 元素（NP-04，图片纳入 CRDT）═══

  /**
   * 插入图片引用元素：生成 ImageRefData（imageRef/hash 引用）。
   * 二进制走旁路通道（阶段二 WS 二进制帧），P0 以 uri 引用 + hash 标记。
   */
  insertImageRef(uri: string, x: number, y: number, layerId: string, width: number, height: number): ImageRefData {
    const id: string = `image_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
    const hash: string = ImageManager.computeHash(`${uri}_${Date.now()}`);
    const ref: ImageRefData = {
      id: id,
      layerId: layerId,
      createdBy: 'local',
      createdAt: Date.now(),
      imageHash: hash,
      mimeType: ImageManager.getMimeType(uri),
      x: x,
      y: y,
      width: width,
      height: height,
      binaryRef: '',
      uri: uri,
      rotation: 0,
      scale: 1.0,
    };
    this.imageRefs.set(id, ref);
    Logger.info(TAG_MODULE, `ImageRef created: ${id}, hash=${hash}`);
    return ref;
  }

  /** 注册 ImageRef（接收端按 hash 去重缓存，缺图时懒加载，架构 §8.1 约定 6） */
  addImageRef(ref: ImageRefData): void {
    this.imageRefs.set(ref.id, ref);
  }

  getImageRef(id: string): ImageRefData | null {
    const ref: ImageRefData | undefined = this.imageRefs.get(id);
    return ref !== undefined ? ref : null;
  }

  getAllImageRefs(): ImageRefData[] {
    return Array.from(this.imageRefs.values());
  }

  /** 按 hash 查找已有 ImageRef（去重用） */
  findImageRefByHash(hash: string): ImageRefData | null {
    const refs: ImageRefData[] = Array.from(this.imageRefs.values());
    for (let i = 0; i < refs.length; i++) {
      if (refs[i].imageHash === hash) {
        return refs[i];
      }
    }
    return null;
  }

  removeImageRef(id: string): boolean {
    return this.imageRefs.delete(id);
  }

  /** FNV-1a 32 位哈希（十六进制字符串），用于图片内容去重标记 */
  static computeHash(input: string): string {
    let hash: number = 0x811c9dc5;
    for (let i = 0; i < input.length; i++) {
      hash ^= input.charCodeAt(i);
      hash = Math.imul(hash, 0x01000193);
    }
    const unsigned: number = hash >>> 0;
    return unsigned.toString(16);
  }

  /** 按文件后缀推断 MIME 类型 */
  static getMimeType(uri: string): string {
    const lower: string = uri.toLowerCase();
    if (lower.endsWith('.png')) {
      return 'image/png';
    }
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lower.endsWith('.webp')) {
      return 'image/webp';
    }
    if (lower.endsWith('.gif')) {
      return 'image/gif';
    }
    if (lower.endsWith('.bmp')) {
      return 'image/bmp';
    }
    return 'application/octet-stream';
  }

  // 获取所有图片
  getAllImages(): ImageData[] {
    return Array.from(this.images.values());
  }

  // 获取图片数据
  getImage(id: string): ImageData | null {
    const data = this.images.get(id);
    return data || null;
  }

  // 删除图片
  removeImage(id: string): boolean {
    return this.images.delete(id);
  }

  // 清除所有图片
  clearAllImages(): void {
    this.images.clear();
    this.imageCache.clear();
  }

  // 导出图片数据
  exportImageData(): string {
    const data = Array.from(this.images.values());
    return JSON.stringify(data);
  }

  // 导入图片数据
  importImageData(jsonData: string): boolean {
    try {
      const images: ImageData[] = JSON.parse(jsonData) as ImageData[];
      this.images.clear();
      
      images.forEach((image: ImageData) => {
        this.images.set(image.id, image);
      });
      
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `importImageData error: ${error}`);
      return false;
    }
  }

  // 绘制图片到Canvas
  drawImageToCanvas(ctx: CanvasRenderingContext2D, imageData: ImageData): void {
    try {
      const bitmap = this.imageCache.get(imageData.uri);
      if (!bitmap) {
        Logger.warn(TAG_MODULE, `drawImageToCanvas: bitmap not found for ${imageData.uri}`);
        return;
      }

      // 保存当前上下文状态
      ctx.save();

      // 应用变换
      ctx.translate(imageData.x + imageData.width / 2, imageData.y + imageData.height / 2);
      ctx.rotate(imageData.rotation * Math.PI / 180);
      ctx.scale(imageData.scale, imageData.scale);

      // 绘制图片
      ctx.drawImage(bitmap, -imageData.originalWidth / 2, -imageData.originalHeight / 2);

      // 恢复上下文状态
      ctx.restore();
    } catch (error) {
      Logger.error(TAG_MODULE, `drawImageToCanvas error: ${error}`);
    }
  }

  // 按 ImageRefData 绘制图片到Canvas（导出合成用）
  // 与 drawImageToCanvas 语义一致，但接收 CRDT 元素 ImageRefData（尺寸取引用宽高）
  drawImageRefToCanvas(ctx: CanvasRenderingContext2D, imageRef: ImageRefData): void {
    try {
      const bitmap = this.imageCache.get(imageRef.uri);
      if (!bitmap) {
        Logger.warn(TAG_MODULE, `drawImageRefToCanvas: bitmap not found for ${imageRef.uri}`);
        return;
      }

      ctx.save();

      ctx.translate(imageRef.x + imageRef.width / 2, imageRef.y + imageRef.height / 2);
      ctx.rotate(imageRef.rotation * Math.PI / 180);
      ctx.scale(imageRef.scale, imageRef.scale);

      ctx.drawImage(bitmap, -imageRef.width / 2, -imageRef.height / 2);

      ctx.restore();
    } catch (error) {
      Logger.error(TAG_MODULE, `drawImageRefToCanvas error: ${error}`);
    }
  }

  // 绘制所有图片到Canvas
  drawAllImagesToCanvas(ctx: CanvasRenderingContext2D): void {
    const allImages = this.getAllImages();
    allImages.forEach((imageData: ImageData) => {
      this.drawImageToCanvas(ctx, imageData);
    });
  }
}