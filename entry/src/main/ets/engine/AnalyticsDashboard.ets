/**
 * AnalyticsDashboard.ets — 统计/分析（P2 扩展）
 *
 * 提供笔记使用统计、学习时长分析、笔记活跃度等功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'AnalyticsDashboard';

export interface AnalyticsEvent {
  eventType: string;
  noteId: string;
  timestamp: number;
  data: string;
}

export interface DailyStats {
  date: string;
  strokeCount: number;
  noteCount: number;
  activeMinutes: number;
}

export class AnalyticsDashboard {
  private static instance: AnalyticsDashboard;
  private events: AnalyticsEvent[] = [];
  private dailyStats: DailyStats[] = [];

  static getInstance(): AnalyticsDashboard {
    if (!AnalyticsDashboard.instance) {
      AnalyticsDashboard.instance = new AnalyticsDashboard();
    }
    return AnalyticsDashboard.instance;
  }

  trackEvent(eventType: string, noteId: string, data: string): void {
    const event: AnalyticsEvent = {
      eventType: eventType,
      noteId: noteId,
      timestamp: Date.now(),
      data: data
    };
    this.events.push(event);
  }

  getEvents(noteId: string): AnalyticsEvent[] {
    return this.events.filter(e => e.noteId === noteId);
  }

  getDailyStats(days: number): DailyStats[] {
    return this.dailyStats.slice(0, days);
  }

  recordDaily(date: string, strokeCount: number, noteCount: number, activeMinutes: number): void {
    const stats: DailyStats = {
      date: date,
      strokeCount: strokeCount,
      noteCount: noteCount,
      activeMinutes: activeMinutes
    };
    this.dailyStats.unshift(stats);
    if (this.dailyStats.length > 365) {
      this.dailyStats = this.dailyStats.slice(0, 365);
    }
  }

  getTotalNotes(): number {
    return this.dailyStats.reduce((sum, s) => sum + s.noteCount, 0);
  }

  getTotalStrokes(): number {
    return this.dailyStats.reduce((sum, s) => sum + s.strokeCount, 0);
  }

  getTotalActiveMinutes(): number {
    return this.dailyStats.reduce((sum, s) => sum + s.activeMinutes, 0);
  }

  /** 结束分析会话 */
  endSession(): void {
    this.trackEvent('session_end', 'global', 'session_ended');
    Logger.info(TAG, 'Analytics session ended');
  }
}
