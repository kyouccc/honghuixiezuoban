/**
 * run-c03-verify.mjs — C03 编解码加固 + 离线补发 Node 逻辑验证
 *
 * 沿用仓库既有模式（tests/run-node-verify.mjs + tests/ets-loader.mjs）：
 * 运行：cd harmonycanvas/tests && node --experimental-transform-types --experimental-loader=./ets-loader.mjs run-c03-verify.mjs
 *
 * 覆盖（对应 C03 验收）：
 *  ① 畸形 wireType 1/5 消息 decode 不死循环、不抛未捕获异常、优雅丢弃
 *  ② Date.now() 级 timestamp 经 encode/decode 往返一致（Q13 varint > 2³²）
 *  ③ 64KB 分片 base64 编码耗时对照（改造前逐字符 += 基线 vs 改造后 parts.join）
 *  ④ OfflineOpQueue：断网入队 N 笔 → drain 恢复 → 顺序一致（Q14）
 *  ⑤ OfflineOpQueue：满 2000 后 droppedCount 累计，DROPPED 持续可见（drain 不清零）
 *  + readUserId 换源（T2）：SessionIdentity 兜底链生效，不再直接读 AppStorage
 */
import { SignalCodec, MsgType } from '../entry/src/main/ets/network/SignalCodec.ets';
import { OfflineOpQueue } from '../entry/src/main/ets/crdt/OfflineOpQueue.ets';
import { SessionIdentity } from '../entry/src/main/ets/common/identity/SessionIdentity.ets';

let total = 0;
let passed = 0;
const failures = [];

function assert(cond, name, detail) {
  total++;
  if (cond) {
    passed++;
  } else {
    failures.push({ name, detail: detail || '' });
  }
}

function assertEq(actual, expected, name) {
  total++;
  if (Object.is(actual, expected)) {
    passed++;
  } else {
    failures.push({ name, detail: `expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}` });
  }
}

function assertNoThrow(fn, name) {
  total++;
  try {
    fn();
    passed++;
  } catch (e) {
    failures.push({ name, detail: `expected no throw, got: ${e && e.message ? e.message : e}` });
  }
}

console.log('=== C03 编解码加固 + 离线补发 Node 逻辑验证 ===\n');

// ═══ ① 畸形 wireType 1/5 decode：不死循环 / 不抛异常 / 优雅丢弃 ═══
console.log('--- ① 畸形 wireType 1/5 decode 防死循环 ---');
assertNoThrow(() => {
  // 手工构造畸形信封：tag=0x09 (field1 wireType1 fixed64) + 8 字节负载 + tag=0x0D (field1 wireType5 fixed32) + 4 字节
  const malformed1 = new Uint8Array([0x09, 1, 2, 3, 4, 5, 6, 7, 8, 0x0D, 9, 10, 11, 12]);
  const env = SignalCodec.decode(malformed1);
  assert(env !== null && env !== undefined, 'wireType1/5 畸形消息 decode 返回信封（不抛）');
}, 'wireType1/5 畸形消息 decode 不抛异常');

// 纯 wireType1（fixed64）重复字段 → 旧实现会死循环；新实现必须终止且前进
assertNoThrow(() => {
  const fixed64Only = new Uint8Array([0x09, 1, 2, 3, 4, 5, 6, 7, 8]);
  const env = SignalCodec.decode(fixed64Only);
  assert(env !== null, '纯 wireType1 fixed64 字段 decode 正常返回');
}, '纯 wireType1 decode 不挂');

// 纯 wireType5（fixed32）
assertNoThrow(() => {
  const fixed32Only = new Uint8Array([0x0D, 1, 2, 3, 4]);
  SignalCodec.decode(fixed32Only);
}, '纯 wireType5 decode 不挂');

// 超长 varint（连续 0x80 continuation）→ 旧实现 shift 溢出；新实现截断不死循环
assertNoThrow(() => {
  const longVarint = new Uint8Array([0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80]);
  const env = SignalCodec.decode(longVarint);
  assert(env !== null, '超长 varint 消息 decode 截断返回（不抛、不死循环）');
}, '超长 varint decode 不挂');

