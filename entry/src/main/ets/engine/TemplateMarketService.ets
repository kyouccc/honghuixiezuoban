/**
 * TemplateMarketService.ets — 模板市场（P2 扩展）
 *
 * 提供笔记模板浏览、下载、应用功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'TemplateMarketService';

export interface NoteTemplate {
  id: string;
  name: string;
  description: string;
  category: string;
  previewUrl: string;
  downloadUrl: string;
  size: number;
  rating: number;
  downloadCount: number;
}

export class TemplateMarketService {
  private static instance: TemplateMarketService;
  private templates: NoteTemplate[] = [];
  private downloadedTemplates: NoteTemplate[] = [];

  static getInstance(): TemplateMarketService {
    if (!TemplateMarketService.instance) {
      TemplateMarketService.instance = new TemplateMarketService();
    }
    return TemplateMarketService.instance;
  }

  getTemplates(): NoteTemplate[] { return this.templates; }
  getDownloaded(): NoteTemplate[] { return this.downloadedTemplates; }

  async fetchTemplates(category: string): Promise<NoteTemplate[]> {
    Logger.info(TAG, `fetchTemplates: ${category}`);
    return this.templates;
  }

  async downloadTemplate(templateId: string): Promise<NoteTemplate | null> {
    const template = this.templates.find(t => t.id === templateId);
    if (!template) return null;
    this.downloadedTemplates.push(template);
    Logger.info(TAG, `downloaded: ${template.name}`);
    return template;
  }

  applyTemplate(template: NoteTemplate): void {
    Logger.info(TAG, `applyTemplate: ${template.name}`);
  }

  deleteDownloaded(templateId: string): void {
    this.downloadedTemplates = this.downloadedTemplates.filter(t => t.id !== templateId);
  }

  getCategories(): string[] {
    return ['全部', '学习', '工作', '生活', '创意', '规划'];
  }
}
