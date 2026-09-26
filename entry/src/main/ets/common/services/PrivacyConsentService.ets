/**
 * 隐私同意服务
 * 用于管理用户隐私同意状态，确保在用户同意前不收集任何信息
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../Logger';

const PRIVACY_CONSENT_KEY = 'privacy_consent_accepted';
const PREFERENCES_NAME = 'privacy_store';

export class PrivacyConsentService {
  private static instance: PrivacyConsentService;
  private context: common.UIAbilityContext | null = null;
  private consentAccepted: boolean = false;
  /** 🔧 修复：防重入标志，防止多个异步 checkConsent 并发导致弹窗重复打开 */
  private dialogOpened: boolean = false;

  static getInstance(): PrivacyConsentService {
    if (!PrivacyConsentService.instance) {
      PrivacyConsentService.instance = new PrivacyConsentService();
    }
    return PrivacyConsentService.instance;
  }

  init(context: common.UIAbilityContext): void {
    this.context = context;
  }

  async checkConsent(): Promise<boolean> {
    if (!this.context) {
      return false;
    }

    try {
      const prefs = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      this.consentAccepted = await prefs.get(PRIVACY_CONSENT_KEY, false) as boolean;
      return this.consentAccepted;
    } catch (error) {
      Logger.error('PrivacyConsentService', 'checkConsent error: ' + JSON.stringify(error));
      return false;
    }
  }

  /** 🔧 修复：检查弹窗是否已打开，防止多个隐私弹窗同时出现 */
  isDialogOpened(): boolean {
    return this.dialogOpened;
  }

  /** 🔧 修复：标记弹窗已打开 */
  markDialogOpened(): void {
    this.dialogOpened = true;
  }

  async acceptConsent(): Promise<void> {
    if (!this.context) {
      return;
    }

    try {
      const prefs = await preferences.getPreferences(this.context, PREFERENCES_NAME);
      await prefs.put(PRIVACY_CONSENT_KEY, true);
      await prefs.flush();
      this.consentAccepted = true;
      this.dialogOpened = false;
      Logger.info('PrivacyConsentService', 'Privacy consent accepted');
    } catch (error) {
      Logger.error('PrivacyConsentService', 'acceptConsent error: ' + JSON.stringify(error));
    }
  }

  isConsentAccepted(): boolean {
    return this.consentAccepted;
  }
}

export const privacyConsentService = PrivacyConsentService.getInstance();
