/**
 * ets-loader.mjs — Node.js loader，用于在纯 Node 环境运行 ArkTS(.ets) 源文件做逻辑验证
 *
 * 说明：
 *  - 将 .ets 按 TypeScript 源处理（Node --experimental-transform-types 负责类型剥离与 enum 转换）；
 *  - 实现 import elision：ArkTS 混合导入 `import { 值, 类型 } from '...'` 中，Node 22
 *    strip-types 不做类型导入消除，这里按"名字在正文中是否出现值上下文"拆分为
 *    `import { 值 }` + `import type { 类型 }`（export 同理拆为 export type）；
 *  - mock 鸿蒙 SDK 模块（@kit.PerformanceAnalysisKit / @ohos.multimedia.image / @ohos.file.fs），
 *    使不依赖真实设备的纯逻辑模块可运行；
 *  - 相对无扩展名 import（ArkTS 约定）解析为 .ets 文件。
 *
 * 仅供 QA 本地逻辑验证使用，不参与鸿蒙工程构建。
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

function dataUrl(js) {
  return 'data:text/javascript,' + encodeURIComponent(js);
}

// ─── 鸿蒙模块 Mock ───
const HILOG_MOCK = dataUrl(`
export const hilog = {
  debug() {}, info() {}, warn() {}, error() {}, fatal() {},
};
`);

const IMAGE_MOCK = dataUrl(`
export const PixelMapFormat = { RGBA_8888: 3, RGB_565: 2, BGRA_8888: 4 };
export async function createPixelMap(buf, opts) {
  return {
    width: opts && opts.size ? opts.size.width : 0,
    height: opts && opts.size ? opts.size.height : 0,
  };
}
export function createImageSource(uri) {
  return { createPixelMap: async () => ({ width: 0, height: 0 }) };
}
const imageApi = { PixelMapFormat, createPixelMap, createImageSource };
export default imageApi;
`);

const FS_MOCK = dataUrl(`
import { readFileSync as _readFileSync, statSync as _statSync } from 'node:fs';
export const OpenMode = { READ_ONLY: 0, WRITE_ONLY: 1, READ_WRITE: 2 };
export function openSync(uri, mode) { return { fd: uri }; }
export function statSync(uri) { return { size: _statSync(uri).size }; }
export function readSync(fd, buf, opts) {
  const len = opts && opts.length !== undefined ? opts.length : buf.byteLength;
  const offset = opts && opts.offset !== undefined ? opts.offset : 0;
  const fileBuf = _readFileSync(fd);
  const slice = fileBuf.subarray(offset, offset + len);
  new Uint8Array(buf).set(slice, 0);
  return slice.length;
}
export function closeSync(fd) {}
const fsApi = { OpenMode, openSync, statSync, readSync, closeSync };
export default fsApi;
`);

// C03（SignalCodec 依赖 @kit.ArkTS 的 util.TextEncoder/TextDecoder）。
// ArkTS util.TextEncoder.encodeInto(str) 返回 Uint8Array；TextDecoder.decodeToString(bytes) 返回 string。
// Node 全局 TextEncoder/TextDecoder 语义等价（encode(str)/decode(bytes)），直接委托。
const ARKTS_UTIL_MOCK = dataUrl(`
export const util = {
  TextEncoder: class {
    encodeInto(str) { return new TextEncoder().encode(str); }
  },
  TextDecoder: class {
    decodeToString(bytes) { return new TextDecoder().decode(bytes); }
  },
};
`);

const MOCKS = {
  '@kit.PerformanceAnalysisKit': HILOG_MOCK,
  '@kit.ArkTS': ARKTS_UTIL_MOCK,
  '@ohos.multimedia.image': IMAGE_MOCK,
  '@ohos.file.fs': FS_MOCK,
};

// ─── Import/Export Elision ───
function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** 剥离注释（块注释 + 行注释），避免注释中的文件名（如 CanvasElement.ets）干扰值判断 */
function stripComments(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\n]*/g, ' ');
}

/** 判断名字在正文中是否存在"值上下文"使用 */
function isValueUse(name, body) {
  const n = escapeRegExp(name);
  const patterns = [
    `new\\s+${n}\\b`,           // 构造
    `\\b${n}\\s*\\(`,           // 函数/构造调用
    `\\b${n}\\s*\\.`,           // 属性访问（枚举成员、静态成员）
    `\\b${n}\\?\\s*\\.`,        // 可选链
    `\\b${n}\\[(?!\\])`,        // 下标访问（排除 Name[] 数组类型）
    `\\(\\s*${n}\\b`,           // 括号内首参（值参数）
  ];
  for (const p of patterns) {
    const re = new RegExp(p, 'g');
    if (re.test(body)) {
      return true;
    }
  }
  return false;
}

