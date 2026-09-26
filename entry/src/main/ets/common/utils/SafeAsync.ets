/**
 * SafeAsync.ets — 通用安全执行工具（v2.3 稳定性增量）
 *
 * 用途：
 *  统一包裹「可能抛异常 / 可能永不 resolve」的调用，避免单点异常导致
 *  页面白屏、Promise 悬挂、后台定时器泄漏。
 *
 * 输入：
 *  tag        调用方模块名（hilog TAG）
 *  operation  操作名（用于错误日志定位）
 *  action     待执行的同步 / 异步动作
 *  fallback   同步执行失败时的兜底返回值
 *  onError    可选失败回调（页面可用于把错误落到 UI 状态栏）
 *
 * 输出：
 *  同步：动作返回值或 fallback；异步：Promise<boolean>（超时/异常均 resolve(false)，绝不 reject）
 *
 * 注意事项：
 *  1. 本模块为纯逻辑模块，只依赖 common/Logger（hilog），不引入 @kit.* 重依赖；
 *  2. 所有方法均不会向外抛异常——调用方无需再包 try-catch；
 *  3. 错误日志同时落到 hilog 与内存环形缓冲（getRecentErrors），便于 QA 现场取证。
 */

import { Logger } from '../Logger';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG_MODULE = 'SafeAsync';

/** 内存错误缓冲上限（环形覆盖，防止长时间运行内存增长） */
const MAX_ERROR_RECORDS: number = 50;

/** 结构化错误信息 */
export interface SafeErrorInfo {
  tag: string;
  operation: string;
  message: string;
  timestamp: number;
  /** 系统错误码（对应 BusinessError.code / errno）；非 BusinessError 时为 undefined（T2-1b C-1） */
  code?: number;
}

/** 失败回调签名 */
export type SafeErrorHandler = (info: SafeErrorInfo) => void;

/**
 * 失败分类（T2-1b C-1 / d1 §10.2）：
 * 用户面对这三类能采取不同行动的最小集合——清空间 / 查权限 / 单纯重试。
 * 映射不到已知 errno 时必须落 'unknown' 且照常报错，绝不允许静默吞掉（D-1 教训）。
 */
export type FsFailureKind = 'no_space' | 'no_permission' | 'unknown';

/** runDetailed 结果：成功 value=action()、error=null；失败 value=fallback、error=带 code 的 SafeErrorInfo */
export interface DetailedResult<T> {
  value: T;
  error: SafeErrorInfo | null;
}

/** 仅含 code 的结构化类型（用于从 Error 中安全提取 BusinessError.code，避免引入 @kit.* 依赖） */
interface HasCode {
  code: number;
}

/** Linux errno 常量（OpenHarmony 为 Linux 内核，BusinessError.code 即 errno；供 classifyFsError 映射） */
const ERRNO_ENOSPC: number = 28;
const ERRNO_EDQUOT: number = 122;
const ERRNO_EACCES: number = 13;
const ERRNO_EPERM: number = 1;
const ERRNO_EROFS: number = 30;

/**
 * 按系统错误码分类失败（T2-1b C-1 / d1 §10.2.4）。
 * @param code BusinessError.code / errno；undefined（非 BusinessError）归类为 'unknown'
 * @returns 'no_space' | 'no_permission' | 'unknown'。任何返回值都代表失败，调用方必须照常报错。
 */
export function classifyFsError(code: number | undefined): FsFailureKind {
  if (code === ERRNO_ENOSPC || code === ERRNO_EDQUOT) {
    return 'no_space';
  }
  if (code === ERRNO_EACCES || code === ERRNO_EPERM || code === ERRNO_EROFS) {
    return 'no_permission';
  }
  return 'unknown';
}

export class SafeAsync {
  /** 最近错误环形缓冲（最多 MAX_ERROR_RECORDS 条） */
  private static errorLog: SafeErrorInfo[] = [];

