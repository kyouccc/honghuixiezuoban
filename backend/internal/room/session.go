// Package room 提供 v2.0 笔记协作会话管理（HM-10/HM-11）。
// 会话 = v1 房间的语义扩展（room_type=note_collab，V2-Q5 决策），
// 复用 Redis/广播/过期机制；P0 以内存存储实现（参赛可演示）。
package room

import (
	"errors"
	"sync"
	"time"

	"honghui/backend/internal/auth"
)

// Session 笔记协作会话。
type Session struct {
	ID          string
	Name        string
	NoteID      string
	CreatorID   string
	DefaultRole auth.SessionRole
	WSEndpoint  string
	ExpiresAt   time.Time
	Roles       map[string]auth.SessionRole // userID -> role
	OnlineCount int
	CreatedAt   time.Time
}

// ErrNotFound 会话不存在。
var ErrNotFound = errors.New("session not found")

// ErrForbidden 仅创建者可执行（邀请/调权限/结束会话）。
var ErrForbidden = errors.New("only creator can manage session")

// Store 会话存储（内存实现 + 互斥锁；生产可替换为 Redis）。
type Store struct {
	mu       sync.RWMutex
	sessions map[string]*Session
}

// NewStore 创建会话存储。
func NewStore() *Store {
	return &Store{
		sessions: make(map[string]*Session),
	}
}

// Create 创建会话：创建者默认 EDITOR（PRD §4.2）。
func (s *Store) Create(id, name, noteID, creatorID, wsEndpoint string, defaultRole auth.SessionRole, ttl time.Duration) *Session {
	now := time.Now()
	sess := &Session{
		ID:          id,
		Name:        name,
		NoteID:      noteID,
		CreatorID:   creatorID,
		DefaultRole: defaultRole,
		WSEndpoint:  wsEndpoint,
		ExpiresAt:   now.Add(ttl),
		Roles:       map[string]auth.SessionRole{creatorID: auth.RoleEditor},
		OnlineCount: 1,
		CreatedAt:   now,
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[id] = sess
	return sess
}

// Get 查询会话。
func (s *Store) Get(id string) (*Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	sess, ok := s.sessions[id]
	if !ok {
		return nil, ErrNotFound
	}
	if time.Now().After(sess.ExpiresAt) {
		delete(s.sessions, id)
		return nil, ErrNotFound
	}
	return sess, nil
}

// Join 加入会话：按 default_role 授予（wantRole 仅在创建者指定时生效）。
func (s *Store) Join(id, userID string, wantRole auth.SessionRole) (*Session, auth.SessionRole, error) {
	sess, err := s.Get(id)
	if err != nil {
		return nil, auth.RoleUnknown, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	role, ok := sess.Roles[userID]
	if !ok {
		// 新加入者按会话默认角色授权；wantRole 优先级高于默认值
		if wantRole != auth.RoleUnknown {
			role = wantRole
		} else {
			role = sess.DefaultRole
		}
		sess.Roles[userID] = role
		sess.OnlineCount++
	}
	return sess, role, nil
}

// UpdateRole 调整权限（仅创建者/EDITOR，PRD §4.1）。
func (s *Store) UpdateRole(id, operatorID, userID string, newRole auth.SessionRole) error {
	sess, err := s.Get(id)
	if err != nil {
		return err
	}
	if operatorID != sess.CreatorID {
		return ErrForbidden
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	sess.Roles[userID] = newRole
	return nil
}

// Delete 结束会话（仅创建者；触发数据清理由上层 cleanup 管道负责，HM-15）。
func (s *Store) Delete(id, operatorID string) error {
	sess, err := s.Get(id)
	if err != nil {
		return err
	}
	if operatorID != sess.CreatorID {
		return ErrForbidden
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, id)
	return nil
}

// OnlineCount 在线人数。
func (s *Store) OnlineCount(id string) int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if sess, ok := s.sessions[id]; ok {
		return sess.OnlineCount
	}
	return 0
}
