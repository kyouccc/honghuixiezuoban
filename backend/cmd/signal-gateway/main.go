package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"harmonycanvas/backend/internal/auth"
	"harmonycanvas/backend/internal/crdt"
	"harmonycanvas/backend/internal/room"
	ws "harmonycanvas/backend/internal/ws"
)

// draining 优雅驱逐标记（v1.1）。
// preStop 调用 /drain 后置位：readiness 开始失败使 Pod 从 Service 摘除，
// 同时 WS 层向存量客户端下发 REBALANCE 通知其主动重连。
var draining atomic.Bool

var (
	port      = flag.Int("port", 8080, "HTTP server port")
	wsPort    = flag.Int("ws-port", 8081, "WebSocket server port")
	redisAddr = flag.String("redis", "localhost:6379", "Redis address")
)

// v2.0（S2T02/HM-11）：会话/权限存储 + CRDT 中继（服务端 RBAC）
var (
	permStore *auth.PermissionStore
	sessStore *room.Store
	relay     *crdt.Relay
)

func main() {
	flag.Parse()

	logger, _ := zap.NewProduction()
	defer logger.Sync()

	log.Println("=== 鸿绘协作板 信令网关 ===")
	log.Printf("HTTP: :%d | WS: :%d | Redis: %s", *port, *wsPort, *redisAddr)

	// Redis 客户端（跨 Pod 广播依赖）
	rdb := redis.NewClient(&redis.Options{Addr: *redisAddr})

	// v2.0：初始化权限存储 + 会话存储 + CRDT 中继
	permStore = auth.NewPermissionStore("harmonycanvas-session-secret")
	sessStore = room.NewStore()
	relay = crdt.NewRelay(permStore)

	// 广播器 + 连接管理器（Hub 实现 LocalFanout 接口）
	b := ws.NewBroadcaster(rdb, nil, logger)
	hub := ws.NewHub(b, logger)
	// S2T02：广播前每 CRDT/LayerOp 消息权限查表校验（Q-07）
	hub.SetPermissionChecker(relay)
	b.SetLocalFanout(hub)
	b.Start(context.Background())

	// HTTP REST API
	router := gin.Default()
	setupRoutes(router)

	httpSrv := &http.Server{
		Addr:    fmt.Sprintf(":%d", *port),
		Handler: router,
	}

	// WS 接入服务（8081）
	go func() {
		if err := ws.StartWSServer(fmt.Sprintf(":%d", *wsPort), b, hub); err != nil {
			log.Fatalf("WS server error: %v", err)
		}
	}()

	// 优雅关闭
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		log.Printf("HTTP server listening on :%d", *port)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	<-quit
	log.Println("Shutting down...")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	b.Close()
	if err := httpSrv.Shutdown(ctx); err != nil {
		log.Fatalf("Forced shutdown: %v", err)
	}

	log.Println("Server stopped")
}

func setupRoutes(r *gin.Engine) {
	api := r.Group("/v1")
	{
		api.POST("/rooms", createRoomHandler)
		api.POST("/rooms/:id/join", joinRoomHandler)
		api.POST("/rooms/:id/leave", leaveRoomHandler)
		api.DELETE("/rooms/:id", deleteRoomHandler)
		api.GET("/rooms/:id/state", getRoomStateHandler)
		api.GET("/rooms/:id/history", getRoomHistoryHandler)

		// ─── v2.0 会话 REST API（HM-10/HM-11）───
		api.POST("/sessions", createSessionHandler)
		api.POST("/sessions/:id/join", joinSessionHandler)
		api.PATCH("/sessions/:id/roles", updateSessionRoleHandler)
		api.DELETE("/sessions/:id", deleteSessionHandler)
		api.POST("/sessions/:id/viewport/sub", viewportSubscribeHandler)
	}
	r.GET("/health", func(c *gin.Context) {
		if draining.Load() {
			// 驱逐中：readiness 失败，ELB/Service 停止向本 Pod 分发新连接
			c.JSON(503, gin.H{"status": "draining"})
			return
		}
		c.JSON(200, gin.H{"status": "ok"})
	})
	// /drain 由 deployment.yaml preStop Hook 调用，开始30秒连接驱逐流程
	r.GET("/drain", func(c *gin.Context) {
		if draining.CompareAndSwap(false, true) {
			log.Println("[drain] entering drain mode: stop new conns, notify clients to reconnect")
			// TODO(WS层集成): 遍历本 Pod 全部连接下发 MSG_ROOM_EVENT(REBALANCE)，
			// 客户端指数退避重连后通过 StateSync 增量追赶，用户无感知。
		}
		c.JSON(200, gin.H{"status": "draining"})
	})
}