/** 拆分混合 import/export：值名保留原样，类型名移入 import type / export type */
function elideImports(source) {
  // 仅匹配 import { ... } from / export { ... } from / export { ... }（本地），
  // 不匹配 export enum/class/interface/const/function/type 声明
  const declRe = /^\s*import\s+\{([^}]*)\}\s*from\s*['"][^'"]+['"]\s*;|^\s*export\s+\{([^}]*)\}\s*from\s*['"][^'"]+['"]\s*;|^\s*export\s+\{([^}]*)\}\s*;/gm;
  const matches = [];
  let m;
  while ((m = declRe.exec(source)) !== null) {
    let kind = 'import';
    if (/^\s*export/.test(m[0])) {
      kind = 'export';
    }
    matches.push({ start: m.index, end: m.index + m[0].length, kind });
  }
  if (matches.length === 0) {
    return source;
  }
  // 正文 = 去掉所有 import/export 声明块，并剥离注释（避免注释中文件名干扰值判断）
  let body = source;
  for (let i = matches.length - 1; i >= 0; i--) {
    body = body.slice(0, matches[i].start) +
      ' '.repeat(matches[i].end - matches[i].start) +
      body.slice(matches[i].end);
  }
  body = stripComments(body);
  let result = source;
  for (let i = matches.length - 1; i >= 0; i--) {
    const decl = matches[i];
    const text = result.slice(decl.start, decl.end);
    const inner = text.replace(/^\s*(import|export)\s+/, '');
    const fromMatch = /from\s*['"]([^'"]+)['"]/.exec(inner);
    const from = fromMatch ? fromMatch[1] : null;
    const braces = /\{([^}]*)\}/.exec(inner);
    if (!braces) {
      continue;
    }
    const names = braces[1].split(',').map(s => s.trim()).filter(s => s.length > 0).map(s => {
      const asMatch = /\s+as\s+/.exec(s);
      if (asMatch) {
        return {
          orig: s.slice(0, asMatch.index).trim(),
          local: s.slice(asMatch.index + asMatch[0].length).trim(),
        };
      }
      return { orig: s, local: s };
    });
    const valueNames = [];
    const typeNames = [];
    for (const nm of names) {
      if (isValueUse(nm.local, body)) {
        valueNames.push(nm);
      } else {
        typeNames.push(nm);
      }
    }
    const parts = [];
    if (valueNames.length > 0) {
      const list = valueNames.map(nm => nm.orig === nm.local ? nm.orig : `${nm.orig} as ${nm.local}`).join(', ');
      if (decl.kind === 'import') {
        parts.push(`import { ${list} }${from ? ` from '${from}'` : ''};`);
      } else {
        parts.push(`export { ${list} }${from ? ` from '${from}'` : ''};`);
      }
    }
    if (typeNames.length > 0) {
      const list = typeNames.map(nm => nm.orig === nm.local ? nm.orig : `${nm.orig} as ${nm.local}`).join(', ');
      if (decl.kind === 'import') {
        parts.push(`import type { ${list} }${from ? ` from '${from}'` : ''};`);
      } else {
        parts.push(`export type { ${list} }${from ? ` from '${from}'` : ''};`);
      }
    }
    const replacement = parts.length > 0 ? parts.join('\n') : '';
    result = result.slice(0, decl.start) + replacement + result.slice(decl.end);
  }
  return result;
}

export async function resolve(specifier, context, next) {
  if (Object.prototype.hasOwnProperty.call(MOCKS, specifier)) {
    return { url: MOCKS[specifier], shortCircuit: true };
  }
  // 相对路径无扩展名（ArkTS 约定）→ 尝试 .ets
  if (specifier.startsWith('.') &&
      !specifier.endsWith('.ets') &&
      !specifier.endsWith('.js') &&
      !specifier.endsWith('.mjs') &&
      !specifier.endsWith('.json')) {
    const base = new URL(specifier + '.ets', context.parentURL);
    return { url: base.href, shortCircuit: true };
  }
  return next(specifier, context);
}

export async function load(url, context, next) {
  if (url.endsWith('.ets')) {
    let source = readFileSync(fileURLToPath(url), 'utf-8');
    source = elideImports(source);
    return { format: 'module-typescript', source, shortCircuit: true };
  }
  return next(url, context);
}