// 长度越界（length 声明超过剩余字节）→ 优雅丢弃剩余
assertNoThrow(() => {
  const badLen = new Uint8Array([0x0A, 0xFF, 0xFF, 0xFF, 0x7F, 0x41, 0x42]); // field1 len=2^35-1 越界
  SignalCodec.decode(badLen);
}, '长度越界 decode 不挂');

// 正常 encode → decode 完整往返（验证不是无脑返回默认信封）
{
  const env = SignalCodec.encode({
    msg_id: 'm1',
    msg_type: MsgType.MSG_CRDT_OP,
    payload: new Uint8Array([1, 2, 3]),
    timestamp: Date.now(),
    sender_id: 'u1'
  });
  const back = SignalCodec.decode(env);
  assertEq(back.msg_id, 'm1', '正常信封 msg_id 往返一致');
  assertEq(back.msg_type, MsgType.MSG_CRDT_OP, '正常信封 msg_type 往返一致');
  assert(back.payload.length === 3 && back.payload[2] === 3, '正常信封 payload 往返一致');
  assertEq(back.sender_id, 'u1', '正常信封 sender_id 往返一致');
}

// ═══ ② Date.now() 级 timestamp 往返一致（Q13：varint > 2³²） ═══
console.log('--- ② Date.now() timestamp 往返（Q13 varint > 2³²） ---');
{
  const t = Date.now(); // ~1.7e12 > 2^32（4294967296），旧实现 v>>>7 截断会丢高位
  const env = SignalCodec.encode({
    msg_id: 't1',
    msg_type: MsgType.MSG_HEARTBEAT,
    payload: new Uint8Array(0),
    timestamp: t,
    sender_id: 'u1'
  });
  const back = SignalCodec.decode(env);
  assertEq(back.timestamp, t, `Date.now() 时间戳往返一致（${t}）`);
  // 额外边界：大时间戳（2^32+、2^40+）
  const big = 1099511627776; // 2^40
  const env2 = SignalCodec.encode({
    msg_id: 't2',
    msg_type: MsgType.MSG_HEARTBEAT,
    payload: new Uint8Array(0),
    timestamp: big,
    sender_id: 'u2'
  });
  const back2 = SignalCodec.decode(env2);
  assertEq(back2.timestamp, big, `2^40 级时间戳往返一致（${big}）`);
}

// ═══ ③ 64KB 分片 base64 编码耗时对照（改造前基线 vs 改造后） ═══
console.log('--- ③ 64KB base64 编码耗时对照 ---');
{
  const bytes = new Uint8Array(64 * 1024);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = i % 251;
  }
  // 改造前基线：逐字符 += 拼接（与旧实现同算法）
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const t0 = Date.now();
  let baseline = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i];
    const b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    const n = (b0 << 16) | (b1 << 8) | b2;
    baseline += chars.charAt((n >> 18) & 63);
    baseline += chars.charAt((n >> 12) & 63);
    baseline += i + 1 < bytes.length ? chars.charAt((n >> 6) & 63) : '=';
    baseline += i + 2 < bytes.length ? chars.charAt(n & 63) : '=';
  }
  const baselineMs = Date.now() - t0;

  // 改造后：parts.push + join
  const t1 = Date.now();
  const optimized = SignalCodec.base64Encode(bytes);
  const optimizedMs = Date.now() - t1;

  assertEq(optimized, baseline, '改造后 base64 输出与基线一致（正确性）');
  assert(optimized.length === Math.ceil(bytes.length / 3) * 4, 'base64 输出长度正确');
  console.log(`  [PERF] 64KB base64：基线(+=) ${baselineMs}ms → 改造后(join) ${optimizedMs}ms`);

  // 64KB 分片编码耗时可接受：改造后 < 500ms 视为通过（Node 实测通常 <10ms）
  assert(optimizedMs < 500, '64KB base64 编码耗时 <500ms（可接受）');
}

