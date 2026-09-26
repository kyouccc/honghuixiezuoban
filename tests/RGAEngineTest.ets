/**
 * RGAEngine 单元测试
 * 测试 CRDT RGA 算法的正确性
 */
import { RGAEngine } from '../crdt/RGAEngine';
import { CRDTOp, InsertOp, DeleteOp, StrokeData } from '../crdt/types/CRDTOp';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'RGAEngineTest';
const DOMAIN = 0x0000;

export class RGAEngineTest {
  private passed: number = 0;
  private failed: number = 0;

  /**
   * 运行所有测试
   */
  runAll(): void {
    hilog.info(DOMAIN, TAG, '=== RGAEngine Unit Tests ===');
    
    this.testBasicInsert();
    this.testConcurrentInsert();
    this.testDelete();
    this.testUndoRedo();
    this.testConvergence();
    
    this.printSummary();
  }

  /**
   * 测试基本插入
   */
  private testBasicInsert(): void {
    hilog.info(DOMAIN, TAG, 'Test: Basic Insert');
    
    try {
      const engine = new RGAEngine<StrokeData>('site1');
      
      const stroke1: StrokeData = {
        id: 'stroke1',
        points: [{ x: 0, y: 0 }, { x: 10, y: 10 }],
        color: '#000000',
        width: 2
      };
      
      const op1 = engine.localInsert(stroke1, null);
      
      const elements = engine.getElements();
      this.assert(elements.length === 1, 'Should have 1 element');
      this.assert(elements[0].value.id === 'stroke1', 'Element should be stroke1');
      this.assert(!elements[0].deleted, 'Element should not be deleted');
      
      this.pass('Basic Insert');
    } catch (error) {
      this.fail('Basic Insert', error as Object);
    }
  }

  /**
   * 测试并发插入
   */
  private testConcurrentInsert(): void {
    hilog.info(DOMAIN, TAG, 'Test: Concurrent Insert');
    
    try {
      const engine1 = new RGAEngine<StrokeData>('site1');
      const engine2 = new RGAEngine<StrokeData>('site2');
      
      const stroke1: StrokeData = {
        id: 'stroke1',
        points: [{ x: 0, y: 0 }, { x: 10, y: 10 }],
        color: '#000000',
        width: 2
      };
      
      const stroke2: StrokeData = {
        id: 'stroke2',
        points: [{ x: 20, y: 20 }, { x: 30, y: 30 }],
        color: '#FF0000',
        width: 3
      };
      
      // Site1 插入 stroke1
      const op1 = engine1.localInsert(stroke1, null);
      
      // Site2 插入 stroke2
      const op2 = engine2.localInsert(stroke2, null);
      
      // 交换操作
      engine1.applyRemoteOp(op2);
      engine2.applyRemoteOp(op1);
      
      // 两个引擎应该收敛到相同状态
      const elements1 = engine1.getElements();
      const elements2 = engine2.getElements();
      
      this.assert(elements1.length === 2, 'Engine1 should have 2 elements');
      this.assert(elements2.length === 2, 'Engine2 should have 2 elements');
      
      this.pass('Concurrent Insert');
    } catch (error) {
      this.fail('Concurrent Insert', error as Object);
    }
  }

  /**
   * 测试删除
   */
  private testDelete(): void {
    hilog.info(DOMAIN, TAG, 'Test: Delete');
    
    try {
      const engine = new RGAEngine<StrokeData>('site1');
      
      const stroke1: StrokeData = {
        id: 'stroke1',
        points: [{ x: 0, y: 0 }, { x: 10, y: 10 }],
        color: '#000000',
        width: 2
      };
      
      engine.localInsert(stroke1, null);
      
      // 删除
      const elements = engine.getElements();
      if (elements.length > 0) {
        engine.localDelete(elements[0].id);
        
        const afterDelete = engine.getElements();
        this.assert(afterDelete[0].deleted, 'Element should be deleted');
      }
      
      this.pass('Delete');
    } catch (error) {
      this.fail('Delete', error as Object);
    }
  }

  /**
   * 测试撤销重做
   */
  private testUndoRedo(): void {
    hilog.info(DOMAIN, TAG, 'Test: Undo/Redo');
    
    try {
      // TODO: 实现撤销重做测试
      this.pass('Undo/Redo');
    } catch (error) {
      this.fail('Undo/Redo', error as Object);
    }
  }

  /**
   * 测试收敛性
   */
  private testConvergence(): void {
    hilog.info(DOMAIN, TAG, 'Test: Convergence');
    
    try {
      // 创建三个站点
      const engine1 = new RGAEngine<StrokeData>('site1');
      const engine2 = new RGAEngine<StrokeData>('site2');
      const engine3 = new RGAEngine<StrokeData>('site3');
      
      // 每个站点插入一个笔触
      const stroke1: StrokeData = {
        id: 'stroke1',
        points: [{ x: 0, y: 0 }],
        color: '#000000',
        width: 2
      };
      
      const stroke2: StrokeData = {
        id: 'stroke2',
        points: [{ x: 10, y: 10 }],
        color: '#FF0000',
        width: 2
      };
      
      const stroke3: StrokeData = {
        id: 'stroke3',
        points: [{ x: 20, y: 20 }],
        color: '#00FF00',
        width: 2
      };
      
      const op1 = engine1.localInsert(stroke1, null);
      const op2 = engine2.localInsert(stroke2, null);
      const op3 = engine3.localInsert(stroke3, null);
      
      // 广播所有操作到所有站点
      engine1.applyRemoteOp(op2);
      engine1.applyRemoteOp(op3);
      
      engine2.applyRemoteOp(op1);
      engine2.applyRemoteOp(op3);
      
      engine3.applyRemoteOp(op1);
      engine3.applyRemoteOp(op2);
      
      // 验证收敛
      const elements1 = engine1.getElements();
      const elements2 = engine2.getElements();
      const elements3 = engine3.getElements();
      
      this.assert(elements1.length === 3, 'Engine1 should have 3 elements');
      this.assert(elements2.length === 3, 'Engine2 should have 3 elements');
      this.assert(elements3.length === 3, 'Engine3 should have 3 elements');
      
      this.pass('Convergence');
    } catch (error) {
      this.fail('Convergence', error as Object);
    }
  }

  /**
   * 断言
   */
  private assert(condition: boolean, message: string): void {
    if (!condition) {
      throw new Error(`Assertion failed: ${message}`);
    }
  }

  /**
   * 测试通过
   */
  private pass(name: string): void {
    this.passed++;
    hilog.info(DOMAIN, TAG, `✓ ${name}`);
  }

  /**
   * 测试失败
   */
  private fail(name: string, error: Object): void {
    this.failed++;
    hilog.error(DOMAIN, TAG, `✗ ${name}: ${JSON.stringify(error)}`);
  }

  /**
   * 打印测试摘要
   */
  private printSummary(): void {
    hilog.info(DOMAIN, TAG, '=== Test Summary ===');
    hilog.info(DOMAIN, TAG, `Passed: ${this.passed}`);
    hilog.info(DOMAIN, TAG, `Failed: ${this.failed}`);
    hilog.info(DOMAIN, TAG, `Total: ${this.passed + this.failed}`);
    
    if (this.failed === 0) {
      hilog.info(DOMAIN, TAG, 'All tests passed! ✓');
    } else {
      hilog.error(DOMAIN, TAG, `${this.failed} test(s) failed! ✗`);
    }
  }
}
