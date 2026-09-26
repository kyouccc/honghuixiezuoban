/**
 * brace-scan.cjs — build() 括号平衡扫描（T05a 风险红线①：缩进不可信，只信括号计数）
 */
const fs = require('fs');
const src = fs.readFileSync(process.argv[2] || 'entry/src/main/ets/pages/WhiteboardPage.ets', 'utf8');
const lines = src.split('\n');

function findBuildStart() {
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].includes('build() {')) return i;
  }
  return -1;
}

const start = findBuildStart();
if (start < 0) {
  console.log('build() not found');
  process.exit(0);
}

let depth = 0;
let depthByLine = [];
for (let i = start; i < lines.length; i++) {
  const line = lines[i];
  // strip string literals (single-quoted), comments
  const stripped = line
    .replace(/'(?:[^'\\]|\\.)*'/g, "''")
    .replace(/\/\/.*$/, '')
    .replace(/\/\*[\s\S]*?\*\//g, '');
  for (const ch of stripped) {
    if (ch === '{') depth++;
    else if (ch === '}') depth--;
  }
  depthByLine.push({ line: i + 1, depth, text: line.trim().slice(0, 70) });
  if (depth === 0) {
    console.log(`build() spans lines ${start + 1}..${i + 1}`);
    break;
  }
}

// 打印每 10 行深度摘要 + 关键锚点行深度
console.log('--- 关键行深度（缩进 vs 实际括号深度）---');
const anchors = [
  'if (this.isHalfFolded)',
  '} else {',
  'Canvas(this.ctxPaper)',
  'Canvas(this.ctxHistory)',
  'Canvas(this.ctxActive)',
  'buildBottomBar()',
  'layoutWeight(1)',
  'constraintSize',
];
for (const rec of depthByLine) {
  const trimmed = rec.text;
  for (const a of anchors) {
    if (trimmed.includes(a)) {
      // 计算该行缩进空格数
      const indent = (() => {
        const full = lines[rec.line - 1];
        let n = 0;
        while (n < full.length && full[n] === ' ') n++;
        return n;
      })();
      console.log(`L${rec.line} depth=${rec.depth} indent=${indent} | ${trimmed}`);
      break;
    }
  }
}
console.log(`--- 总行数: ${depthByLine.length}，末深度: ${depth} ---`);
