import { Logger } from '../Logger';

const TAG = 'PerformanceTracker';

interface MetricRecord {
  name: string;
  values: number[];
  min: number;
  max: number;
  avg: number;
  p95: number;
  count: number;
}

export class PerformanceTracker {
  private static instance: PerformanceTracker | null = null;
  private metrics: Map<string, MetricRecord> = new Map();

  static getInstance(): PerformanceTracker {
    if (!PerformanceTracker.instance) {
      PerformanceTracker.instance = new PerformanceTracker();
    }
    return PerformanceTracker.instance;
  }

  record(name: string, valueMs: number): void {
    let metric = this.metrics.get(name);
    if (!metric) {
      metric = { name, values: [], min: Infinity, max: -Infinity, avg: 0, p95: 0, count: 0 };
      this.metrics.set(name, metric);
    }
    metric.values.push(valueMs);
    metric.min = Math.min(metric.min, valueMs);
    metric.max = Math.max(metric.max, valueMs);
    metric.count++;
    metric.avg = metric.values.reduce((a, b) => a + b, 0) / metric.count;

    // 计算P95
    const sorted = [...metric.values].sort((a, b) => a - b);
    const p95Idx = Math.ceil(sorted.length * 0.95) - 1;
    metric.p95 = sorted[Math.max(0, p95Idx)];

    // 限制记录数量
    if (metric.values.length > 1000) {
      metric.values = metric.values.slice(-500);
    }
  }

  get(name: string): MetricRecord | undefined {
    return this.metrics.get(name);
  }

  getAll(): Map<string, MetricRecord> {
    return new Map(this.metrics);
  }

  report(): string {
    let report = '=== Performance Report ===\n';
    this.metrics.forEach((m, name) => {
      report += `${name}: avg=${m.avg.toFixed(2)}ms p95=${m.p95.toFixed(2)}ms min=${m.min.toFixed(2)}ms max=${m.max.toFixed(2)}ms count=${m.count}\n`;
    });
    Logger.info(TAG, report);
    return report;
  }

  reset(): void {
    this.metrics.clear();
  }
}