// Handler stubs - 实际实现通过redis存储房间状态
func createRoomHandler(c *gin.Context) {
	c.JSON(201, gin.H{
		"code": 0,
		"data": gin.H{
			"room_id":     "r_a1b2c3d4",
			"name":        "example room",
			"join_code":   "123456",
			"nfc_token":   "nfc_hash_xxx",
			"ws_endpoint": "wss://ws.harmonycanvas.dev/ws?room=r_a1b2c3d4",
			"created_at":  time.Now().Format(time.RFC3339),
			"expires_at":  time.Now().Add(6 * time.Hour).Format(time.RFC3339),
		},
	})
}

func joinRoomHandler(c *gin.Context) {
	c.JSON(200, gin.H{
		"code": 0,
		"data": gin.H{
			"user_id":     "u_x1y2z3",
			"token":       "jwt_token_xxx",
			"ws_endpoint": "wss://ws.harmonycanvas.dev/ws?room=r_a1b2c3d4",
			"room_state": gin.H{
				"participants": 1,
				"layers":       []interface{}{},
				"snapshot_seq": 0,
			},
		},
	})
}

func leaveRoomHandler(c *gin.Context)  { c.JSON(200, gin.H{"code": 0}) }
func deleteRoomHandler(c *gin.Context) { c.JSON(200, gin.H{"code": 0}) }
func getRoomStateHandler(c *gin.Context) {
	c.JSON(200, gin.H{
		"code": 0,
		"data": gin.H{
			"participants": []gin.H{},
			"layer_count":  1,
			"stroke_count": 0,
		},
	})
}
func getRoomHistoryHandler(c *gin.Context) {
	c.JSON(200, gin.H{
		"code": 0,
		"data": gin.H{
			"ops":      []interface{}{},
			"has_more": false,
			"next_seq": 0,
		},
	})
}

// ─── v2.0 会话 Handler（HM-10/HM-11）───

type createSessionRequest struct {
	Name        string `json:"name"`
	NoteID      string `json:"note_id"`
	DefaultRole string `json:"default_role"`
	CreatorID   string `json:"creator_id"`
}

// createSessionHandler POST /sessions：创建笔记协作会话，创建者默认 EDITOR。
func createSessionHandler(c *gin.Context) {
	var req createSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"code": 1100, "error": "invalid request"})
		return
	}
	creatorID := req.CreatorID
	if creatorID == "" {
		creatorID = "u_creator"
	}
	defaultRole := auth.RoleAnnotator
	if auth.RoleFromString(req.DefaultRole) != auth.RoleUnknown {
		defaultRole = auth.RoleFromString(req.DefaultRole)
	}
	sessionID := "s_" + randHex(8)
	sess := sessStore.Create(sessionID, req.Name, req.NoteID, creatorID, "wss://ws.harmonycanvas.dev/ws?room="+sessionID, defaultRole, 6*time.Hour)
	permStore.CacheRole(sessionID, creatorID, auth.RoleEditor)

	assertion := permStore.SignAssertion(sessionID, creatorID, "d_creator", auth.RoleEditor, creatorID, 4*time.Hour)

	c.JSON(201, gin.H{
		"code": 0,
		"data": gin.H{
			"session_id":           sessionID,
			"name":                 sess.Name,
			"ws_endpoint":          sess.WSEndpoint,
			"default_role":         auth.RoleToString(defaultRole),
			"permission_assertion": assertionToMap(assertion),
			"expires_at":           sess.ExpiresAt.Format(time.RFC3339),
		},
	})
}

type joinSessionRequest struct {
	UserID   string `json:"user_id"`
	DeviceID string `json:"device_id"`
	WantRole string `json:"want_role"`
}

