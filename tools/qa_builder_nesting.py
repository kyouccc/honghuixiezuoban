#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""QA 工具2：验证指定行处的花括号嵌套深度 + 各 @Builder 的包围层级。"""
import sys
from pathlib import Path


def lex(text: str) -> str:
    out = []
    i, n = 0, len(text)
    while i < n:
        c, nxt = text[i], text[i+1] if i+1 < n else ""
        if c == "/" and nxt == "/":
            while i < n and text[i] != "\n":
                out.append(" "); i += 1
            continue
        if c == "/" and nxt == "*":
            out.append(" "); out.append(" "); i += 2
            while i < n and not (text[i] == "*" and i+1 < n and text[i+1] == "/"):
                if text[i] == "\n": out.append("\n")
                else: out.append(" ")
                i += 1
            if i < n: out.append(" "); out.append(" "); i += 2
            continue
        if c in ("'", '"', "`"):
            q = c
            out.append(" "); i += 1
            while i < n:
                if text[i] == "\\" and i+1 < n:
                    out.append(" "); out.append(" "); i += 2; continue
                if text[i] == q:
                    out.append(" "); i += 1; break
                if text[i] == "\n": out.append("\n")
                else: out.append(" ")
                i += 1
            continue
        out.append(c); i += 1
    return "".join(out)


def main():
    path = Path(sys.argv[1])
    lines = path.read_text(encoding="utf-8").splitlines()
    struct = lex("\n".join(lines))
    # 统计每一行开头的 brace depth
    line_depth = []
    d = 0
    for line in struct.split("\n"):
        line_depth.append(d)
        for ch in line:
            if ch == "{": d += 1
            elif ch == "}": d -= 1
    # 指定关键行
    key_lines = {
        "struct WhiteboardPage": 151,
        "build() 开": 1143,
        "buildNoteBar": 1485,
        "buildDraftBanner": 1663,
        "buildTopBar": 2034,
        "quickToolBar": 2242,
        "文件末尾": len(lines),
    }
    print("关键行 brace 深度（进入该行时）:")
    for name, ln in key_lines.items():
        idx = ln - 1
        if 0 <= idx < len(line_depth):
            print(f"  行 {ln:5d} [{name:24s}] depth={line_depth[idx]}")
        else:
            print(f"  行 {ln} [{name}] 超出范围")

    # 各 @Builder 的跨度：从 @Builder 行到其闭合
    print("\n各 @Builder 方法跨度验证:")
    # 先重新扫描 @Builder 行
    builder_lines = []
    for i, l in enumerate(lines, 1):
        if "@Builder" in l:
            builder_lines.append(i)
    # 计算每个 @Builder 方法体开 brace 与闭合 brace 行
    # 简化：找 @Builder 行之后下一个 '(' 后的 '{'，然后用 depth 匹配
    for bl in builder_lines:
        # 找该行及之后最近的 '{'（方法体开）
        open_brace_line = None
        for j in range(bl - 1, len(lines)):
            s = lex(lines[j])
            if "{" in s:
                open_brace_line = j + 1
                break
        if open_brace_line is None:
            print(f"  @Builder @ {bl}: 未找到方法体")
            continue
        d_open = line_depth[open_brace_line - 1]
        # 从 open_brace_line 开始，找 depth 回到 d_open 的行（即闭合）
        close_brace_line = None
        cur = d_open
        for j in range(open_brace_line - 1, len(lines)):
            s = lex(lines[j])
            for ch in s:
                if ch == "{": cur += 1
                elif ch == "}":
                    cur -= 1
                    if cur == d_open:
                        close_brace_line = j + 1
                        break
            if close_brace_line: break
        name = lines[bl-1].split("@Builder")[1].strip().split("(")[0].strip() or "(多行签名)"
        print(f"  @Builder [{name:22s}] @ {bl}: 方法体 {open_brace_line} -> {close_brace_line} (span={close_brace_line-open_brace_line+1 if close_brace_line else '?'})")

    # 找 build() 方法跨度
    for i, l in enumerate(lines, 1):
        if l.strip().startswith("build()"):
            bl = i
            d_open = line_depth[bl - 1]
            cur = d_open
            close_brace_line = None
            for j in range(bl - 1, len(lines)):
                s = lex(lines[j])
                for ch in s:
                    if ch == "{": cur += 1
                    elif ch == "}":
                        cur -= 1
                        if cur == d_open:
                            close_brace_line = j + 1
                            break
                if close_brace_line: break
            print(f"  build() @ {bl} -> {close_brace_line} (span={close_brace_line-bl+1 if close_brace_line else '?'})")
            break


if __name__ == "__main__":
    sys.exit(main())
