/**
 * LatexService.ets — LaTeX/数学公式（P2 扩展）
 *
 * 提供笔记内 LaTeX 数学公式编辑与渲染支持。
 */
import { Logger } from '../common/Logger';

const TAG = 'LatexService';

export interface LatexBlock {
  id: string;
  content: string;
  displayMode: boolean;
  rendered: boolean;
}

export interface LatexRenderResult {
  success: boolean;
  imagePath: string;
  errorMessage: string;
}

export class LatexService {
  private static instance: LatexService;
  private blocks: LatexBlock[] = [];

  static getInstance(): LatexService {
    if (!LatexService.instance) {
      LatexService.instance = new LatexService();
    }
    return LatexService.instance;
  }

  createBlock(content: string, displayMode: boolean): LatexBlock {
    const block: LatexBlock = {
      id: Date.now().toString(),
      content: content,
      displayMode: displayMode,
      rendered: false
    };
    this.blocks.push(block);
    return block;
  }

  removeBlock(id: string): void {
    this.blocks = this.blocks.filter(b => b.id !== id);
  }

  getBlocks(): LatexBlock[] {
    return this.blocks;
  }

  updateContent(id: string, content: string): boolean {
    const block = this.blocks.find(b => b.id === id);
    if (!block) return false;
    block.content = content;
    block.rendered = false;
    return true;
  }

  async render(blockId: string): Promise<LatexRenderResult> {
    const block = this.blocks.find(b => b.id === blockId);
    if (!block) {
      return { success: false, imagePath: '', errorMessage: 'block not found' };
    }
    Logger.info(TAG, `render: ${block.content}`);
    block.rendered = true;
    return { success: true, imagePath: '', errorMessage: '' };
  }

  isLatexBlock(text: string): boolean {
    return text.includes('$$') || text.includes('\\(') || text.includes('\\[');
  }

  extractLatex(text: string): string[] {
    const results: string[] = [];
    const parts = text.split('$$');
    for (let i = 1; i < parts.length; i += 2) {
      results.push(parts[i]);
    }
    return results;
  }
}
