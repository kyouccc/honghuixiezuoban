import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;

export class Logger {
  static debug(tag: string, msg: string): void {
    hilog.debug(DOMAIN, tag, msg);
  }

  static info(tag: string, msg: string): void {
    hilog.info(DOMAIN, tag, msg);
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, msg);
  }

  static error(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, msg);
  }

  /** 性能打点 */
  static perf(tag: string, operation: string, durationMs: number): void {
    hilog.info(DOMAIN, `[PERF] ${tag}`, `${operation}: ${durationMs}ms`);
  }
}
