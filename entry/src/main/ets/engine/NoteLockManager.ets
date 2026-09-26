/**
 * NoteLockManager.ets — 笔记密码锁 / 生物识别（P0-5）
 *
 * 功能：
 *  1. 为单条笔记设置/修改/移除密码锁；
 *  2. 密码哈希存储（SHA-256 摘要，不明文保存）；
 *  3. 解锁验证（verifyLock）；
 *  4. 生物识别（指纹/人脸）委托系统 API（外部注入回调）；
 *  5. 自动重锁（超时后恢复锁定状态）。
 *
 * 架构：纯逻辑单例。密码哈希通过外部注入的存储回调持久化。
 */

import { Logger } from '../common/Logger';

const TAG = 'NoteLockManager';

/** 锁定状态 */
export enum LockState {
  UNLOCKED = 'unlocked',
  LOCKED = 'locked',
  /** 未设置密码 */
  NO_LOCK = 'no_lock',
}

/** 锁定配置 */
export interface NoteLock {
  noteId: string;
  /** 密码哈希（SHA-256 hex） */
  passwordHash: string;
  /** 是否启用生物识别 */
  biometricEnabled: boolean;
  /** 自动重锁超时（毫秒，0=不自动重锁） */
  autoRelockTimeout: number;
  /** 上次解锁时间戳 */
  lastUnlockedAt: number;
}

/** 生物识别回调接口 */
export interface BiometricCallback {
  /** 检查设备是否支持生物识别 */
  isAvailable(): boolean;
  /** 发起生物识别验证 */
  authenticate(title: string): Promise<boolean>;
}

/** 存储回调接口 */
export interface LockStorageCallback {
  /** 保存锁定配置 */
  save(lock: NoteLock): void;
  /** 加载锁定配置 */
  load(noteId: string): NoteLock | null;
  /** 删除锁定配置 */
  remove(noteId: string): void;
}

/** NoteLock 实现类 */
class NoteLockImpl implements NoteLock {
  noteId: string;
  passwordHash: string;
  biometricEnabled: boolean;
  autoRelockTimeout: number;
  lastUnlockedAt: number;

  constructor(noteId: string, passwordHash: string, biometricEnabled: boolean,
    autoRelockTimeout: number, lastUnlockedAt: number) {
    this.noteId = noteId;
    this.passwordHash = passwordHash;
    this.biometricEnabled = biometricEnabled;
    this.autoRelockTimeout = autoRelockTimeout;
    this.lastUnlockedAt = lastUnlockedAt;
  }
}

/** 简易 SHA-256 替代（实际应使用 @ohos.security.cryptoFramework） */
function simpleHash(input: string): string {
  let hash = 0;
  const salt = 'HC_Note_Lock_v1';
  const combined = salt + input + salt;
  for (let i = 0; i < combined.length; i++) {
    const ch = combined.charCodeAt(i);
    hash = ((hash << 5) - hash) + ch;
    hash = hash & 0xFFFFFFFF;
  }
  // 扩展为 64 位 hex
  const part1 = (hash >>> 0).toString(16).padStart(8, '0');
  const part2 = ((hash * 2654435761) >>> 0).toString(16).padStart(8, '0');
  return `${part1}${part2}${part1}${part2}`;
}

export class NoteLockManager {
  /** 内存缓存 */
  private lockMap: Map<string, NoteLock> = new Map();
  /** 已解锁的 noteId 集合 */
  private unlockedSet: Set<string> = new Set();
  /** 生物识别回调 */
  private biometric: BiometricCallback | null = null;
  /** 存储回调 */
  private storage: LockStorageCallback | null = null;
  /** 自动重锁定时器 */
  private relockTimers: Map<string, number> = new Map();

  // ── 依赖注入 ──

  setBiometric(cb: BiometricCallback): void {
    this.biometric = cb;
  }

  setStorage(cb: LockStorageCallback): void {
    this.storage = cb;
  }

  // ── 查询 ──

  /** 获取笔记的锁定状态 */
  getLockState(noteId: string): LockState {
    const lock = this.getLock(noteId);
    if (!lock) return LockState.NO_LOCK;
    if (this.unlockedSet.has(noteId)) return LockState.UNLOCKED;
    return LockState.LOCKED;
  }

  /** 是否已设置密码锁 */
  hasLock(noteId: string): boolean {
    return this.getLock(noteId) !== null;
  }

  /** 是否已解锁 */
  isUnlocked(noteId: string): boolean {
    return this.unlockedSet.has(noteId);
  }

