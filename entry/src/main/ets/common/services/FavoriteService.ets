/**
 * FavoriteService.ets — 收藏服务（v2.5 阶段二）
 *
 * 职责：
 *  1. 管理笔记收藏状态的持久化存储；
 *  2. 提供收藏列表的增删改查接口；
 *  3. 使用 Preferences API 进行轻量级数据存储。
 *
 * 设计原则：
 *  - 单例模式，全局唯一实例；
 *  - 异步初始化，不阻塞主线程；
 *  - 提供同步和异步两种接口，适应不同场景。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../Logger';
import { SafeAsync } from '../utils/SafeAsync';

const TAG_MODULE = 'FavoriteService';
const FAVORITES_KEY = 'favorite_note_ids';

/**
 * 收藏服务
 */
export class FavoriteService {
  private static instance: FavoriteService | null = null;
  private preferences: preferences.Preferences | null = null;
  private favoriteIds: Set<string> = new Set<string>();
  private ready: boolean = false;
  
  private constructor() {}
  
  /**
   * 获取单例实例
   */
  static getInstance(): FavoriteService {
    if (!FavoriteService.instance) {
      FavoriteService.instance = new FavoriteService();
    }
    return FavoriteService.instance;
  }
  
  /**
   * 初始化服务（异步）
   * @param context 应用上下文
   */
  async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      // 获取 Preferences 实例
      this.preferences = await preferences.getPreferences(context, 'harmonycanvas_favorites');
      
      // 加载收藏列表
      const idsJson = await this.preferences.get(FAVORITES_KEY, '[]') as string;
      const ids: string[] = JSON.parse(idsJson);
      
      this.favoriteIds = new Set<string>(ids);
      this.ready = true;
      
      Logger.info(TAG_MODULE, `initialize: 加载收藏列表成功，共 ${this.favoriteIds.size} 个收藏`);
    } catch (error) {
      Logger.error(TAG_MODULE, `initialize: 初始化失败 - ${error}`);
      this.ready = false;
    }
  }
  
  /**
   * 服务是否就绪
   */
  isReady(): boolean {
    return this.ready;
  }
  
  /**
   * 获取所有收藏的笔记ID（同步）
   */
  getAllFavoriteIds(): Set<string> {
    return new Set<string>(this.favoriteIds);
  }
  
  /**
   * 检查笔记是否已收藏（同步）
   * @param noteId 笔记ID
   */
  isFavorite(noteId: string): boolean {
    return this.favoriteIds.has(noteId);
  }
  
  /**
   * 添加收藏（异步）
   * @param noteId 笔记ID
   */
  async addFavorite(noteId: string): Promise<boolean> {
    if (!this.ready || !this.preferences) {
      Logger.warn(TAG_MODULE, 'addFavorite: 服务未就绪');
      return false;
    }
    
    if (this.favoriteIds.has(noteId)) {
      Logger.debug(TAG_MODULE, `addFavorite: 笔记 ${noteId} 已收藏`);
      return true;
    }
    
    try {
      // 更新内存状态
      this.favoriteIds.add(noteId);
      
      // 持久化到存储
      await this.saveToStorage();
      
      Logger.info(TAG_MODULE, `addFavorite: 收藏笔记 ${noteId} 成功`);
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `addFavorite: 收藏失败 - ${error}`);
      // 回滚内存状态
      this.favoriteIds.delete(noteId);
      return false;
    }
  }
  
  /**
   * 取消收藏（异步）
   * @param noteId 笔记ID
   */
  async removeFavorite(noteId: string): Promise<boolean> {
    if (!this.ready || !this.preferences) {
      Logger.warn(TAG_MODULE, 'removeFavorite: 服务未就绪');
      return false;
    }
    
    if (!this.favoriteIds.has(noteId)) {
      Logger.debug(TAG_MODULE, `removeFavorite: 笔记 ${noteId} 未收藏`);
      return true;
    }
    
    try {
      // 更新内存状态
      this.favoriteIds.delete(noteId);
      
      // 持久化到存储
      await this.saveToStorage();
      
      Logger.info(TAG_MODULE, `removeFavorite: 取消收藏笔记 ${noteId} 成功`);
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `removeFavorite: 取消收藏失败 - ${error}`);
      // 回滚内存状态
      this.favoriteIds.add(noteId);
      return false;
    }
  }
  
  /**
   * 切换收藏状态（异步）
   * @param noteId 笔记ID
   * @returns 切换后的收藏状态
   */
  async toggleFavorite(noteId: string): Promise<boolean> {
    if (this.favoriteIds.has(noteId)) {
      const success = await this.removeFavorite(noteId);
      return !success; // 取消收藏后返回 false
    } else {
      const success = await this.addFavorite(noteId);
      return success; // 添加收藏后返回 true
    }
  }
  
  /**
   * 批量设置收藏（异步）
   * @param noteIds 笔记ID数组
   */
  async setFavorites(noteIds: string[]): Promise<boolean> {
    if (!this.ready || !this.preferences) {
      Logger.warn(TAG_MODULE, 'setFavorites: 服务未就绪');
      return false;
    }
    
    try {
      // 更新内存状态
      this.favoriteIds = new Set<string>(noteIds);
      
      // 持久化到存储
      await this.saveToStorage();
      
      Logger.info(TAG_MODULE, `setFavorites: 批量设置收藏成功，共 ${this.favoriteIds.size} 个`);
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `setFavorites: 批量设置失败 - ${error}`);
      return false;
    }
  }
  
  /**
   * 清空所有收藏（异步）
   */
  async clearAll(): Promise<boolean> {
    if (!this.ready || !this.preferences) {
      Logger.warn(TAG_MODULE, 'clearAll: 服务未就绪');
      return false;
    }
    
    try {
      // 更新内存状态
      this.favoriteIds.clear();
      
      // 持久化到存储
      await this.saveToStorage();
      
      Logger.info(TAG_MODULE, 'clearAll: 清空所有收藏成功');
      return true;
    } catch (error) {
      Logger.error(TAG_MODULE, `clearAll: 清空失败 - ${error}`);
      return false;
    }
  }
  
  /**
   * 获取收藏数量
   */
  getFavoriteCount(): number {
    return this.favoriteIds.size;
  }
  
  /**
   * 保存到存储（私有方法）
   */
  private async saveToStorage(): Promise<void> {
    if (!this.preferences) {
      throw new Error('Preferences 未初始化');
    }
    
    const ids: string[] = Array.from(this.favoriteIds);
    const idsJson: string = JSON.stringify(ids);
    
    await this.preferences.put(FAVORITES_KEY, idsJson);
    await this.preferences.flush();
    
    Logger.debug(TAG_MODULE, `saveToStorage: 保存收藏列表成功，共 ${ids.length} 个`);
  }
}

/**
 * 全局单例导出
 */
export const favoriteService = FavoriteService.getInstance();
