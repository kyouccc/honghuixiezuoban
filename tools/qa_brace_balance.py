#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""QA 工具：ArkTS 花括号配平检查（简化 lexer，忽略字符串/注释中的花括号）。"""
import sys
import re
from pathlib import Path


def strip_comments_and_strings(text: str) -> str:
    """逐字符扫描，将字符串字面量与注释替换为等长空白，仅保留结构字符。
    处理：'...' "..." `...` 字符串、// 行注释、/* */ 块注释。
    返回 (结构化文本, 遇到的注释/字符串数量统计)。
    """
    out = []
    i = 0
    n = len(text)
    in_line_comment = False
    in_block_comment = False
    in_squote = False
    in_dquote = False
    in_tick = False
    stats = {"strings": 0, "line_comments": 0, "block_comments": 0}

    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""

        if in_line_comment:
            out.append(" ")
            if c == "\n":
                in_line_comment = False
                out[-1] = "\n"
            i += 1
            continue

        if in_block_comment:
            out.append(" ")
            if c == "*" and nxt == "/":
                out.append(" ")
                i += 2
                in_block_comment = False
                continue
            if c == "\n":
                out[-1] = "\n"
            i += 1
            continue

        if in_squote:
            out.append(" ")
            if c == "\\" and i + 1 < n:
                out.append(" ")
                i += 2
                continue
            if c == "'":
                in_squote = False
            i += 1
            continue

        if in_dquote:
            out.append(" ")
            if c == "\\" and i + 1 < n:
                out.append(" ")
                i += 2
                continue
            if c == '"':
                in_dquote = False
            i += 1
            continue

        if in_tick:
            out.append(" ")
            if c == "\\" and i + 1 < n:
                out.append(" ")
                i += 2
                continue
            if c == "`":
                in_tick = False
            i += 1
            continue

        # 不在任何上下文中
        if c == "/" and nxt == "/":
            in_line_comment = True
            stats["line_comments"] += 1
            out.append(" ")
            i += 2
            continue
        if c == "/" and nxt == "*":
            in_block_comment = True
            stats["block_comments"] += 1
            out.append(" ")
            i += 2
            continue
        if c == "'":
            in_squote = True
            stats["strings"] += 1
            out.append(" ")
            i += 1
            continue
        if c == '"':
            in_dquote = True
            stats["strings"] += 1
            out.append(" ")
            i += 1
            continue
        if c == "`":
            in_tick = True
            stats["strings"] += 1
            out.append(" ")
            i += 1
            continue

        out.append(c)
        i += 1

    return "".join(out), stats


def find_braces(struct_text: str):
    """扫描 { } 配对，返回每一对的位置与闭合行，以及深度曲线。"""
    stack = []
    pairs = []  # (open_idx, close_idx)
    depth = 0
    max_depth = 0
    depth_by_idx = {}

    for idx, ch in enumerate(struct_text):
        if ch == "{":
            stack.append(idx)
            depth += 1
            if depth > max_depth:
                max_depth = depth
            depth_by_idx[idx] = depth
        elif ch == "}":
            if stack:
                open_idx = stack.pop()
                pairs.append((open_idx, idx))
            depth -= 1
            depth_by_idx[idx] = depth

    return pairs, max_depth, depth, stack


def line_of(text: str, idx: int) -> int:
    return text.count("\n", 0, idx) + 1


def find_builder_methods(text: str, struct_text: str):
    """定位 @Builder 方法名在原文中的行号，以及 struct 中对应成员层级。"""
    results = []
    for m in re.finditer(r"@Builder\s*\n?\s*(\w+)\s*\([^)]*\)\s*\{", struct_text):
        name = m.group(1)
        open_idx = m.end() - 1
        results.append((name, open_idx, line_of(text, open_idx)))
    return results


def main():
    if len(sys.argv) < 2:
        print("usage: qa_brace_balance.py <file.ets>")
        return 1
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    struct_text, stats = strip_comments_and_strings(text)
    pairs, max_depth, final_depth, unclosed = find_braces(struct_text)

    print(f"=== 结构配平报告: {path.name} ===")
    print(f"文件行数: {text.count(chr(10)) + 1}")
    print(f"忽略的字符串字面量: {stats['strings']} 个, 行注释: {stats['line_comments']}, 块注释: {stats['block_comments']}")
    print(f"'{'{{'}' 总数: {len(pairs)}, 未闭合 '{'{{'}' 数量: {len(unclosed)}")
    print(f"最大嵌套深度: {max_depth}")
    print(f"最终 depth: {final_depth}  {'(OK, 配平)' if final_depth == 0 and not unclosed else '(!!! 未配平 !!!)'}")
    if unclosed:
        for u in unclosed:
            print(f"  未闭合 '{'{{'}' 位于行 {line_of(text, u)}")

    # 找所有 @Builder 方法
    builders = find_builder_methods(text, struct_text)
    print("\n=== @Builder 方法定位 ===")
    for name, open_idx, line in builders:
        # 找到此 open brace 的配对 close
        close_idx = None
        for o, c in pairs:
            if o == open_idx:
                close_idx = c
                break
        close_line = line_of(text, close_idx) if close_idx is not None else "?"
        print(f"  {name}: 起始行 {line}, 闭合行 {close_line}")

    # 输出所有 brace pair 的深度信息（用于核对 5 个 Builder 是否在 struct 成员层级）
    print("\n=== struct 级别 brace 对（顶层）===")
    # 顶层 depth: 在 depth==1 时打开的 brace 属于 struct 级
    depth_at = {}
    d = 0
    for idx, ch in enumerate(struct_text):
        if ch == "{":
            d += 1
            depth_at[idx] = d
        elif ch == "}":
            depth_at[idx] = d
            d -= 1
    for o, c in pairs:
        od = depth_at.get(o)
        if od == 1:
            print(f"  struct 成员块: 行 {line_of(text, o)} -> 行 {line_of(text, c)}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
