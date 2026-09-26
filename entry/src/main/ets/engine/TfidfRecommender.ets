/**
 * TfidfRecommender.ets — 端侧 TF-IDF 关键词推荐引擎（NOTE-02，阶段2 P1）
 *
 * 用途：双链建链时，根据源节点文本内容，自动推荐同画布中关键词最相关的节点。
 * 纯端侧计算，不依赖云端，符合隐私不下云约束。
 *
 * 算法：
 *  1. 中文按2-3字滑窗分词 + 英文按空格分词（轻量方案，不引入jieba等第三方依赖）
 *  2. TF（词频）= 词条出现次数 / 文档总词数
 *  3. IDF = ln(总文档数 / 包含该词的文档数 + 1)
 *  4. 相似度 = Σ(tf_source * tf_target * idf_word)
 *  5. 按相似度降序取 Top-N
 */

import { CanvasNode, TextPayload, StickyPayload } from './types/BoardModel';

/** 推荐结果项 */
export interface RecommendItem {
  nodeId: string;
  /** 节点文本摘要（展示用） */
  snippet: string;
  /** 相似度分数（0-1归一化） */
  score: number;
  /** 命中关键词列表 */
  keywords: string[];
}

export class TfidfRecommender {
  /** 推荐最大返回数 */
  private static readonly TOP_N: number = 8;
  /** 摘要截断长度 */
  private static readonly SNIPPET_LEN: number = 20;

  /**
   * 从节点列表中推荐与源节点最相关的目标节点。
   * @param sourceNodeId 源节点 id（排除自身）
   * @param nodes 当前画布全部可见节点
   * @param excludeIds 需排除的节点 id（如已建链的节点）
   * @returns 按相似度降序排列的推荐列表
   */
  static recommend(sourceNodeId: string, nodes: CanvasNode[], excludeIds: string[] = []): RecommendItem[] {
    // 1. 提取所有文本节点的文档
    const docs: Map<string, string> = new Map<string, string>();
    let sourceText: string = '';

    for (let i = 0; i < nodes.length; i++) {
      const node: CanvasNode = nodes[i];
      if (node.deleted) {
        continue;
      }
      const text: string = TfidfRecommender.extractText(node);
      if (text.length === 0) {
        continue;
      }
      docs.set(node.id, text);
      if (node.id === sourceNodeId) {
        sourceText = text;
      }
    }

    if (sourceText.length === 0) {
      return [];
    }

    // 2. 构建排除集合
    const excludeSet: Set<string> = new Set<string>(excludeIds);
    excludeSet.add(sourceNodeId);

    // 3. 分词 + 计算 TF
    const allDocs: string[] = [];
    docs.forEach((text: string) => {
      allDocs.push(text);
    });

    const sourceTokens: string[] = TfidfRecommender.tokenize(sourceText);
    if (sourceTokens.length === 0) {
      return [];
    }

    const sourceTf: Map<string, number> = TfidfRecommender.computeTf(sourceTokens);

    // 4. 计算 IDF（基于全部文档）
    const idf: Map<string, number> = TfidfRecommender.computeIdf(allDocs);

    // 5. 对每个候选节点计算相似度
    const results: RecommendItem[] = [];
    docs.forEach((text: string, nodeId: string) => {
      if (excludeSet.has(nodeId)) {
        return;
      }
      const tokens: string[] = TfidfRecommender.tokenize(text);
      if (tokens.length === 0) {
        return;
      }
      const targetTf: Map<string, number> = TfidfRecommender.computeTf(tokens);

      // 余弦相似度（TF-IDF 加权）
      let dotProduct: number = 0;
      const matchedKeywords: string[] = [];
      sourceTf.forEach((tfS: number, word: string) => {
        const tfT: number | undefined = targetTf.get(word);
        if (tfT !== undefined) {
          const idfVal: number | undefined = idf.get(word);
          if (idfVal !== undefined) {
            const weightS: number = tfS * idfVal;
            const weightT: number = tfT * idfVal;
            dotProduct += weightS * weightT;
            if (matchedKeywords.length < 5) {
              matchedKeywords.push(word);
            }
          }
        }
      });

      if (dotProduct > 0) {
        results.push({
          nodeId: nodeId,
          snippet: text.length > TfidfRecommender.SNIPPET_LEN ? text.substring(0, TfidfRecommender.SNIPPET_LEN) + '…' : text,
          score: dotProduct,
          keywords: matchedKeywords
        });
      }
    });

    // 6. 归一化 + 降序排序 + 取 Top-N
    if (results.length === 0) {
      return [];
    }
    const maxScore: number = results[0].score;
    for (let i = 0; i < results.length; i++) {
      results[i].score = maxScore > 0 ? results[i].score / maxScore : 0;
    }
    results.sort((a: RecommendItem, b: RecommendItem) => b.score - a.score);
    return results.slice(0, TfidfRecommender.TOP_N);
  }