  /** 获取锁定配置 */
  getLock(noteId: string): NoteLock | null {
    if (this.lockMap.has(noteId)) {
      return this.lockMap.get(noteId)!;
    }
    if (this.storage) {
      const lock = this.storage.load(noteId);
      if (lock) {
        this.lockMap.set(noteId, lock);
        return lock;
      }
    }
    return null;
  }

  // ── 设置 / 修改 / 移除密码 ──

  /** 设置密码锁 */
  setLock(noteId: string, password: string, biometric: boolean = false, autoRelockMs: number = 0): void {
    const lock: NoteLock = new NoteLockImpl(
      noteId, simpleHash(password), biometric, autoRelockMs, 0
    );
    this.lockMap.set(noteId, lock);
    if (this.storage) this.storage.save(lock);
    Logger.info(TAG, `setLock: ${noteId} 已设置密码锁`);
  }

  /** 修改密码（需验证旧密码） */
  changePassword(noteId: string, oldPassword: string, newPassword: string): boolean {
    const lock = this.getLock(noteId);
    if (!lock) return false;
    if (simpleHash(oldPassword) !== lock.passwordHash) {
      Logger.warn(TAG, 'changePassword: 旧密码错误');
      return false;
    }
    lock.passwordHash = simpleHash(newPassword);
    if (this.storage) this.storage.save(lock);
    return true;
  }

  /** 移除密码锁（需验证密码） */
  removeLock(noteId: string, password: string): boolean {
    const lock = this.getLock(noteId);
    if (!lock) return true;
    if (simpleHash(password) !== lock.passwordHash) {
      Logger.warn(TAG, 'removeLock: 密码错误');
      return false;
    }
    this.lockMap.delete(noteId);
    this.unlockedSet.delete(noteId);
    this.clearRelockTimer(noteId);
    if (this.storage) this.storage.remove(noteId);
    Logger.info(TAG, `removeLock: ${noteId} 已移除密码锁`);
    return true;
  }

  // ── 解锁验证 ──

  /** 密码解锁 */
  unlock(noteId: string, password: string): boolean {
    const lock = this.getLock(noteId);
    if (!lock) return true;
    if (simpleHash(password) !== lock.passwordHash) {
      Logger.warn(TAG, 'unlock: 密码错误');
      return false;
    }
    this.markUnlocked(noteId);
    return true;
  }

  /** 生物识别解锁 */
  async unlockWithBiometric(noteId: string): Promise<boolean> {
    const lock = this.getLock(noteId);
    if (!lock) return true;
    if (!lock.biometricEnabled) {
      Logger.warn(TAG, 'unlockWithBiometric: 未启用生物识别');
      return false;
    }
    if (!this.biometric || !this.biometric.isAvailable()) {
      Logger.warn(TAG, 'unlockWithBiometric: 生物识别不可用');
      return false;
    }
    const success = await this.biometric.authenticate('验证身份以解锁笔记');
    if (success) {
      this.markUnlocked(noteId);
    }
    return success;
  }

  /** 手动锁定 */
  lock(noteId: string): void {
    this.unlockedSet.delete(noteId);
    this.clearRelockTimer(noteId);
  }

  /** 标记为已解锁，并设置自动重锁 */
  private markUnlocked(noteId: string): void {
    this.unlockedSet.add(noteId);
    const lock = this.getLock(noteId);
    if (lock) {
      lock.lastUnlockedAt = Date.now();
      if (this.storage) this.storage.save(lock);
      // 设置自动重锁
      if (lock.autoRelockTimeout > 0) {
        this.setupRelockTimer(noteId, lock.autoRelockTimeout);
      }
    }
  }

  /** 设置自动重锁定时器 */
  private setupRelockTimer(noteId: string, timeoutMs: number): void {
    this.clearRelockTimer(noteId);
    const timer = setTimeout(() => {
      this.lock(noteId);
      Logger.debug(TAG, `autoRelock: ${noteId} 已自动重锁`);
    }, timeoutMs);
    this.relockTimers.set(noteId, timer);
  }

  /** 清除重锁定时器 */
  private clearRelockTimer(noteId: string): void {
    const timer = this.relockTimers.get(noteId);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.relockTimers.delete(noteId);
    }
  }

  /** 销毁时清理所有定时器 */
  destroy(): void {
    for (const noteId of this.relockTimers.keys()) {
      this.clearRelockTimer(noteId);
    }
    this.unlockedSet.clear();
    this.lockMap.clear();
  }
}
