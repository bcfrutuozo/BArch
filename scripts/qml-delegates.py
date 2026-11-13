#!/usr/bin/env python3
"""Delegates that read the model through context properties (modelData, index, model.x) without
declaring them as `required property`. Under `pragma ComponentBehavior: Bound` those context
properties are gone: the delegate throws `ReferenceError: modelData is not defined` the moment it
is created, which for a popup or a list may be much later than the reload. qml-check.sh runs it.

    scripts/qml-delegates.py [quickshell dir]      # one line per problem, exit 1 if any
"""
import re
import sys
from pathlib import Path

VIEWS = r"(Repeater|Instantiator|Variants|ListView|GridView|PathView|TableView|DelegateChooser|DelegateChoice)"
CTX = {"modelData": r"(?<![\w.])modelData\b(?!\s*:)", "index": r"(?<![\w.])index\b(?!\s*:)", "model": r"(?<![\w.])model\.\w"}


def strip(src: str) -> str:
    """Comments and string contents blanked (same length, so offsets and lines survive)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i); j = n if j < 0 else j
            out.append(" " * (j - i)); i = j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2); j = n if j < 0 else j + 2
            out.append(re.sub(r"[^\n]", " ", src[i:j])); i = j
        elif c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(c + re.sub(r"[^\n]", " ", src[i + 1:j]) + c); i = j + 1
        else:
            out.append(c); i += 1
    return "".join(out)


def blocks(s: str):
    """(type, open brace offset, close brace offset) of every `Type {` object, outermost first."""
    res, stack = [], []
    for m in re.finditer(r"[{}]", s):
        if m.group() == "{":
            head = re.search(r"([A-Z][\w.]*)\s*$", s[:m.start()])
            stack.append((head.group(1) if head else None, m.start(), s[max(0, m.start() - 40):m.start()]))
        elif stack:
            t, o, before = stack.pop()
            if t:
                res.append((t, o, m.start(), before))
    return sorted(res, key=lambda b: b[1])


def check(path: Path, rel: str):
    s = strip(path.read_text())
    bl = blocks(s)
    roots = []
    for t, o, c, before in bl:
        if re.search(r"\bdelegate\s*:\s*[A-Z][\w.]*\s*$", before):
            roots.append((t, o, c))
    for t, o, c, before in bl:
        if re.fullmatch(VIEWS, t.split(".")[-1]):
            # the view's own default child (Repeater { Item {} }) is its delegate
            kids = [b for b in bl if o < b[1] < c and not any(o < x[1] < b[1] < x[2] for x in bl if x[1] != b[1])]
            for k in kids:
                if not re.search(r"\w\s*:\s*[A-Z][\w.]*\s*$", k[3]):
                    roots.append((k[0], k[1], k[2]))
    for t, o, c, before in bl:          # Component { Root {} } : its root is a delegate when used as one
        if t == "Component":
            kids = [b for b in bl if o < b[1] < c and not any(o < x[1] < b[1] < x[2] for x in bl if x[1] != b[1])]
            roots += [(k[0], k[1], k[2]) for k in kids]
    roots = sorted({(o, c): (t, o, c) for t, o, c in roots}.values(), key=lambda r: r[1])
    probs = []
    for t, o, c in roots:
        inner = [(a, b) for _, a, b in roots if o < a < c]
        body = list(s[o:c + 1])
        for a, b in inner:                       # nested delegates answer for themselves
            for i in range(a - o, b - o + 1):
                body[i] = " "
        body = "".join(body)
        # declarations directly in this object (not in a child object)
        depth, top = 0, []
        for ch in body[1:]:
            depth += ch == "{"; depth -= ch == "}"
            top.append(ch if depth == 0 else " ")
        top = "".join(top)
        for name, pat in CTX.items():
            if not re.search(pat, body):
                continue
            if name == "model" and re.search(r"required property \w+ model\b", top):
                continue
            if name != "model" and re.search(rf"required property [\w<>]+ {name}\b", top):
                continue
            if name == "model":
                continue        # roles through `model.` are rare here; reported by qmllint -v instead
            line = s.count("\n", 0, o) + 1
            probs.append(f"{rel}:{line}: delegate {t} uses {name} without `required property ... {name}`")
    return probs


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "quickshell/.config/quickshell")
    probs = []
    for p in sorted(root.rglob("*.qml")):
        if p.is_symlink():
            continue
        if "pragma ComponentBehavior: Bound" not in p.read_text():
            continue
        probs += check(p, str(p.relative_to(root)))
    print("\n".join(probs)) if probs else None
    return 1 if probs else 0


if __name__ == "__main__":
    sys.exit(main())
