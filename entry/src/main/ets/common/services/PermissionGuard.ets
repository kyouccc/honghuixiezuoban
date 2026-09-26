/**
 * PermissionGuard.ets — 客户端权限守卫（v2.0 增量，S2T02 / HM-11）
 *
 * 三级权限模型（PRD §4.1 权限矩阵）：
 *  - VIEWER    只读：仅查看/翻页/缩放，本地不产生任何 CRDT 操作，仅渲染；
 *  - ANNOTATOR 批注：可增删自己的 Annotation 元素（高亮/下划线/旁注），禁止图层写与素材插入；
 *  - EDITOR    编辑：全部允许；邀请/调权限/结束会话仅会话创建者（issuer==creator，服务端校验）。
 *
 * 拦截位置：StrokeEngine 落笔 / LayerManager.addElement / 素材插入入口
 * （上层引擎入口调用 assertLocalOp，返回 false 时直接忽略输入，仅允许渲染）。
 * 服务端对每条 CRDT/LayerOp 消息做权限查表校验（双端校验防伪造，Q-07）。
 *
 * 纯逻辑模块：不依赖 @kit.*（QA 可在 Node 环境直接验证）。
 */

import { Logger } from '../Logger';
import { CanvasElementType } from '../../engine/types/CanvasElement';

const TAG_MODULE = 'PermissionGuard';

/** 会话内角色（与 proto SessionRole 字符串对齐：VIEWER/ANNOTATOR/EDITOR） */
export enum SessionRole {
  VIEWER = 'VIEWER',
  ANNOTATOR = 'ANNOTATOR',
  EDITOR = 'EDITOR',
}

/** 图层操作类型（含 v2.0 增量 merge/duplicate/group/ungroup/export） */
export enum LayerOpKind {
  LAYER_CREATE = 'LAYER_CREATE',
  LAYER_DELETE = 'LAYER_DELETE',
  LAYER_UPDATE = 'LAYER_UPDATE',
  LAYER_REORDER = 'LAYER_REORDER',
  LAYER_MERGE = 'LAYER_MERGE',
  LAYER_DUPLICATE = 'LAYER_DUPLICATE',
  LAYER_GROUP = 'LAYER_GROUP',
  LAYER_UNGROUP = 'LAYER_UNGROUP',
  LAYER_EXPORT = 'LAYER_EXPORT',
}

/** 字符串 → SessionRole（服务端断言 role 字段解析；未知回退 VIEWER 最保守） */
export function sessionRoleFromString(role: string): SessionRole {
  if (role === SessionRole.EDITOR) {
    return SessionRole.EDITOR;
  }
  if (role === SessionRole.ANNOTATOR) {
    return SessionRole.ANNOTATOR;
  }
  return SessionRole.VIEWER;
}

/** 角色中文标签（卡片/UI 展示） */
export function sessionRoleLabel(role: SessionRole): string {
  if (role === SessionRole.EDITOR) {
    return '可编辑';
  }
  if (role === SessionRole.ANNOTATOR) {
    return '可批注';
  }
  return '只读';
}

export class PermissionGuard {
  private static instance: PermissionGuard | null = null;
  private role: SessionRole = SessionRole.EDITOR;  // 单机默认编辑态
  private creatorDeviceId: string = '';

  static getInstance(): PermissionGuard {
    if (!PermissionGuard.instance) {
      PermissionGuard.instance = new PermissionGuard();
    }
    return PermissionGuard.instance;
  }

  /** 服务端下发角色 → 配置守卫（加入会话时由 CollaborationManager 调用） */
  configure(role: SessionRole): void {
    this.role = role;
    Logger.info(TAG_MODULE, `PermissionGuard configured: ${role}`);
  }

  configureWithAssertion(role: SessionRole, creatorDeviceId: string): void {
    this.role = role;
    this.creatorDeviceId = creatorDeviceId;
    Logger.info(TAG_MODULE, `PermissionGuard configured: ${role}, creator=${creatorDeviceId}`);
  }

  getRole(): SessionRole {
    return this.role;
  }

  isReadOnly(): boolean {
    return this.role === SessionRole.VIEWER;
  }

  /**
   * 元素写入权限（PRD §4.1 矩阵）：
   *  - EDITOR：全部元素类型；
   *  - ANNOTATOR：仅 annotation；
   *  - VIEWER：全部拒绝。
   */
  canWriteElement(elementType: string): boolean {
    if (this.role === SessionRole.EDITOR) {
      return true;
    }
    if (this.role === SessionRole.ANNOTATOR) {
      return elementType === CanvasElementType.ANNOTATION;
    }
    return false;
  }

  /** 图层操作权限：仅 EDITOR（合并/复制/分组/重排/透明度等） */
  canLayerOp(opType: LayerOpKind): boolean {
    return this.role === SessionRole.EDITOR;
  }

  /**
   * 本地操作断言：只读端本地不产生任何 CRDT 操作（Q-07）。
   * opType: 'insert' | 'delete' | 'layer_op'；elementType 见 CanvasElementType。
   */
  assertLocalOp(opType: string, elementType: string): boolean {
    if (opType === 'layer_op') {
      return this.canLayerOp(LayerOpKind.LAYER_UPDATE);
    }
    if (opType === 'insert' || opType === 'delete') {
      return this.canWriteElement(elementType);
    }
    return false;
  }

  /** 素材插入权限（图片/形状/文本框/贴纸）：仅 EDITOR */
  canInsertAsset(): boolean {
    return this.role === SessionRole.EDITOR;
  }

  /** 会话管理权限（邀请/调权限/结束会话）：仅创建者（EDITOR + creator 匹配） */
  canManageSession(issuerDeviceId: string): boolean {
    if (this.role !== SessionRole.EDITOR) {
      return false;
    }
    if (this.creatorDeviceId.length === 0) {
      return true; // 单机/未登记创建者时默认放行（兼容 v1）
    }
    return this.creatorDeviceId === issuerDeviceId;
  }

  reset(): void {
    this.role = SessionRole.EDITOR;
    this.creatorDeviceId = '';
  }
}
