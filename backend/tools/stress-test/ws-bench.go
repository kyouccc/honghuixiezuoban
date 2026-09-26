// ws-bench 鸿绘协作板 WebSocket 压力测试工具（TC-07/TC-08 验证）
//
// 用途：
//  1. 单房间50人×30分钟稳定性压测（TC-07）
//  2. 万人并发+HPA扩缩观测（TC-08，配合多机分布式启动）
//
// 用法：
//
//	go run ws-bench.go -addr wss://ws.harmonycanvas.dev/ws -room r_xxx \
//	    -conns 50 -duration 30m -rate 2
//
// 输出：连接成功率、断连次数、消息RTT P50/P95/P99、吞吐msg/s，
// 结果可直接填入 docs/verification-report-template.md。
package main

import (
	"flag"
	"fmt"
	"math/rand"
	"net/url"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
)

var (
	addr     = flag.String("addr", "ws://localhost:8081/ws", "WebSocket地址")
	room     = flag.String("room", "r_bench", "房间ID")
	conns    = flag.Int("conns", 50, "并发连接数")
	duration = flag.Duration("duration", 30*time.Minute, "压测时长")
	rate     = flag.Float64("rate", 2, "每连接消息速率(msg/s)，模拟人均书写频率")
)

// stats 全局统计（原子操作）
type stats struct {
	connOK      atomic.Int64
	connFail    atomic.Int64
	disconnects atomic.Int64
	msgSent     atomic.Int64
	msgRecv     atomic.Int64
}

var latMu sync.Mutex
var latencies []time.Duration

func recordLatency(d time.Duration) {
	latMu.Lock()
	latencies = append(latencies, d)
	latMu.Unlock()
}

func percentile(p float64) time.Duration {
	latMu.Lock()
	defer latMu.Unlock()
	if len(latencies) == 0 {
		return 0
	}
	sorted := make([]time.Duration, len(latencies))
	copy(sorted, latencies)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	idx := int(float64(len(sorted)) * p)
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

// runClient 单个模拟客户端：连接→按速率发送笔画消息→收广播测RTT。
// 断线后按指数退避自动重连（模拟真实客户端行为），计入断连统计。
func runClient(id int, st *stats, deadline time.Time, wg *sync.WaitGroup) {
	defer wg.Done()

	u := fmt.Sprintf("%s?room=%s&user=u_bench_%d", *addr, url.QueryEscape(*room), id)
	backoff := 100 * time.Millisecond

	for time.Now().Before(deadline) {
		conn, _, _, err := ws.Dial(nil, u)
		if err != nil {
			st.connFail.Add(1)
			time.Sleep(backoff)
			if backoff < 5*time.Second {
				backoff *= 2
			}
			continue
		}
		st.connOK.Add(1)
		backoff = 100 * time.Millisecond

		sendTicker := time.NewTicker(time.Duration(float64(time.Second) / *rate))
		recvDone := make(chan struct{})

		// 接收协程：读广播消息，提取回显时间戳计算RTT
		go func() {
			defer close(recvDone)
			for {
				msgs, err := wsutil.ReadServerMessage(conn, nil)
				if err != nil {
					return
				}
				for _, m := range msgs {
					st.msgRecv.Add(1)
					// 协议约定：消息前8字节为发送端UnixNano时间戳
					if len(m.Payload) >= 8 {
						sent := int64(m.Payload[0])<<56 | int64(m.Payload[1])<<48 |
							int64(m.Payload[2])<<40 | int64(m.Payload[3])<<32 |
							int64(m.Payload[4])<<24 | int64(m.Payload[5])<<16 |
							int64(m.Payload[6])<<8 | int64(m.Payload[7])
						if rtt := time.Since(time.Unix(0, sent)); rtt > 0 && rtt < 10*time.Second {
							recordLatency(rtt)
						}
					}
				}
			}
		}()

		// 发送循环：模拟 CRDT InsertOp（时间戳 + 随机笔画负载 ~1KB）
		payload := make([]byte, 8+1024)
		rand.Read(payload[8:])
	loop:
		for {
			select {
			case <-recvDone:
				break loop // 连接已断
			case <-sendTicker.C:
				if time.Now().After(deadline) {
					break loop
				}
				now := time.Now().UnixNano()
				for i := 0; i < 8; i++ {
					payload[i] = byte(now >> (56 - 8*i))
				}
				if err := wsutil.WriteClientMessage(conn, ws.OpBinary, payload); err != nil {
					break loop
				}
				st.msgSent.Add(1)
			}
		}

		sendTicker.Stop()
		conn.Close()
		if time.Now().Before(deadline) {
			st.disconnects.Add(1)
		}
	}
}

func main() {
	flag.Parse()
	rand.Seed(time.Now().UnixNano())

	fmt.Printf("=== 鸿绘协作板 WS压测 ===\n")
	fmt.Printf("目标: %s | 房间: %s | 连接: %d | 时长: %s | 速率: %.1f msg/s/conn\n",
		*addr, *room, *conns, *duration, *rate)

	var st stats
	var wg sync.WaitGroup
	start := time.Now()
	deadline := start.Add(*duration)

	// 分批建立连接（每秒50个，模拟真实加入而非瞬时风暴）
	ticker := time.NewTicker(time.Second / 50)
	for i := 0; i < *conns; i++ {
		<-ticker.C
		wg.Add(1)
		go runClient(i, &st, deadline, &wg)
	}
	ticker.Stop()

	// 每分钟输出中间状态
	report := time.NewTicker(time.Minute)
	done := make(chan struct{})
	go func() {
		for {
			select {
			case <-done:
				return
			case t := <-report.C:
				fmt.Printf("[%s] 在线≈%d 断连累计=%d 已发=%d 已收=%d RTT P95=%v\n",
					t.Format("15:04:05"), st.connOK.Load()-st.disconnects.Load(),
					st.disconnects.Load(), st.msgSent.Load(), st.msgRecv.Load(),
					percentile(0.95))
			}
		}
	}()

	wg.Wait()
	report.Stop()
	close(done)

	elapsed := time.Since(start)
	fmt.Printf("\n=== 压测报告（填入验证报告附录）===\n")
	fmt.Printf("实际时长:        %v\n", elapsed.Round(time.Second))
	fmt.Printf("连接成功/失败:   %d / %d\n", st.connOK.Load(), st.connFail.Load())
	fmt.Printf("断连次数:        %d（TC-07要求: 0）\n", st.disconnects.Load())
	fmt.Printf("消息 发/收:      %d / %d\n", st.msgSent.Load(), st.msgRecv.Load())
	fmt.Printf("平均吞吐:        %.0f msg/s\n", float64(st.msgRecv.Load())/elapsed.Seconds())
	fmt.Printf("RTT P50/P95/P99: %v / %v / %v（TC-05要求: P95≤150ms）\n",
		percentile(0.50), percentile(0.95), percentile(0.99))
}