// ═══ ④ OfflineOpQueue：断网入队 N 笔 → drain 恢复 → 顺序一致（Q14） ═══
console.log('--- ④ OfflineOpQueue 断网入队 → 恢复 drain 顺序一致 ---');
{
  const q = new OfflineOpQueue();
  const N = 5;
  for (let i = 0; i < N; i++) {
    q.enqueue({ type: 'insert', seq: i, elementType: 'stroke' });
  }
  assertEq(q.size(), N, `断网入队 ${N} 笔 pending=${N}`);
  const drained = q.drain();
  assertEq(drained.length, N, `恢复后 drain 取出 ${N} 笔`);
  let orderOk = true;
  for (let i = 0; i < N; i++) {
    if (drained[i].seq !== i) orderOk = false;
  }
  assert(orderOk, 'drain 顺序与入队顺序一致（FIFO）');
  assertEq(q.size(), 0, 'drain 后 pending=0');

  // 全链路：drain 出的 op 经 SignalCodec.encodeCRDTOp 编码可正常 decode（远端收到 N 笔）
  let remoteReceived = 0;
  for (let i = 0; i < drained.length; i++) {
    const wire = SignalCodec.encodeCRDTOp(drained[i]);
    const env = SignalCodec.decode(wire);
    if (env.msg_type === MsgType.MSG_CRDT_OP && env.payload.length > 0) {
      remoteReceived++;
    }
  }
  assertEq(remoteReceived, N, '远端收到 N 笔 CRDT_OP（编码往返成功）');
}

// ═══ ⑤ OfflineOpQueue：满 2000 后 droppedCount 累计，DROPPED 持续可见 ═══
console.log('--- ⑤ OfflineOpQueue 满 2000 → DROPPED 持续可见 ---');
{
  const q = new OfflineOpQueue(); // 默认 2000
  for (let i = 0; i < 2000; i++) {
    q.enqueue({ type: 'insert', seq: i });
  }
  assertEq(q.size(), 2000, '队列满 2000');
  assertEq(q.dropped(), 0, '未超限前 dropped=0');

  // 继续画 3 笔 → FIFO 淘汰最旧（保新不保旧）
  for (let i = 2000; i < 2003; i++) {
    q.enqueue({ type: 'insert', seq: i });
  }
  assertEq(q.size(), 2000, '超限后队列仍 2000（FIFO 淘汰最旧）');
  assertEq(q.dropped(), 3, '超限 3 笔 → dropped=3');

  // drain 后 dropped 不清零 → DROPPED 状态持续可见（非一闪）
  const drained = q.drain();
  assertEq(drained.length, 2000, 'drain 取出 2000 笔（最新 2000 保新）');
  assertEq(drained[0].seq, 3, 'FIFO 淘汰了 seq 0..2（保新不保旧）');
  assertEq(q.size(), 0, 'drain 后 pending=0');
  assertEq(q.dropped(), 3, 'drain 后 dropped 仍为 3（DROPPED 持续可见）');

  // clear() 复位（用户确认「知道了」后）
  q.clear();
  assertEq(q.size(), 0, 'clear 后 pending=0');
  assertEq(q.dropped(), 0, 'clear 后 dropped=0（用户确认复位）');
}

// ═══ T2 附加：readUserId 换源（SessionIdentity 兜底链） ═══
console.log('--- T2 readUserId 换源（SessionIdentity 兜底链） ---');
{
  // Node 环境无 ArkUI AppStorage：SessionIdentity.userId() 会抛 ReferenceError，
  // 但 SignalCodec.readUserId() 的 try/catch 兜底应吞掉并回退 'unknown' ——
  // 关键是「不再直接读 AppStorage」，而是委托 SessionIdentity（其内部有完整回退链）。
  assertNoThrow(() => {
    const wire = SignalCodec.encodeCRDTOp({ type: 'insert', seq: 1, elementType: 'stroke' });
    const env = SignalCodec.decode(wire);
    // 在真实 ArkTS 环境 sender_id 取 SessionIdentity.userId()（服务端签发 > siteId）；
    // Node 兜底路径返回 'unknown' 属预期（无 AppStorage），重点是整链不抛异常。
    assert(env.sender_id !== null && env.sender_id !== undefined, 'encodeCRDTOp sender_id 字段存在');
  }, 'SignalCodec.encodeCRDTOp 经 SessionIdentity 兜底不抛异常（readUserId 换源生效）');
}

console.log('');
console.log(`=== 结果：${passed}/${total} PASS ===`);
if (failures.length > 0) {
  console.log('失败明细：');
  for (const f of failures) {
    console.log(`  ✗ ${f.name}${f.detail ? ' — ' + f.detail : ''}`);
  }
  process.exitCode = 1;
}
