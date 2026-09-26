/**
 * WebClipperService.ets — 网页剪藏（P2 扩展）
 *
 * 提供网页内容剪辑保存到笔记的功能。
 */
import { Logger } from '../common/Logger';

const TAG = 'WebClipperService';

export interface ClippedContent {
  url: string;
  title: string;
  content: string;
  images: string[];
  clippedAt: number;
}

export class WebClipperService {
  private static instance: WebClipperService;
  private clippings: ClippedContent[] = [];

  static getInstance(): WebClipperService {
    if (!WebClipperService.instance) {
      WebClipperService.instance = new WebClipperService();
    }
    return WebClipperService.instance;
  }

  async clipUrl(urlStr: string): Promise<ClippedContent | null> {
    Logger.info(TAG, `clipUrl: ${urlStr}`);
    const content: ClippedContent = {
      url: urlStr,
      title: '',
      content: '',
      images: [],
      clippedAt: Date.now()
    };
    this.clippings.push(content);
    return content;
  }

  clipText(title: string, content: string): ClippedContent {
    const clipped: ClippedContent = {
      url: '',
      title: title,
      content: content,
      images: [],
      clippedAt: Date.now()
    };
    this.clippings.push(clipped);
    return clipped;
  }

  getClippings(): ClippedContent[] {
    return this.clippings;
  }

  removeClipping(url: string): void {
    this.clippings = this.clippings.filter(c => c.url !== url);
  }

  clearAll(): void {
    this.clippings = [];
  }

  getHostname(urlStr: string): string {
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
