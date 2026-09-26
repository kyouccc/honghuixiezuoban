// Package ws 提供了 WebSocket 接入服务与房间级连接管理（Hub），
// 与 broadcast.go 的跨 Pod 广播配合构成完整的协作信令网关。
//
// 链路：客户端消息 → Hub 写入 → Broadcaster.Publish(带房间前缀) →
//
//	Redis 分片 channel → 所有 Pod 订阅 → dispatch → 本 Pod Hub.FanoutLocal
//
// 单 Pod 场景：写入经 Redis 回环到本 Pod 订阅者，由 Hub 扇出给房间内全部连接
// （含发送者自身，满足 CRDT 操作回声确认与压测 RTT 测量）。
//
// v2.0 修复（S2T02）：gobwas/ws 升级至 v1.4.0 API（ws.Upgrade 返回 2 值、
// wsutil.ReadServerMessage 返回 []Message，client.conn 为 net.Conn）；
// 新增 PermissionChecker 钩子，广播前对每条 CRDT/LayerOp 消息做权限查表校验（Q-07）。
package ws

import (
	"bufio"
	"context"
	"net"
	"net/http"
	"sync"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"go.uber.org/zap"
)

// PermissionChecker 每操作权限校验钩子（由 internal/crdt.Relay 实现）。
type PermissionChecker interface {
	CheckMessage(sessionID, userID string, payload []byte) error
}

// client 单个 WS 连接。conn 用于写，rw 用于读（保留 Hijack 后的缓冲读）。
type client struct {
	conn   net.Conn
	rw     *bufio.ReadWriter
	room   string
	userID string
}

// Hub 房间级连接管理器，同时实现 Broadcaster.LocalFanout 接口。
type Hub struct {
	mu      sync.RWMutex
	rooms   map[string]map[*client]struct{}
	b       *Broadcaster
	log     *zap.Logger
	checker PermissionChecker
}

// NewHub 创建连接管理器。
func NewHub(b *Broadcaster, log *zap.Logger) *Hub {
	return &Hub{
		rooms: make(map[string]map[*client]struct{}),
		b:     b,
		log:   log,
	}
}

// SetPermissionChecker 注入每操作权限校验器（S2T02，服务端 RBAC）。
func (h *Hub) SetPermissionChecker(checker PermissionChecker) {
	h.checker = checker
}

// Add 注册连接。
func (h *Hub) Add(room string, c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.rooms[room] == nil {
		h.rooms[room] = make(map[*client]struct{})
	}
	h.rooms[room][c] = struct{}{}
}

// Remove 注销连接。
func (h *Hub) Remove(room string, c *client) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if set := h.rooms[room]; set != nil {
		delete(set, c)
		if len(set) == 0 {
			delete(h.rooms, room)
		}
	}
}

// HasRoom 实现 LocalFanout：本 Pod 是否持有该房间连接。
func (h *Hub) HasRoom(roomID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.rooms[roomID]) > 0
}

// FanoutLocal 实现 LocalFanout：将 envelope 推送给本 Pod 房间内全部连接。
func (h *Hub) FanoutLocal(roomID string, envelope []byte) int {
	h.mu.RLock()
	set := h.rooms[roomID]
	conns := make([]*client, 0, len(set))
	for c := range set {
		conns = append(conns, c)
	}
	h.mu.RUnlock()

	for _, c := range conns {
		// 单连接写失败不影响其他连接；错误由读循环统一清理
		_ = wsutil.WriteServerMessage(c.conn, ws.OpBinary, envelope)
	}
	return len(conns)
}

// ServeWS 升级 HTTP 为 WebSocket，启动该连接的读写协程。
func (h *Hub) ServeWS(w http.ResponseWriter, r *http.Request) {
	room := r.URL.Query().Get("room")
	if room == "" {
		http.Error(w, "missing room", http.StatusBadRequest)
		return
	}
	userID := r.URL.Query().Get("user")
	if userID == "" {
		userID = "unknown"
	}

	conn, brw, err := wsUpgrade(w, r)
	if err != nil {
		if h.log != nil {
			h.log.Warn("ws upgrade failed", zap.Error(err))
		}
		return
	}

	c := &client{conn: conn, rw: brw, room: room, userID: userID}
	h.Add(room, c)
	if h.log != nil {
		h.log.Info("ws connected", zap.String("room", room), zap.String("user", userID))
	}

	// 驱逐通知由 /drain 处理：收到后读循环会读失败并退出
	go h.writePump(c)
	h.readPump(c)
}

// readPump 读取客户端消息并发布到广播器。
// S2T02：若配置了 PermissionChecker，广播前对 CRDT/LayerOp 消息做权限校验，越权丢弃。
func (h *Hub) readPump(c *client) {
	defer func() {
		h.Remove(c.room, c)
		_ = c.conn.Close()
	}()
	for {
		msgs, err := wsutil.ReadServerMessage(c.rw, nil)
		if err != nil {
			return
		}
		for _, msg := range msgs {
			if msg.OpCode == ws.OpClose {
				return
			}
			if h.checker != nil {
				if checkErr := h.checker.CheckMessage(c.room, c.userID, msg.Payload); checkErr != nil {
					// 越权操作丢弃（权限不足）；非 CRDT 消息由 Relay 内部放行
					continue
				}
			}
			// msg.Payload 为已序列化 SignalEnvelope；发布时带房间前缀
			if err := h.b.Publish(context.Background(), c.room, msg.Payload); err != nil {
				return
			}
		}
	}
}

// writePump 预留：当前扇出由 Hub.FanoutLocal 直接写，无需独立写协程。
// 若未来需要背压/队列，可在此实现。
func (h *Hub) writePump(_ *client) {}

// wsUpgrade 借助 http.Hijack 完成 gobwas/ws 升级（v1.4.0：Upgrade 返回 2 值，
// 返回 net.Conn 与保留缓冲读的 bufio.ReadWriter）。
func wsUpgrade(w http.ResponseWriter, r *http.Request) (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		return nil, nil, errNoHijacker
	}
	netConn, brw, err := hj.Hijack()
	if err != nil {
		return nil, nil, err
	}
	_, err = ws.Upgrade(brw)
	if err != nil {
		netConn.Close()
		return nil, nil, err
	}
	return netConn, brw, nil
}

// errNoHijacker 当前 ResponseWriter 不支持 Hijack。
type wsErr string

func (e wsErr) Error() string { return string(e) }

const errNoHijacker = wsErr("response writer does not support hijacking")

// StartWSServer 启动 WS 接入服务（HTTP 升级端点 /ws）。
func StartWSServer(addr string, b *Broadcaster, hub *Hub) error {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws", hub.ServeWS)
	srv := &http.Server{Addr: addr, Handler: mux}
	if b.log != nil {
		b.log.Info("ws server listening", zap.String("addr", addr))
	}
	return srv.ListenAndServe()
}
