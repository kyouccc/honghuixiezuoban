// Package crdt — QA 阶段二服务端中继权限校验测试（严过关，S2T02/S2T03）
package crdt

import (
	"encoding/json"
	"testing"

	"honghui/backend/internal/auth"
)

// buildEnvelope 构造最小 SignalEnvelope TLV：field2=msg_type(varint), field3=payload(length-delimited)。
func buildEnvelope(msgType int, payload []byte) []byte {
	var out []byte
	// field 2 (msg_type, wire type 0): tag=0x10
	out = append(out, encodeVarint(2<<3|0)...)
	out = append(out, encodeVarint(uint64(msgType))...)
	// field 3 (payload, wire type 2): tag=0x1A
	out = append(out, encodeVarint(3<<3|2)...)
	out = append(out, encodeVarint(uint64(len(payload)))...)
	out = append(out, payload...)
	return out
}

func encodeVarint(v uint64) []byte {
	var out []byte
	for v > 127 {
		out = append(out, byte(v&0x7F|0x80))
		v >>= 7
	}
	out = append(out, byte(v))
	return out
}

// TestRelayCheckMessagePermission 服务端每操作权限校验（广播前拦截）。
func TestRelayCheckMessagePermission(t *testing.T) {
	store := auth.NewPermissionStore("secret")
	store.CacheRole("s1", "viewer", auth.RoleViewer)
	store.CacheRole("s1", "annotator", auth.RoleAnnotator)
	store.CacheRole("s1", "editor", auth.RoleEditor)
	relay := NewRelay(store)

	cases := []struct {
		name    string
		user    string
		msgType int
		payload map[string]string
		wantErr bool
	}{
		// annotator 插入 annotation → 放行
		{"annotator insert annotation", "annotator", MsgCRDTOp, map[string]string{"type": "insert", "elementType": "annotation"}, false},
		// annotator 插入 stroke → 拒绝
		{"annotator insert stroke", "annotator", MsgCRDTOp, map[string]string{"type": "insert", "elementType": "stroke"}, true},
		// viewer 任何 CRDT → 拒绝
		{"viewer insert stroke", "viewer", MsgCRDTOp, map[string]string{"type": "insert", "elementType": "stroke"}, true},
		{"viewer delete annotation", "viewer", MsgCRDTOp, map[string]string{"type": "delete", "elementType": "annotation"}, true},
		// editor 任意 → 放行
		{"editor insert image", "editor", MsgCRDTOp, map[string]string{"type": "insert", "elementType": "image_ref"}, false},
		{"editor delete shape", "editor", MsgCRDTOp, map[string]string{"type": "delete", "elementType": "shape"}, false},
		// LayerOp：仅 editor
		{"annotator layer op", "annotator", MsgLayerOp, map[string]string{}, true},
		{"viewer layer op", "viewer", MsgLayerOp, map[string]string{}, true},
		{"editor layer op", "editor", MsgLayerOp, map[string]string{}, false},
	}
	for _, tc := range cases {
		payload, _ := json.Marshal(tc.payload)
		env := buildEnvelope(tc.msgType, payload)
		err := relay.CheckMessage("s1", tc.user, env)
		if tc.wantErr && err == nil {
			t.Errorf("%s: expected rejection, got allow", tc.name)
		}
		if !tc.wantErr && err != nil {
			t.Errorf("%s: expected allow, got %v", tc.name, err)
		}
	}
}

// TestRelayNonCRDTOpAllowed 非 CRDT/LayerOp 消息（视口同步等）不参与校验，放行。
func TestRelayNonCRDTOpAllowed(t *testing.T) {
	store := auth.NewPermissionStore("x")
	relay := NewRelay(store)
	env := buildEnvelope(MsgViewportSync, []byte(`{"center_x":1}`))
	if err := relay.CheckMessage("s1", "viewer", env); err != ErrNotCRDTOp {
		t.Fatalf("viewport sync should be allowed (ErrNotCRDTOp), got %v", err)
	}
	// 权限断言消息本身放行
	env2 := buildEnvelope(MsgPermissionAssert, []byte(`{"role":1}`))
	if err := relay.CheckMessage("s1", "viewer", env2); err != nil {
		t.Fatalf("permission assert should be allowed, got %v", err)
	}
}

// TestRelayParseCRDTOpFallback 未标注 elementType 的 delete 回退 stroke（服务端保守行为：拒绝批注者删批注）。
// Round 2 保留该负向用例；客户端 E-3 修复后 DeleteOp 已携带 elementType，正向用例见 TestRelayAnnotatorDeleteAnnotationWithType。
func TestRelayParseCRDTOpFallback(t *testing.T) {
	store := auth.NewPermissionStore("x")
	store.CacheRole("s1", "annotator", auth.RoleAnnotator)
	relay := NewRelay(store)
	// 模拟旧客户端 sendOperation(deleteOp) —— DeleteOp JSON 不含 elementType
	payload := []byte(`{"type":"delete","targetId":{"lamportTs":1,"siteId":"a"},"vectorClock":{"a":1},"timestamp":1}`)
	env := buildEnvelope(MsgCRDTOp, payload)
	err := relay.CheckMessage("s1", "annotator", env)
	if err == nil {
		t.Fatal("annotator delete (no elementType -> fallback stroke) must be REJECTED by server (conservative fallback)")
	}
}

// TestRelayAnnotatorDeleteAnnotationWithType E-3 修复验证：客户端 DeleteOp 携带 elementType=annotation，
// Annotator 删除自己的批注被服务端接受（PRD §4.1「删除/修改自己批注 ✅」）。
func TestRelayAnnotatorDeleteAnnotationWithType(t *testing.T) {
	store := auth.NewPermissionStore("x")
	store.CacheRole("s1", "annotator", auth.RoleAnnotator)
	relay := NewRelay(store)
	payload := []byte(`{"type":"delete","elementType":"annotation","targetId":{"lamportTs":1,"siteId":"a"},"vectorClock":{"a":1},"timestamp":1}`)
	env := buildEnvelope(MsgCRDTOp, payload)
	if err := relay.CheckMessage("s1", "annotator", env); err != nil {
		t.Fatalf("annotator delete annotation WITH elementType must be accepted, got %v", err)
	}
	// annotator 删除 stroke（带 elementType）仍被拒
	payload2 := []byte(`{"type":"delete","elementType":"stroke","targetId":{"lamportTs":1,"siteId":"a"},"vectorClock":{"a":1},"timestamp":1}`)
	env2 := buildEnvelope(MsgCRDTOp, payload2)
	if err := relay.CheckMessage("s1", "annotator", env2); err == nil {
		t.Fatal("annotator delete stroke (with elementType) must be REJECTED")
	}
}

// TestRelayMalformedEnvelope 畸形信封拒绝。
func TestRelayMalformedEnvelope(t *testing.T) {
	store := auth.NewPermissionStore("x")
	relay := NewRelay(store)
	if err := relay.CheckMessage("s1", "u", []byte{}); err == nil {
		t.Fatal("empty envelope must error")
	}
}
