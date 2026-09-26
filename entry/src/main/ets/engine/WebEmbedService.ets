
/**
 * WebEmbedService.ets — 嵌入式网页/浏览器（P2 扩展）
 *
 * 提供笔记内嵌入网页视图功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'WebEmbedService';

export interface WebEmbedData {
  url: string;
  title: string;
  width: number;
  height: number;
  scrollable: boolean;
}

export class WebEmbedService {
  private static instance: WebEmbedService;
  private embeds: WebEmbedData[] = [];

  static getInstance(): WebEmbedService {
    if (!WebEmbedService.instance) {
      WebEmbedService.instance = new WebEmbedService();
    }
    return WebEmbedService.instance;
  }

  addEmbed(url: string, title: string, w: number, h: number, scrollable: boolean): WebEmbedData {
    const data: WebEmbedData = {
      url: url,
      title: title,
      width: w,
      height: h,
      scrollable: scrollable
    };
    this.embeds.push(data);
    return data;
  }

  removeEmbed(url: string): void {
    this.embeds = this.embeds.filter(e => e.url !== url);
  }

  getEmbeds(): WebEmbedData[] {
    return this.embeds;
  }

  async captureSnapshot(url: string): Promise<string> {
    Logger.info(TAG, `captureSnapshot: ${url}`);
    return '';
  }

  async fetchPageTitle(urlStr: string): Promise<string> {
    Logger.info(TAG, `fetchPageTitle`);
    const host = this.extractHost(urlStr);
    return host;
  }

  private extractHost(urlStr: string): string {
    if (urlStr.startsWith('https://')) {
      const rest = urlStr.substring(8);
      const idx = rest.indexOf('/');
      if (idx > 0) return rest.substring(0, idx);
      return rest;
    }
    if (urlStr.startsWith('http://')) {
      const rest = urlStr.substring(7);
      const idx = rest.indexOf('/');
      if (idx > 0) return rest.substring(0, idx);
      return rest;
    }
    return urlStr;
  }
}
