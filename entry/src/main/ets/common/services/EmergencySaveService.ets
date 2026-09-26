/**
 * EmergencySaveService.ets - 紧急保存服务（F-04 崩溃兜底）
 * 
 * 功能：
 * 1. 定期紧急保存笔记内容
 * 2. 监听系统低内存警告
 * 3. 提供紧急保存接口
 */

import { CrashRecoveryService, crashRecoveryService, CrashRecoveryData } from './CrashRecoveryService';
import { NoteContent } from '../../engine/types/NoteModel';
import { Logger } from '../Logger';

export class EmergencySaveService {
  private static instance: EmergencySaveService;
  private readonly TAG = 'EmergencySaveService';
  
  // 紧急保存定时器
  private emergencySaveTimer: number = -1;
  
  // 紧急保存间隔（毫秒）
  private readonly EMERGENCY_SAVE_INTERVAL = 30000; // 30秒
  
  // 当前编辑的笔记信息
  private currentNoteId: string = '';
  private currentTitle: string = '';
  private currentContent: NoteContent | null = null;
  
  // 获取内容的回调
  private getContentCallback: (() => NoteContent) | null = null;
  
  private constructor() {}
  
  static getInstance(): EmergencySaveService {
    if (!EmergencySaveService.instance) {
      EmergencySaveService.instance = new EmergencySaveService();
    }
    return EmergencySaveService.instance;
  }
  
  /**
   * 设置当前编辑的笔记信息
   */
  setCurrentNote(noteId: string, title: string): void {
    this.currentNoteId = noteId;
    this.currentTitle = title;
  }
  
  /**
   * 设置获取内容的回调
   */
  setGetContentCallback(callback: () => NoteContent): void {
    this.getContentCallback = callback;
  }
  
  /**
   * 启动紧急保存定时器
   */
  startEmergencySave(): void {
    // 清除之前的定时器
    this.stopEmergencySave();
    
    // 设置新的定时器
    this.emergencySaveTimer = setInterval(() => {
      this.emergencySave();
    }, this.EMERGENCY_SAVE_INTERVAL);
    
    Logger.info(this.TAG, '启动紧急保存定时器，间隔=' + this.EMERGENCY_SAVE_INTERVAL + 'ms');
  }
  
  /**
   * 停止紧急保存定时器
   */
  stopEmergencySave(): void {
    if (this.emergencySaveTimer !== -1) {
      clearInterval(this.emergencySaveTimer);
      this.emergencySaveTimer = -1;
      Logger.info(this.TAG, '停止紧急保存定时器');
    }
  }
  
  /**
   * 紧急保存
   */
  async emergencySave(): Promise<void> {
    if (!this.currentNoteId || !this.getContentCallback) {
      return;
    }
    
    try {
      // 获取当前内容
      const content = this.getContentCallback();
      
      // 保存恢复数据
      const recoveryData: CrashRecoveryData = {
        noteId: this.currentNoteId,
        title: this.currentTitle,
        content: content,
        timestamp: Date.now(),
        isEmergency: true
      };
      
      await crashRecoveryService.saveRecoveryData(recoveryData);
      
      Logger.info(this.TAG, '紧急保存成功: noteId=' + this.currentNoteId);
    } catch (error) {
      Logger.error(this.TAG, '紧急保存失败: ' + JSON.stringify(error));
    }
  }
  
  /**
   * 手动触发紧急保存
   */
  async triggerEmergencySave(): Promise<void> {
    await this.emergencySave();
  }
  
  /**
   * 处理低内存警告
   */
  async handleLowMemory(): Promise<void> {
    Logger.warn(this.TAG, '收到低内存警告，执行紧急保存');
    await this.emergencySave();
  }
  
  /**
   * 清理资源
   */
  cleanup(): void {
    this.stopEmergencySave();
    this.currentNoteId = '';
    this.currentTitle = '';
    this.currentContent = null;
    this.getContentCallback = null;
  }
}

// 导出单例便捷方法
export const emergencySaveService = EmergencySaveService.getInstance();
