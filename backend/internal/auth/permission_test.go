// Package auth — QA 阶段二服务端权限模型测试（严过关，S2T02 / HM-11）
package auth

import (
	"strings"
	"testing"
	"time"
)

// TestSignVerifyAssertion 断言签发/校验：签名有效、篡改拒绝、过期拒绝。
func TestSignVerifyAssertion(t *testing.T) {
	store := NewPermissionStore("test-secret")
	a := store.SignAssertion("s_1", "u_1", "d_1", RoleEditor, "creator", time.Hour)
	if a.Signature == "" {
		t.Fatal("assertion signature must be non-empty")
	}
	if err := store.VerifyAssertion(a); err != nil {
		t.Fatalf("valid assertion rejected: %v", err)
	}
	// 篡改角色
	bad := a
	bad.Role = RoleViewer
	if err := store.VerifyAssertion(bad); err == nil {
		t.Fatal("tampered role must be rejected")
	}
	// 篡改 session
	bad2 := a
	bad2.SessionID = "s_evil"
	if err := store.VerifyAssertion(bad2); err == nil {
		t.Fatal("tampered session must be rejected")
	}
	// 过期
	expired := store.SignAssertion("s_1", "u_1", "d_1", RoleEditor, "creator", -time.Minute)
	if err := store.VerifyAssertion(expired); err == nil {
		t.Fatal("expired assertion must be rejected")
	}
}

// TestCheckOpAllowedFullMatrix 三级权限矩阵逐项（PRD §4.1）。
func TestCheckOpAllowedFullMatrix(t *testing.T) {
	store := NewPermissionStore("test-secret")
	store.CacheRole("s1", "viewer", RoleViewer)
	store.CacheRole("s1", "annotator", RoleAnnotator)
	store.CacheRole("s1", "editor", RoleEditor)

	cases := []struct {
		name        string
		user        string
		opKind      string
		elementType string
		wantErr     bool
	}{
		// VIEWER：一切写操作拒绝
		{"viewer insert stroke", "viewer", OpKindCRDTInsert, ElementStroke, true},
		{"viewer insert annotation", "viewer", OpKindCRDTInsert, ElementAnnotation, true},
		{"viewer delete stroke", "viewer", OpKindCRDTDelete, ElementStroke, true},
		{"viewer delete annotation", "viewer", OpKindCRDTDelete, ElementAnnotation, true},
		{"viewer layer op", "viewer", OpKindLayerOp, "", true},
		// ANNOTATOR：仅 annotation 元素操作；图层/素材拒绝
		{"annotator insert annotation", "annotator", OpKindCRDTInsert, ElementAnnotation, false},
		{"annotator delete annotation", "annotator", OpKindCRDTDelete, ElementAnnotation, false},
		{"annotator insert stroke", "annotator", OpKindCRDTInsert, ElementStroke, true},
		{"annotator insert shape", "annotator", OpKindCRDTInsert, ElementShape, true},
		{"annotator insert text_block", "annotator", OpKindCRDTInsert, ElementTextBlock, true},
		{"annotator insert image_ref", "annotator", OpKindCRDTInsert, ElementImageRef, true},
		{"annotator delete stroke", "annotator", OpKindCRDTDelete, ElementStroke, true},
		{"annotator layer op", "annotator", OpKindLayerOp, "", true},
		// EDITOR：全部允许
		{"editor insert stroke", "editor", OpKindCRDTInsert, ElementStroke, false},
		{"editor insert annotation", "editor", OpKindCRDTInsert, ElementAnnotation, false},
		{"editor insert image_ref", "editor", OpKindCRDTInsert, ElementImageRef, false},
		{"editor delete text_block", "editor", OpKindCRDTDelete, ElementTextBlock, false},
		{"editor layer op", "editor", OpKindLayerOp, "", false},
	}
	for _, tc := range cases {
		err := store.CheckOpAllowed("s1", tc.user, tc.opKind, tc.elementType)
		if tc.wantErr && err == nil {
			t.Errorf("%s: expected error, got nil", tc.name)
		}
		if !tc.wantErr && err != nil {
			t.Errorf("%s: expected allow, got %v", tc.name, err)
		}
	}
}

// TestRoleFromString 字符串→角色（未知回退 VIEWER 最保守）。
func TestRoleFromString(t *testing.T) {
	if RoleFromString("EDITOR") != RoleEditor {
		t.Fatal("EDITOR parse failed")
	}
	if RoleFromString("ANNOTATOR") != RoleAnnotator {
		t.Fatal("ANNOTATOR parse failed")
	}
	if RoleFromString("VIEWER") != RoleViewer {
		t.Fatal("VIEWER parse failed")
	}
	if RoleFromString("hacker") != RoleViewer {
		t.Fatal("unknown role must fall back to VIEWER")
	}
	if RoleFromString("") != RoleViewer {
		t.Fatal("empty role must fall back to VIEWER")
	}
}

// TestRoleToStringRoundTrip 角色→字符串→角色 往返。
func TestRoleToStringRoundTrip(t *testing.T) {
	for _, r := range []SessionRole{RoleViewer, RoleAnnotator, RoleEditor} {
		if RoleFromString(RoleToString(r)) != r {
			t.Fatalf("round trip failed for %d", r)
		}
	}
}

// TestUnregisteredUserDefaultViewer 未登记用户默认 VIEWER（最保守）。
func TestUnregisteredUserDefaultViewer(t *testing.T) {
	store := NewPermissionStore("x")
	if err := store.CheckOpAllowed("s1", "nobody", OpKindCRDTInsert, ElementStroke); err == nil {
		t.Fatal("unregistered user must default to VIEWER and be denied")
	}
	if !strings.Contains(errorsText(store.CheckOpAllowed("s1", "nobody", OpKindCRDTInsert, ElementStroke)), "1101") {
		t.Fatal("denial error should carry code 1101")
	}
}

// TestUnknownOpKind 未知操作类型报错。
func TestUnknownOpKind(t *testing.T) {
	store := NewPermissionStore("x")
	store.CacheRole("s1", "e", RoleEditor)
	if err := store.CheckOpAllowed("s1", "e", "crdt_whatever", ""); err == nil {
		t.Fatal("unknown op kind must error")
	}
}

func errorsText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
