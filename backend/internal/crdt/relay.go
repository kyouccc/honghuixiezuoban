// Package crdt 提供 v2.0 CRDT 操作中继（S2T03/HM-13）：
//   - 每 CRDT/LayerOp 消息权限查表校验（服务端，Q-07）；
//   - CanvasElement 全类型中继（Stroke/Shape/TextBlock/Annotation/ImageRef）；
//   - 最小 SignalEnvelope 解析（TLV），供 WS 接入层在广播前做权限拦截。
package crdt

import (
	"encoding/json"
	"errors"

	"honghui/backend/internal/auth"
)

// 消息类型（与 proto MsgType 对齐）
const (
	MsgCRDTOp           = 1
	MsgCursorSync       = 2
	MsgRoomEvent        = 3
	MsgStateSync        = 4
	MsgHeartbeat        = 5
	MsgLayerOp          = 6
	MsgViewportSync     = 8
	MsgPermissionAssert = 9
	MsgViewportSub      = 10
	MsgViewportDiff     = 11
)

// ErrNotCRDTOp 非 CRDT/图层操作消息（不参与权限校验，放行）。
var ErrNotCRDTOp = errors.New("not a crdt/layer message")

// Relay CRDT 操作中继：封装权限校验逻辑，供 WS 接入层广播前调用。
type Relay struct {
	perms *auth.PermissionStore
}

// NewRelay 创建中继。
func NewRelay(perms *auth.PermissionStore) *Relay {
	return &Relay{perms: perms}
}

// CheckMessage 校验单条 SignalEnvelope 消息（WS readPump 广播前调用）。
// 返回 nil=放行；ErrNotCRDTOp=非 CRDT/LayerOp 消息（放行）；其他 error=拒绝。
func (r *Relay) CheckMessage(sessionID, userID string, payload []byte) error {
	msgType, inner, err := parseEnvelope(payload)
	if err != nil {
		return err
	}
	switch msgType {
	case MsgCRDTOp:
		opType, elementType := parseCRDTOpJSON(inner)
		return r.perms.CheckOpAllowed(sessionID, userID, opType, elementType)
	case MsgLayerOp:
		return r.perms.CheckOpAllowed(sessionID, userID, auth.OpKindLayerOp, "")
	case MsgPermissionAssert:
		// 权限断言消息本身放行（角色登记在 REST join 时已完成）
		return nil
	default:
		return ErrNotCRDTOp
	}
}

// HandleCRDTOp 显式校验 CRDT 操作（REST/内部调用用）。
func (r *Relay) HandleCRDTOp(sessionID, userID, opType, elementType string) error {
	return r.perms.CheckOpAllowed(sessionID, userID, opType, elementType)
}

// CheckLayerOp 显式校验图层操作。
func (r *Relay) CheckLayerOp(sessionID, userID string) error {
	return r.perms.CheckOpAllowed(sessionID, userID, auth.OpKindLayerOp, "")
}

// crdtOpJSON 客户端 CRDT 操作 JSON 负载（与 ArkTS InsertOp 对齐）。
type crdtOpJSON struct {
	Type        string `json:"type"`
	ElementType string `json:"elementType"`
}

// parseCRDTOpJSON 从 CRDT 操作 JSON 提取 opType/elementType。
func parseCRDTOpJSON(inner []byte) (string, string) {
	var op crdtOpJSON
	_ = json.Unmarshal(inner, &op)
	opType := auth.OpKindCRDTInsert
	if op.Type == "delete" {
		opType = auth.OpKindCRDTDelete
	}
	elementType := op.ElementType
	if elementType == "" {
		elementType = auth.ElementStroke // 未标注回退 stroke
	}
	return opType, elementType
}

// parseEnvelope 最小 SignalEnvelope TLV 解析：
// field 2 (varint) = msg_type，field 3 (length-delimited) = payload。
func parseEnvelope(data []byte) (int, []byte, error) {
	pos := 0
	msgType := 0
	var inner []byte
	for pos < len(data) {
		tag, n, err := readVarint(data, pos)
		if err != nil {
			return 0, nil, err
		}
		pos = n
		fieldNum := tag >> 3
		wireType := tag & 0x07
		if wireType == 0 {
			v, n2, err := readVarint(data, pos)
			if err != nil {
				return 0, nil, err
			}
			pos = n2
			if fieldNum == 2 {
				msgType = int(v)
			}
		} else if wireType == 2 {
			length, n2, err := readVarint(data, pos)
			if err != nil {
				return 0, nil, err
			}
			pos = n2
			if pos+int(length) > len(data) {
				return 0, nil, errors.New("envelope payload out of range")
			}
			if fieldNum == 3 {
				inner = data[pos : pos+int(length)]
			}
			pos += int(length)
		} else {
			// 未知 wire type：跳过（P0 不解析）
			return 0, nil, errors.New("unsupported wire type")
		}
	}
	if msgType == 0 && len(inner) == 0 {
		return 0, nil, errors.New("empty envelope")
	}
	return msgType, inner, nil
}

// readVarint 读取 protobuf varint。
func readVarint(data []byte, pos int) (uint64, int, error) {
	var value uint64
	shift := 0
	for pos < len(data) {
		b := data[pos]
		value |= uint64(b&0x7F) << shift
		pos++
		if b&0x80 == 0 {
			return value, pos, nil
		}
		shift += 7
		if shift > 63 {
			return 0, pos, errors.New("varint overflow")
		}
	}
	return 0, pos, errors.New("varint truncated")
}