// joinSessionHandler POST /sessions/:id/join：加入会话并签发权限断言（卡片点击触发）。
func joinSessionHandler(c *gin.Context) {
	sessionID := c.Param("id")
	var req joinSessionRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"code": 1100, "error": "invalid request"})
		return
	}
	userID := req.UserID
	if userID == "" {
		userID = "u_guest"
	}
	sess, granted, err := sessStore.Join(sessionID, userID, auth.RoleFromString(req.WantRole))
	if err != nil {
		c.JSON(404, gin.H{"code": 1103, "error": err.Error()})
		return
	}
	permStore.CacheRole(sessionID, userID, granted)
	assertion := permStore.SignAssertion(sessionID, userID, req.DeviceID, granted, sess.CreatorID, 4*time.Hour)

	c.JSON(200, gin.H{
		"code": 0,
		"data": gin.H{
			"granted_role":         auth.RoleToString(granted),
			"permission_assertion": assertionToMap(assertion),
			"online_count":         sessStore.OnlineCount(sessionID),
		},
	})
}

type updateRoleRequest struct {
	OperatorID string `json:"operator_id"`
	UserID     string `json:"user_id"`
	NewRole    string `json:"new_role"`
}

// updateSessionRoleHandler PATCH /sessions/:id/roles：调整权限（仅创建者/EDITOR）。
func updateSessionRoleHandler(c *gin.Context) {
	sessionID := c.Param("id")
	var req updateRoleRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(400, gin.H{"code": 1100, "error": "invalid request"})
		return
	}
	if req.OperatorID == "" {
		c.JSON(403, gin.H{"code": 1101, "error": "operator required"})
		return
	}
	newRole := auth.RoleFromString(req.NewRole)
	if err := sessStore.UpdateRole(sessionID, req.OperatorID, req.UserID, newRole); err != nil {
		code := 1101
		if err == room.ErrNotFound {
			code = 1103
		}
		c.JSON(403, gin.H{"code": code, "error": err.Error()})
		return
	}
	permStore.CacheRole(sessionID, req.UserID, newRole)
	c.JSON(200, gin.H{"code": 0, "data": gin.H{"granted_role": auth.RoleToString(newRole)}})
}

// deleteSessionHandler DELETE /sessions/:id：结束会话 + 触发数据清理（仅创建者，HM-15）。
func deleteSessionHandler(c *gin.Context) {
	sessionID := c.Param("id")
	operatorID := c.Query("operator_id")
	if operatorID == "" {
		operatorID = c.GetHeader("X-User-Id")
	}
	if err := sessStore.Delete(sessionID, operatorID); err != nil {
		code := 1101
		if err == room.ErrNotFound {
			code = 1103
		}
		c.JSON(403, gin.H{"code": code, "error": err.Error()})
		return
	}
	c.JSON(200, gin.H{"code": 0, "data": gin.H{"cleaned": true, "audit_ref": "aud_" + randHex(8)}})
}

type viewportSubscribeRequest struct {
	Viewport map[string]float64 `json:"viewport"`
}

// viewportSubscribeHandler POST /sessions/:id/viewport/sub：注册/更新视口订阅（HM-14，P1 基础版）。
func viewportSubscribeHandler(c *gin.Context) {
	sessionID := c.Param("id")
	if _, err := sessStore.Get(sessionID); err != nil {
		c.JSON(404, gin.H{"code": 1103, "error": err.Error()})
		return
	}
	var req viewportSubscribeRequest
	_ = c.ShouldBindJSON(&req)
	c.JSON(200, gin.H{"code": 0, "data": gin.H{"subscribed": true, "session_id": sessionID}})
}

// ─── 工具 ───

func assertionToMap(a auth.PermissionAssertion) gin.H {
	return gin.H{
		"session_id": a.SessionID,
		"user_id":    a.UserID,
		"device_id":  a.DeviceID,
		"role":       auth.RoleToString(a.Role),
		"issuer":     a.Issuer,
		"issued_at":  a.IssuedAt,
		"expires_at": a.ExpiresAt,
		"signature":  a.Signature,
	}
}

func randHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}
