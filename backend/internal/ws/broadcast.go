// Package ws 跨Pod消息广播：Redis Pub/Sub 按 roomId 一致性哈希分片
//
// 架构文档 §1.3.5 的实现。
// 问题背景：WebSocket 是有状态连接，同一房间 50 人的连接经 ELB 散落到多个 Pod，
// 若广播仅在本 Pod 内进行，跨 Pod 成员收不到彼此的操作。
// 本模块让每个信号网关 Pod 订阅全部 64 个 shard channel，
// 写入侧按 crc32(roomId)%64 选择 channel 发布，接收侧筛选本 Pod 持有的连接扇出。
package ws

import (
	"context"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"
)

const (
	// ShardCount shard 数量。50 Pod × 单房间峰值 200msg/s →
	// 单 channel 流量 <160msg/s，远低于 Redis 单 channel 上限。
	ShardCount = 64

	// channelPrefix Redis channel 前缀：room:{shard}
	channelPrefix = "room:"
)

// LocalFanout 本 Pod 连接扇出接口，由 Hub 实现。
// 返回值为本次扇出的本 Pod 连接数（用于指标统计）。
type LocalFanout interface {
	FanoutLocal(roomID string, payload []byte) int
	HasRoom(roomID string) bool
}

// Broadcaster 跨 Pod 广播器。
// 同一房间的消息经由同一 shard channel，Redis 单 channel 保序，
// 配合服务端分配的全局操作序号，因果序不破坏。
type Broadcaster struct {
	rdb    *redis.Client
	fanout LocalFanout
	log    *zap.Logger

	mu     sync.RWMutex
	closed bool
	cancel context.CancelFunc
	wg     sync.WaitGroup

	// 指标
	publishTotal    uint64
	deliverTotal    uint64
	fanoutConnTotal uint64
}

// NewBroadcaster 创建广播器。fanout 可在 Start 前通过 SetLocalFanout 注入。
func NewBroadcaster(rdb *redis.Client, fanout LocalFanout, log *zap.Logger) *Broadcaster {
	return &Broadcaster{rdb: rdb, fanout: fanout, log: log}
}

// SetLocalFanout 注入本 Pod 连接扇出实现（Hub）。需在 Start 前调用。
func (b *Broadcaster) SetLocalFanout(f LocalFanout) {
	b.fanout = f
}

// Shard 计算房间的 shard 编号。
func Shard(roomID string) int {
	return int(crc32.ChecksumIEEE([]byte(roomID)) % ShardCount)
}

// channelName 返回 shard 对应的 channel 名。
func channelName(shard int) string {
	return fmt.Sprintf("%s%d", channelPrefix, shard)
}

// Start 启动全部 shard 的订阅 goroutine。幂等。
func (b *Broadcaster) Start(ctx context.Context) {
	ctx, cancel := context.WithCancel(ctx)
	b.cancel = cancel

	// 64 个 shard 合并为一次 PSubscribe 模式订阅，避免 64 条连接。
	// Redis 单连接即可承载全部订阅流量（10K msg/s @50 Pod 上限）。
	b.wg.Add(1)
	go b.subscribeLoop(ctx, fmt.Sprintf("%s*", channelPrefix))
}

// Publish 将房间内消息发布到对应 shard channel。
// payload 为已序列化的 SignalEnvelope；发布时自动加 2 字节房间ID长度 +
// 房间ID 前缀，订阅侧 dispatch 据此解析并扇出到本 Pod 持有该房间的连接。
func (b *Broadcaster) Publish(ctx context.Context, roomID string, payload []byte) error {
	b.mu.RLock()
	if b.closed {
		b.mu.RUnlock()
		return fmt.Errorf("broadcaster closed")
	}
	b.mu.RUnlock()

	body := make([]byte, 2+len(roomID)+len(payload))
	binary.BigEndian.PutUint16(body[:2], uint16(len(roomID)))
	copy(body[2:], roomID)
	copy(body[2+len(roomID):], payload)

	ch := channelName(Shard(roomID))
	if err := b.rdb.Publish(ctx, ch, body).Err(); err != nil {
		return fmt.Errorf("publish %s: %w", ch, err)
	}
	b.publishTotal++
	return nil
}

// subscribeLoop 订阅循环，断线自动重连（指数退避，上限5s）。
func (b *Broadcaster) subscribeLoop(ctx context.Context, pattern string) {
	defer b.wg.Done()

	backoff := 100 * time.Millisecond
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		pubsub := b.rdb.PSubscribe(ctx, pattern)
		b.log.Info("broadcaster subscribed", zap.String("pattern", pattern))

		err := b.consume(ctx, pubsub)
		pubsub.Close()

		if ctx.Err() != nil {
			return
		}
		b.log.Warn("broadcaster resubscribing",
			zap.Error(err), zap.Duration("backoff", backoff))

		select {
		case <-ctx.Done():
			return
		case <-time.After(backoff):
		}
		if backoff < 5*time.Second {
			backoff *= 2
		}
	}
}

// consume 消费消息直到出错或取消。
func (b *Broadcaster) consume(ctx context.Context, pubsub *redis.PubSub) error {
	ch := pubsub.Channel()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case msg, ok := <-ch:
			if !ok {
				return fmt.Errorf("pubsub channel closed")
			}
			b.dispatch(msg.Payload)
		}
	}
}

// dispatch 将收到的消息扇出到本 Pod 持有该房间的连接。
// payload 前 2 字节为 roomID 长度，随后为 roomID，剩余为 SignalEnvelope 字节流。
func (b *Broadcaster) dispatch(payload string) {
	raw := []byte(payload)
	if len(raw) < 2 {
		return
	}
	idLen := int(binary.BigEndian.Uint16(raw[:2]))
	if len(raw) < 2+idLen {
		return
	}
	roomID := string(raw[2 : 2+idLen])
	envelope := raw[2+idLen:]

	if !b.fanout.HasRoom(roomID) {
		return // 本 Pod 无该房间连接，直接丢弃（广播放大的固有成本）
	}
	n := b.fanout.FanoutLocal(roomID, envelope)
	b.deliverTotal++
	b.fanoutConnTotal += uint64(n)
}

// Close 停止订阅并等待退出。
func (b *Broadcaster) Close() {
	b.mu.Lock()
	b.closed = true
	b.mu.Unlock()
	if b.cancel != nil {
		b.cancel()
	}
	b.wg.Wait()
}

// Stats 返回累计指标（接入 monitor.go 的 Prometheus 导出）。
func (b *Broadcaster) Stats() (publish, deliver, fanoutConn uint64) {
	return b.publishTotal, b.deliverTotal, b.fanoutConnTotal
}