  /** 从节点 payload 提取文本（text/sticky 类型） */
  private static extractText(node: CanvasNode): string {
    if (node.type === 'text') {
      const pl: TextPayload = node.payload as TextPayload;
      return pl.content;
    } else if (node.type === 'sticky') {
      const pl: StickyPayload = node.payload as StickyPayload;
      return pl.text;
    }
    return '';
  }

  /**
   * 轻量分词：中文2-3字滑窗 + 英文按空格/标点分割。
   * 不引入 jieba 等第三方依赖，满足 MVP 端侧轻量约束。
   */
  private static tokenize(text: string): string[] {
    const tokens: string[] = [];
    const segments: string[] = text.split(/[\s,，。.!！?？;；:：、（）()【】\[\]{}""''`'\n\r\t]+/);

    for (let s = 0; s < segments.length; s++) {
      const seg: string = segments[s];
      if (seg.length === 0) {
        continue;
      }

      // 判断是否纯英文/数字
      if (/^[a-zA-Z0-9]+$/.test(seg)) {
        if (seg.length >= 2) {
          tokens.push(seg.toLowerCase());
        }
        continue;
      }

      // 中文：2字滑窗（覆盖大多数双音节词）
      for (let i = 0; i < seg.length - 1; i++) {
        const bigram: string = seg.substring(i, i + 2);
        tokens.push(bigram);
      }
      // 3字滑窗（覆盖三音节词，权重通过出现频率自然体现）
      for (let i = 0; i < seg.length - 2; i++) {
        const trigram: string = seg.substring(i, i + 3);
        tokens.push(trigram);
      }
    }

    return tokens;
  }

  /** 计算词频（TF = 词条出现次数 / 总词数） */
  private static computeTf(tokens: string[]): Map<string, number> {
    const tf: Map<string, number> = new Map<string, number>();
    const total: number = tokens.length;
    if (total === 0) {
      return tf;
    }
    const counts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < tokens.length; i++) {
      const t: string = tokens[i];
      const c: number | undefined = counts.get(t);
      counts.set(t, c !== undefined ? c + 1 : 1);
    }
    counts.forEach((count: number, word: string) => {
      tf.set(word, count / total);
    });
    return tf;
  }

  /** 计算 IDF = ln(总文档数 / 包含该词的文档数 + 1) */
  private static computeIdf(docs: string[]): Map<string, number> {
    const idf: Map<string, number> = new Map<string, number>();
    const docCount: number = docs.length;
    if (docCount === 0) {
      return idf;
    }

    // 统计每个词出现在多少篇文档中
    const docFreq: Map<string, number> = new Map<string, number>();
    for (let d = 0; d < docs.length; d++) {
      const tokens: string[] = TfidfRecommender.tokenize(docs[d]);
      const seen: Set<string> = new Set<string>();
      for (let i = 0; i < tokens.length; i++) {
        seen.add(tokens[i]);
      }
      seen.forEach((word: string) => {
        const c: number | undefined = docFreq.get(word);
        docFreq.set(word, c !== undefined ? c + 1 : 1);
      });
    }

    docFreq.forEach((freq: number, word: string) => {
      idf.set(word, Math.log(docCount / (freq + 1) + 1));
    });

    return idf;
  }
}
