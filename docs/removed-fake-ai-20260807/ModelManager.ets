import { Logger } from '../common/Logger';
import { Constants } from '../common/Constants';

const TAG_MODULE = 'ModelManager';

interface ModelInfo {
  name: string;
  version: string;
  sizeBytes: number;
  path: string;
  isLoaded: boolean;
  lastUsed: number;
}

export class ModelManager {
  private static instance: ModelManager | null = null;
  private models: Map<string, ModelInfo> = new Map();
  private maxCachedModels: number = 2;

  static getInstance(): ModelManager {
    if (!ModelManager.instance) {
      ModelManager.instance = new ModelManager();
    }
    return ModelManager.instance;
  }

  registerModel(name: string, version: string, sizeBytes: number, path: string): void {
    this.models.set(name, {
      name, version, sizeBytes, path, isLoaded: false, lastUsed: Date.now()
    });
    Logger.info(TAG_MODULE, `Model registered: ${name} v${version} (${(sizeBytes / 1024 / 1024).toFixed(1)}MB)`);
  }

  getModel(name: string): ModelInfo | undefined {
    return this.models.get(name);
  }

  checkVersion(name: string): string {
    return this.models.get(name)?.version || 'unknown';
  }

  markLoaded(name: string): void {
    const model = this.models.get(name);
    if (model) {
      model.isLoaded = true;
      model.lastUsed = Date.now();
      this.evictLRU();
    }
  }

  markUnloaded(name: string): void {
    const model = this.models.get(name);
    if (model) {
      model.isLoaded = false;
    }
  }

  /**
   * LRU淘汰：最多保留2个模型在内存中
   */
  private evictLRU(): void {
    const loaded = Array.from(this.models.values())
      .filter(m => m.isLoaded)
      .sort((a, b) => a.lastUsed - b.lastUsed);

    while (loaded.length > this.maxCachedModels) {
      const oldest = loaded.shift()!;
      oldest.isLoaded = false;
      Logger.info(TAG_MODULE, `LRU evicted: ${oldest.name}`);
    }
  }

  /**
   * 模拟从CDN下载模型到应用沙箱
   * CRITICAL: 实际项目中通过request.downloadFile下载
   */
  async downloadModel(name: string, url: string): Promise<string> {
    Logger.info(TAG_MODULE, `Downloading model: ${name} from ${url}`);
    // 模拟下载延迟
    await this.sleep(1500);
    const localPath = `/data/storage/el2/base/haps/entry/files/models/${name}_v1.2.int8.ms`;
    Logger.info(TAG_MODULE, `Model downloaded: ${localPath}`);
    return localPath;
  }

  /**
   * 模型热更新：检查版本 → 下载新版本 → 静默替换
   */
  async checkAndUpdate(modelName: string, latestVersion: string, downloadUrl: string): Promise<boolean> {
    const current = this.models.get(modelName);
    if (!current || current.version < latestVersion) {
      Logger.info(TAG_MODULE, `Updating ${modelName}: ${current?.version || 'none'} → ${latestVersion}`);
      const newPath = await this.downloadModel(modelName, downloadUrl);
      this.registerModel(modelName, latestVersion, Constants.AI_MODEL_MAX_SIZE, newPath);
      return true;
    }
    return false;
  }

  getTotalLoadedSize(): number {
    let total = 0;
    this.models.forEach(m => {
      if (m.isLoaded) total += m.sizeBytes;
    });
    return total;
  }

  private sleep(ms: number): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}
