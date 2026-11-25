#!/usr/bin/env python3
"""Check `-- port: <file>.c <Func> L<a>-<b> @xonotic-v0.8.6` comments against the DarkPlaces source.

  python3 tools/engine/check_port_lines.py [--fix] [engine/*.luau ...]

A comment is right when line a of the C file defines Func (its name followed by '(' on that line or
the next) and line b is that function's closing '}' (first line starting with '}' after a).
--fix rewrites wrong ranges in place when the function is found exactly once in the file.
Needs work/source (tools/release/fetch.sh source).
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "work/source/Xonotic/source/darkplaces"
PAT = re.compile(r"-- port: (\w+\.c) (\w+) L(\d+)-(\d+)")


def func_range(lines, func):
    hits = []
    for i, l in enumerate(lines):
        split = re.match(re.escape(func) + r"\s*\(", l)  # return type on the line before (K&R style)
        if (split or re.match(r"^[A-Za-z_].*\b" + re.escape(func) + r"\s*\(", l)) and not l.rstrip().endswith(";"):
            if split and i > 0 and re.match(r"^[A-Za-z_][\w\s\*]*$", lines[i - 1]):
                i0 = i - 1
            else:
                i0 = i
            if l.rstrip().endswith("{"):
                k = i + 1
                while k < len(lines) and not lines[k].startswith("}"):
                    k += 1
                hits.append((i0 + 1, k + 1))
                continue
            j = i
            while j < len(lines) and not lines[j].startswith("{"):
                if lines[j].rstrip().endswith(";") and j > i:
                    break
                j += 1
            if j < len(lines) and lines[j].startswith("{"):
                k = j
                while k < len(lines) and not lines[k].startswith("}"):
                    k += 1
                hits.append((i0 + 1, k + 1))
    return hits


def main():
    fix = "--fix" in sys.argv
    files = [Path(a) for a in sys.argv[1:] if a != "--fix"] or sorted((ROOT / "engine").rglob("*.luau"))
    bad = 0
    for f in files:
        text = f.read_text()
        new = text
        for m in PAT.finditer(text):
            cfile, func, a, b = m.group(1), m.group(2), int(m.group(3)), int(m.group(4))
            p = SRC / cfile
            if not p.exists():
                continue
            hits = func_range(p.read_text(errors="replace").splitlines(), func)
            if (a, b) in hits:
                continue
            bad += 1
            want = f"L{hits[0][0]}-{hits[0][1]}" if len(hits) == 1 else f"{len(hits)} definitions"
            print(f"{f.relative_to(ROOT)}: {cfile} {func} L{a}-{b} -> {want}")
            if fix and len(hits) == 1:
                new = new.replace(m.group(0), f"-- port: {cfile} {func} L{hits[0][0]}-{hits[0][1]}", 1)
        if fix and new != text:
            f.write_text(new)
    print(f"{bad} wrong" + (" (fixed where unique)" if fix else ""))
    sys.exit(1 if bad and not fix else 0)


if __name__ == "__main__":
    main()
