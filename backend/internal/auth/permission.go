// Package auth 提供 v2.0 会话权限模型（RBAC）：会话角色登记、
// PermissionAssertion 签发/校验、每 CRDT/LayerOp 操作权限查表校验（Q-07）。
//
// 三级权限矩阵（PRD §4.1）：
//   - VIEWER    只读：拒绝一切 CRDT 写操作与 LayerOp 写操作
//   - ANNOTATOR 批注：允许 Annotation 元素 Insert/Delete（仅自己的），禁止图层写与素材插入
//   - EDITOR    编辑：全部允许；邀请/调权限/结束会话仅创建者（issuer==creator）
//
// 断言签名：HMAC-SHA256(secret, session_id|user_id|role|expires_at)。
package auth

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

// SessionRole 会话内角色（与 proto SessionRole 对齐：1=VIEWER 2=ANNOTATOR 3=EDITOR）
type SessionRole int

const (
	// RoleUnknown 未知角色
	RoleUnknown SessionRole = 0
	// RoleViewer 只读
	RoleViewer SessionRole = 1
	// RoleAnnotator 批注
	RoleAnnotator SessionRole = 2
	// RoleEditor 编辑
	RoleEditor SessionRole = 3
)

// 错误码（架构 §3.3 增量）
var (
	// ErrPermissionDenied 1101 权限不足
	ErrPermissionDenied = errors.New("permission denied (1101)")
	// ErrInvalidAssertion 1102 权限断言过期/签名无效
	ErrInvalidAssertion = errors.New("invalid permission assertion (1102)")
	// ErrSessionNotFound 1103 会话不存在
	ErrSessionNotFound = errors.New("session not found (1103)")
)

// ElementType 元素类型字符串常量（与两端约定一致，架构 §8.1 约定 2）
const (
	ElementStroke     = "stroke"
	ElementShape      = "shape"
	ElementTextBlock  = "text_block"
	ElementAnnotation = "annotation"
	ElementImageRef   = "image_ref"
	ElementMindMap    = "mind_map"
)

// OpKind 操作种类（服务端校验粒度）
const (
	OpKindCRDTInsert = "crdt_insert"
	OpKindCRDTDelete = "crdt_delete"
	OpKindLayerOp    = "layer_op"
)

// PermissionAssertion 权限断言（服务端签发，客户端信令携带）
type PermissionAssertion struct {
	SessionID string
	UserID    string
	DeviceID  string
	Role      SessionRole
	Issuer    string
	IssuedAt  int64
	ExpiresAt int64
	Signature string
}

// PermissionStore 角色登记 + 断言签发/校验。
// 角色表以内存 map 缓存（生产环境可替换为 Redis，TTL=断言有效期，Q-07 命中率>99%）。
type PermissionStore struct {
	mu     sync.RWMutex
	secret []byte
	roles  map[string]SessionRole // key: sessionID + ":" + userID
}

// NewPermissionStore 创建权限存储。secret 用于断言 HMAC 签名。
func NewPermissionStore(secret string) *PermissionStore {
	key := secret
	if key == "" {
		key = "harmonycanvas-dev-secret"
	}
	return &PermissionStore{
		secret: []byte(key),
		roles:  make(map[string]SessionRole),
	}
}

// roleKey 角色表主键。
func roleKey(sessionID, userID string) string {
	return sessionID + ":" + userID
}

// CacheRole 登记/更新会话角色（Redis 缓存角色语义；TTL 由调用方/上层管理）。
func (s *PermissionStore) CacheRole(sessionID, userID string, role SessionRole) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.roles[roleKey(sessionID, userID)] = role
}

// GetRole 查询会话角色；未登记默认 VIEWER（最保守）。
func (s *PermissionStore) GetRole(sessionID, userID string) SessionRole {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if role, ok := s.roles[roleKey(sessionID, userID)]; ok {
		return role
	}
	return RoleViewer
}

// RemoveRole 删除会话角色（会话结束清理）。
func (s *PermissionStore) RemoveRole(sessionID, userID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.roles, roleKey(sessionID, userID))
}

// SignAssertion 签发权限断言（HMAC-SHA256(secret, session_id|user_id|role|expires_at)）。
func (s *PermissionStore) SignAssertion(sessionID, userID, deviceID string, role SessionRole, issuer string, ttl time.Duration) PermissionAssertion {
	now := time.Now()
	expiresAt := now.Add(ttl).Unix()
	payload := assertionPayload(sessionID, userID, int(role), expiresAt)
	sig := s.hmac(payload)
	return PermissionAssertion{
		SessionID: sessionID,
		UserID:    userID,
		DeviceID:  deviceID,
		Role:      role,
		Issuer:    issuer,
		IssuedAt:  now.Unix(),
		ExpiresAt: expiresAt,
		Signature: sig,
	}
}

// VerifyAssertion 校验断言签名与有效期。
func (s *PermissionStore) VerifyAssertion(a PermissionAssertion) error {
	if a.SessionID == "" || a.UserID == "" {
		return ErrInvalidAssertion
	}
	if time.Now().Unix() > a.ExpiresAt {
		return ErrInvalidAssertion
	}
	expected := s.hmac(assertionPayload(a.SessionID, a.UserID, int(a.Role), a.ExpiresAt))
	if !hmac.Equal([]byte(expected), []byte(a.Signature)) {
		return ErrInvalidAssertion
	}
	return nil
}

// CheckOpAllowed 每 CRDT/LayerOp 操作权限校验（服务端，Q-07）。
// opKind: crdt_insert | crdt_delete | layer_op；elementType 见 Element* 常量。
func (s *PermissionStore) CheckOpAllowed(sessionID, userID, opKind, elementType string) error {
	role := s.GetRole(sessionID, userID)
	switch opKind {
	case OpKindCRDTInsert, OpKindCRDTDelete:
		if role == RoleViewer {
			return ErrPermissionDenied
		}
		if role == RoleAnnotator {
			// 批注者仅允许 Annotation 元素操作（仅自己的由服务端扩展 userID 比对）
			if elementType != ElementAnnotation {
				return ErrPermissionDenied
			}
		}
		return nil
	case OpKindLayerOp:
		if role != RoleEditor {
			return ErrPermissionDenied
		}
		return nil
	default:
		return fmt.Errorf("unknown op kind %q", opKind)
	}
}

// RoleFromString 字符串角色 → SessionRole（未知回退 VIEWER 最保守）。
func RoleFromString(role string) SessionRole {
	switch strings.ToUpper(role) {
	case "EDITOR":
		return RoleEditor
	case "ANNOTATOR":
		return RoleAnnotator
	case "VIEWER":
		return RoleViewer
	default:
		return RoleViewer
	}
}

// RoleToString SessionRole → 字符串。
func RoleToString(role SessionRole) string {
	switch role {
	case RoleEditor:
		return "EDITOR"
	case RoleAnnotator:
		return "ANNOTATOR"
	case RoleViewer:
		return "VIEWER"
	default:
		return "VIEWER"
	}
}

// assertionPayload 签名原文。
func assertionPayload(sessionID, userID string, role int, expiresAt int64) string {
	return sessionID + "|" + userID + "|" + strconv.Itoa(role) + "|" + strconv.FormatInt(expiresAt, 10)
}

func (s *PermissionStore) hmac(payload string) string {
	mac := hmac.New(sha256.New, s.secret)
	mac.Write([]byte(payload))
	return hex.EncodeToString(mac.Sum(nil))
}