  /**
   * 把捕获到的异常对象转为可读字符串（永不抛异常）。
   */
  /**
   * 把任意抛出物转成可读字符串。
   *
   * 🔧 v2.7.0 审核修复（问题①-3「加入房间失败」显示 `[object Object]`）：
   *   鸿蒙抛出的 `BusinessError` 是**普通对象**（不是 `Error` 实例），
   *   原实现 `err instanceof Error ? err.message : String(err)` 会走到
   *   `String(obj)` 分支 → 得到字面量 "[object Object]" 并直接显示给用户。
   *   现在统一走本方法：优先 `message`，其次 `code`，再退 JSON，最后兜底中文文案，
   *   **绝不返回 "[object Object]"**。
   */
  static describe(err: Error): string {
    if (err === null || err === undefined) {
      return '未知错误';
    }
    let message: string = '';
    try {
      const be: BusinessError = err as BusinessError;
      const rawMsg: string | undefined = be.message;
      if (rawMsg !== undefined && rawMsg !== null && `${rawMsg}`.length > 0 && `${rawMsg}` !== '[object Object]') {
        message = `${rawMsg}`;
      }
      if (message.length === 0) {
        const rawCode: number | undefined = be.code;
        if (rawCode !== undefined && rawCode !== null) {
          message = `错误码 ${rawCode}`;
        }
      }
    } catch (_e) { /* 读取失败则走后续兜底 */ }

    if (message.length > 0) {
      return message;
    }
    try {
      const s: string = JSON.stringify(err);
      if (s !== undefined && s !== null && s.length > 0 && s !== '{}' && s !== '[object Object]') {
        return s;
      }
    } catch (_e2) { /* 不可序列化 */ }
    return '未知错误';
  }

  /**
   * 从捕获异常中安全提取系统错误码（BusinessError.code / errno）。
   * 非对象 / 无 code 字段 / code 非数字一律返回 undefined，绝不抛新异常（d1 §10.2.2）。
   */
  static extractCode(err: Error): number | undefined {
    if (err === null || err === undefined || typeof err !== 'object') {
      return undefined;
    }
    // ArkTS 不支持 in 运算符，尝试直接访问 code 属性
    // BusinessError 继承自 Error，包含 code 属性
    const businessError: BusinessError = err as BusinessError;
    if (businessError.code !== undefined && businessError.code !== null) {
      return typeof businessError.code === 'number' ? businessError.code : undefined;
    }
    return undefined;
  }

  /**
   * 安全执行同步动作，异常时返回 fallback。
   * @param tag       模块名
   * @param operation 操作名
   * @param action    同步动作
   * @param fallback  失败兜底值
   * @param onError   可选失败回调
   */
  static run<T>(tag: string, operation: string, action: () => T, fallback: T, onError?: SafeErrorHandler): T {
    try {
      return action();
    } catch (err) {
      SafeAsync.record(tag, operation, SafeAsync.describe(err as Error), onError, SafeAsync.extractCode(err as Error));
      return fallback;
    }
  }

  /**
   * 安全执行同步动作并回传结构化错误（T2-1b C-1 / d1 §10.2.3）。
   * 与 run 的区别：失败时返回 { value: fallback, error: 带 code 的 SafeErrorInfo }，
   * 供写入链（writeTextSync / copySync / renameSync）做失败分类（classifyFsError）。
   * 既有 run / runVoid / runAsyncVoid / withTimeout 签名与行为完全不变（纯增量）。
   */
  static runDetailed<T>(tag: string, operation: string, action: () => T, fallback: T,
                        onError?: SafeErrorHandler): DetailedResult<T> {
    try {
      return { value: action(), error: null };
    } catch (err) {
      const info: SafeErrorInfo = SafeAsync.record(tag, operation, SafeAsync.describe(err as Error), onError,
        SafeAsync.extractCode(err as Error));
      return { value: fallback, error: info };
    }
  }

