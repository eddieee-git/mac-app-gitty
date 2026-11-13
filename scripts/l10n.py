#!/usr/bin/env python3
"""화면 글자 번역 도우미.

  python3 scripts/l10n.py wrap     소스의 한국어 글자를 tr("…")로 감싼다 (작업 기록 Log.* 은 그대로)
  python3 scripts/l10n.py keys     번역 키 목록을 만든다 (끼워 넣은 값은 {}), 빠진 번역을 알려 준다

새 화면 글자를 넣을 때는 tr("…")로 감싸고 Resources/en.json에 영어를 더하면 된다.
`// no-tr`을 붙인 줄은 건드리지 않는다 (파일 이름처럼 번역하면 안 되는 글자).
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = sorted((ROOT / "Sources/Gitty").glob("*.swift"))
EN = ROOT / "Resources/en.json"
SKIP_FILES = {"Localization.swift"}
SKIP_CALLEES = {"Log.info", "Log.error", "Log.write"}
HANGUL = re.compile(r"[가-힣]")


class Literal:
    def __init__(self, start, end, parts, children):
        self.start, self.end = start, end   # 원본에서의 범위 (따옴표 포함)
        self.parts = parts                   # 글자 조각과 None(끼워 넣은 자리)
        self.children = children             # 끼워 넣은 코드 안의 글자들

    def has_hangul(self):
        return any(p and HANGUL.search(p) for p in self.parts)

    def key(self):
        return "".join("{}" if p is None else p for p in self.parts)


ESCAPES = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0", "r": "\r"}


def parse_string(src, i):
    """src[i]가 여는 따옴표일 때 Literal과 끝 위치를 돌려준다."""
    multi = src.startswith('"""', i)
    q = '"""' if multi else '"'
    j = i + len(q)
    parts, buf, children = [], "", []
    while j < len(src):
        if src.startswith(q, j):
            parts.append(buf)
            return Literal(i, j + len(q), parts, children), j + len(q)
        c = src[j]
        if c == "\\":
            n = src[j + 1]
            if n == "(":
                parts.append(buf); buf = ""
                depth, k = 1, j + 2
                while depth:
                    if src[k] == '"':
                        lit, k = parse_string(src, k)
                        children.append(lit)
                        continue
                    depth += {"(": 1, ")": -1}.get(src[k], 0)
                    k += 1
                parts.append(None)
                j = k
                continue
            if n == "u":
                end = src.index("}", j)
                buf += chr(int(src[j + 3:end], 16)); j = end + 1; continue
            if multi and n == "\n":
                j += 2; continue
            buf += ESCAPES.get(n, n); j += 2; continue
        buf += c
        j += 1
    raise ValueError("닫히지 않은 문자열")


def scan(src):
    """주석·원시 문자열을 건너뛰며 맨 바깥 글자들을 찾는다. (Literal, 감싸면 안 되는지)"""
    out, i, stack = [], 0, []
    line_start = 0
    while i < len(src):
        c = src[i]
        if c == "\n":
            line_start = i + 1
        if src.startswith("//", i):
            i = src.index("\n", i) if "\n" in src[i:] else len(src); continue
        if src.startswith("/*", i):
            i = src.index("*/", i) + 2; continue
        if c == "#" and src.startswith('#"', i):
            i = src.index('"#', i + 2) + 2; continue
        if c == "(":
            m = re.search(r"([A-Za-z_][A-Za-z0-9_.]*)\s*$", src[max(0, i - 60):i])
            stack.append(m.group(1) if m else "")
        elif c == ")":
            if stack: stack.pop()
        elif c == '"':
            lit, end = parse_string(src, i)
            line_end = src.find("\n", end)
            line = src[src.rfind("\n", 0, i) + 1: line_end if line_end >= 0 else len(src)]
            prev_start = src.rfind("\n", 0, max(0, src.rfind("\n", 0, i)))
            prev = src[prev_start + 1: src.rfind("\n", 0, i)] if prev_start >= -1 else ""
            skip = any(s in SKIP_CALLEES for s in stack) or "no-tr" in line or "no-tr" in prev
            out.append((lit, skip))
            i = end; continue
        i += 1
    return out


def all_literals(lits):
    for lit, skip in lits:
        yield lit, skip
        yield from all_literals([(c, skip) for c in lit.children])


def wrap_source(src):
    """감싸야 할 글자를 tr(…)로 감싼다. 끼워 넣은 코드 안의 글자도 감싼다."""
    edits = []
    for lit, skip in all_literals(scan(src)):
        if skip or not lit.has_hangul():
            continue
        if src[max(0, lit.start - 3):lit.start] == "tr(":
            continue
        edits.append((lit.start, "tr("))
        edits.append((lit.end, ")"))
    for pos, text in sorted(edits, key=lambda e: e[0], reverse=True):
        src = src[:pos] + text + src[pos:]
    return src


def keys():
    found = {}
    for path in SOURCES:
        if path.name in SKIP_FILES:
            continue
        src = path.read_text()
        for lit, skip in all_literals(scan(src)):
            if not skip and lit.has_hangul() and src[max(0, lit.start - 3):lit.start] == "tr(":
                found.setdefault(lit.key(), path.name)
    return found


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "keys"
    if mode == "wrap":
        for path in SOURCES:
            if path.name in SKIP_FILES:
                continue
            src = path.read_text()
            new = wrap_source(src)
            if new != src:
                path.write_text(new)
                print("감쌈:", path.name)
    elif mode == "keys":
        found = keys()
        table = json.loads(EN.read_text()) if EN.exists() else {}
        missing = [k for k in found if k not in table]
        unused = [k for k in table if k not in found]
        if "--json" in sys.argv:
            print(json.dumps(sorted(found), ensure_ascii=False, indent=1))
        print(f"키 {len(found)}개 · 번역 {len(table)}개 · 빠짐 {len(missing)}개 · 안 쓰임 {len(unused)}개", file=sys.stderr)
        for k in missing:
            print("빠짐:", json.dumps(k, ensure_ascii=False), file=sys.stderr)
        sys.exit(1 if missing else 0)