  /**
   * 安全执行无返回值的同步动作。
   * @returns true=执行成功，false=已捕获异常
   */
  static runVoid(tag: string, operation: string, action: () => void, onError?: SafeErrorHandler): boolean {
    try {
      action();
      return true;
    } catch (err) {
      SafeAsync.record(tag, operation, SafeAsync.describe(err as Error), onError, SafeAsync.extractCode(err as Error));
      return false;
    }
  }

  /**
   * 安全执行异步动作（fire-and-forget）：吞掉 reject，避免未处理的 Promise 异常。
   */
  static runAsyncVoid(tag: string, operation: string, action: () => Promise<void>, onError?: SafeErrorHandler): void {
    try {
      action()
        .then(() => {
          // 正常完成，无需处理
        })
        .catch((err: Error) => {
          SafeAsync.record(tag, operation, SafeAsync.describe(err), onError, SafeAsync.extractCode(err));
        });
    } catch (err) {
      SafeAsync.record(tag, operation, SafeAsync.describe(err as Error), onError, SafeAsync.extractCode(err as Error));
    }
  }

  /**
   * 给「可能永不 resolve」的异步动作加超时保护（如 WebSocket connect）。
   * 超时 / 异常一律 resolve(false)，调用方 UI 不会卡在 loading 态。
   *
   * @param timeoutMs 超时毫秒（<=0 时视为 1000ms）
   */
  static withTimeout(tag: string, operation: string, action: () => Promise<boolean>, timeoutMs: number,
                     onError?: SafeErrorHandler): Promise<boolean> {
    const effectiveTimeout: number = timeoutMs > 0 ? timeoutMs : 1000;
    return new Promise<boolean>((resolve: (value: boolean) => void) => {
      let settled: boolean = false;
      let timer: number = -1;
      const settle = (value: boolean): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timer !== -1) {
          clearTimeout(timer);
          timer = -1;
        }
        resolve(value);
      };

      timer = setTimeout(() => {
        SafeAsync.record(tag, operation, `timeout after ${effectiveTimeout}ms`, onError);
        settle(false);
      }, effectiveTimeout);

      try {
        action()
          .then((ok: boolean) => {
            settle(ok);
          })
          .catch((err: Error) => {
            SafeAsync.record(tag, operation, SafeAsync.describe(err), onError, SafeAsync.extractCode(err));
            settle(false);
          });
      } catch (err) {
        SafeAsync.record(tag, operation, SafeAsync.describe(err as Error), onError, SafeAsync.extractCode(err as Error));
        settle(false);
      }
    });
  }

  /** 最近错误列表（副本，QA 现场取证用） */
  static getRecentErrors(): SafeErrorInfo[] {
    return SafeAsync.errorLog.slice();
  }

  /** 最近一条错误（无错误返回 null） */
  static getLastError(): SafeErrorInfo | null {
    const size: number = SafeAsync.errorLog.length;
    return size > 0 ? SafeAsync.errorLog[size - 1] : null;
  }

  /** 清空错误缓冲 */
  static clear(): void {
    SafeAsync.errorLog = [];
  }

  // ─── 内部 ───

  /** 记录错误：hilog + 内存环形缓冲 + 可选回调 */
  private static record(tag: string, operation: string, message: string, onError?: SafeErrorHandler,
                        errCode?: number): SafeErrorInfo {
    const info: SafeErrorInfo = {
      tag: tag,
      operation: operation,
      message: message,
      timestamp: Date.now(),
      code: errCode
    };
    Logger.error(tag.length > 0 ? tag : TAG_MODULE, `[${operation}] ${message}`);
    SafeAsync.errorLog.push(info);
    if (SafeAsync.errorLog.length > MAX_ERROR_RECORDS) {
      SafeAsync.errorLog.shift();
    }
    if (onError !== undefined) {
      try {
        onError(info);
      } catch (_) {
        Logger.warn(TAG_MODULE, 'onError handler threw, ignored');
      }
    }
    return info;
  }
}
